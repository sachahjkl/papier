// papier: a clipboard manager for Linux (Wayland) and Windows, on gui_toolkit.
//
// One process for the session keeps the history and lives in the notification area; its window comes up in a few
// milliseconds (app.odin). A start of `papier` when it runs hands it a command and ends.
package papier

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import config "gt:config"
import instance "gt:instance"
import "gt:platform"
import "history"

APP_VERSION :: "0.14.0"

USAGE :: `papier: the clipboard's history

  papier                      show the history (start papier when it does not run)
  papier --hidden             start papier in the notification area (for the session's start)
  papier --setup              install papier for you, repair or upgrade the install, or uninstall it
  papier toggle               show the history, or hide it when it is shown (for a key binding)
  papier show | hide | quit
  papier list [count]         the newest entries: id, kind, age, a line of text
  papier get <id> [mime]      the bytes of an entry on the standard output
  papier copy <id>            put an entry back on the clipboard
  papier pin | unpin | delete <id>
  papier clear                remove every entry that is not pinned
  papier install [--no-autostart] [--no-path]
                              the launcher, the icons, ~/.local/bin/papier and the start with the session
  papier uninstall            take them away (the history stays)
  papier status               what is installed, and whether papier runs
  papier prefs                every preference, its value and what it does
  papier set <name> <value>   change a preference (saved; the running papier reads it again)
  papier version
  --pref name=value           a preference for this run only
`

main :: proc() {
	os.exit(run(os.args[1:]))
}

run :: proc(all_args: []string) -> int {
	prefs: config.Prefs
	args, problems := prefs_open(&prefs, all_args)
	defer config.prefs_destroy(&prefs)
	for p in problems { errf("papier: %s", p) }
	verb := len(args) > 0 ? args[0] : ""
	rest := len(args) > 1 ? args[1:] : nil
	switch verb {
	case "", "--hidden", "toggle", "--setup":
		return start(&prefs, verb)
	case "show", "hide", "quit", "copy", "pin", "unpin", "delete", "clear", "reload":
		c, ok := command_parse(strings.join(args[:], " ", context.temp_allocator))
		if !ok { errs(USAGE); return 2 }
		if !command_send(c) { errln("papier: papier does not run (start it with: papier --hidden)"); return 1 }
		return 0
	case "list":    return cmd_list(&prefs, rest)
	case "get":     return cmd_get(&prefs, rest)
	case "install":   return cmd_install(rest)
	case "uninstall": return cmd_uninstall(rest)
	case "status":    return cmd_status(rest)
	case "prefs":   return cmd_prefs(&prefs)
	case "set":     return cmd_set(&prefs, rest)
	case "version", "--version":
		outf("papier %s", APP_VERSION)
		return 0
	case "help", "-h", "--help":
		outs(USAGE)
		return 0
	}
	errs(USAGE)
	return 2
}

// The running papier is asked to show (or toggle) its window; when none runs, this process becomes it.
@(private = "file")
start :: proc(prefs: ^config.Prefs, verb: string) -> int {
	hidden := verb == "--hidden"
	message := hidden ? "ping" : verb == "toggle" ? "toggle" : verb == "--setup" ? "setup" : "show"
	// (Wayland: the launcher's token goes with it, so the running papier's window gets the keyboard)
	if token := platform.activation_token_from_env(context.temp_allocator); token != "" && !hidden && !strings.contains_any(token, " \n") {
		message = fmt.tprintf("%s %s", message, token)
	}
	outcome, owner := instance.acquire({name = DAEMON_NAME, wait_ms = 1500}, transmute([]u8)message)
	switch outcome {
	case .First:          return app_run(prefs, hidden, owner, setup_asked = verb == "--setup")
	case .Forwarded:      return 0
	case .Other_Instance: return 0
	case .Unresponsive:
		errln("papier: a papier runs and does not answer")
		return 1
	}
	return 1
}

@(private = "file")
open_store :: proc(prefs: ^config.Prefs, s: ^history.Store) -> bool {
	when ODIN_OS == .Windows {
		// (no watcher in this process: the system's history read here, once)
		if err := history.system_read_once(classify); err != .None {
			errf("papier: %s", history.SYSTEM_ERROR_TEXT[err])
			return false
		}
	}
	settings := prefs_read(prefs, context.temp_allocator)
	ok, why := history.open(s, history_dir(settings.persist))
	if !ok { errf("papier: the history cannot be opened: %s", why) }
	return ok
}

@(private = "file")
cmd_list :: proc(prefs: ^config.Prefs, args: []string) -> int {
	count := 20
	if len(args) > 0 { count = strconv.parse_int(args[0]) or_else count }
	s: history.Store
	if !open_store(prefs, &s) { return 1 }
	defer history.close(&s)
	now := now_ms()
	for e in s.entries[:min(count, len(s.entries))] {
		outf("%d\t%s%s\t%s\t%s", e.id, history.KIND_NAMES[e.kind], e.pinned ? "*" : "", age_text(now - e.time_ms), one_line(e.preview, 100))
	}
	return 0
}

@(private = "file")
cmd_get :: proc(prefs: ^config.Prefs, args: []string) -> int {
	if len(args) == 0 { errs(USAGE); return 2 }
	id, ok := strconv.parse_u64(args[0])
	if !ok { errs(USAGE); return 2 }
	s: history.Store
	if !open_store(prefs, &s) { return 1 }
	defer history.close(&s)
	at := history.find(&s, id)
	if at < 0 { errf("papier: no entry %d", id); return 1 }
	e := s.entries[at]
	rep := -1
	if len(args) > 1 {
		rep = history.rep_find(e, args[1])
	} else {
		for r, i in e.reps { if r.hash == e.key { rep = i; break } }
	}
	if rep < 0 { errf("papier: entry %d has no such type", id); return 1 }
	data := history.blob_read(&s, e.reps[rep].hash, context.temp_allocator)
	if data == nil { errln("papier: the entry's data is gone"); return 1 }
	outs(string(data))
	return 0
}

@(private = "file")
cmd_prefs :: proc(prefs: ^config.Prefs) -> int {
	for name in config.sorted_names(prefs) {
		r := config.ref_of(prefs, name)
		e := config.entry(prefs, r)
		outf("%s = %s%s\n    %s", name, config.value_string(prefs, r), config.is_default(prefs, r) ? "" : "   (changed)", e.def.description)
	}
	return 0
}

@(private = "file")
cmd_set :: proc(prefs: ^config.Prefs, args: []string) -> int {
	if len(args) != 2 { errs(USAGE); return 2 }
	if err := config.set_from_string(prefs, args[0], args[1], .User); err != .None {
		errf("papier: %s: %s", args[0], config.set_error_text(err))
		return 1
	}
	path := prefs_file()
	if !config.save_user(prefs, path) { errf("papier: %s cannot be written", path); return 1 }
	command_send({verb = .Reload})
	return 0
}

// "12 s", "5 min", "3 h", "2 d".
age_text :: proc(ms: i64, allocator := context.temp_allocator) -> string {
	s := max(ms, 0) / 1000
	switch {
	case s < 60:        return fmt.aprintf("%d s", s, allocator = allocator)
	case s < 3600:      return fmt.aprintf("%d min", s / 60, allocator = allocator)
	case s < 86400:     return fmt.aprintf("%d h", s / 3600, allocator = allocator)
	}
	return fmt.aprintf("%d d", s / 86400, allocator = allocator)
}

// The text on one line: blanks run together, cut after `max_runes` characters with an ellipsis.
one_line :: proc(text: string, max_runes: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	n := 0
	blank := false
	for c in text {
		if c == '\n' || c == '\r' || c == '\t' || c == ' ' { blank = true; continue }
		if blank && strings.builder_len(b) > 0 { strings.write_byte(&b, ' '); n += 1 }
		blank = false
		if n >= max_runes { strings.write_string(&b, "…"); break }
		strings.write_rune(&b, c)
		n += 1
	}
	return strings.to_string(b)
}
