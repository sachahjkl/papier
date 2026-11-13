#+build linux
package papiertool

// A session nobody sees, for `live` and `shots`: the toolkit's sway with no screen (toolbox.sway_start: its own runtime
// directory, no session bus, so no tray icon in the person's panel), and papier started in it, hidden, with its own
// history, preferences and state and the DevTools server on a port. wl-clipboard's commands and papier's own run in it
// (run_in, wl_copy).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import cdp "gt:cdp"
import toolbox "gt:toolbox"

SESSION_WAIT   :: 8 * time.Second
SESSION_POLL   :: 50 * time.Millisecond
// (papier floats at a size of its own, as a popup over the desktop would: the pictures have its real proportions)
SWAY_CONFIG    :: "for_window [app_id=\"papier\"] floating enable, resize set 1100 680\n"

Session :: struct {
	sway:   toolbox.Sway,    // run/, config/, data/, state/, the logs
	dir:    string,          // the session's folder (the Sway's: freed by session_stop)
	port:   int,             // the window's DevTools port
	env:    []string,        // papier's and wl-clipboard's: the session's, and the DevTools port
	papier: os.Process,
	running: bool,           // papier was started (session_stop asks it to quit)
}

// Starts sway and papier in `dir` (made anew). `prefs`: lines of papier's preferences file. `why` says what failed.
session_start :: proc(s: ^Session, dir: string, port: int, prefs: []string = nil) -> (why: string) {
	toolbox.guard_groups()   // (a signal that ends the tool ends sway and papier with it)
	s.port = port
	if why = toolbox.sway_start(&s.sway, dir, {config = SWAY_CONFIG, homes = true}); why != "" { return }
	s.dir = s.sway.dir
	if len(prefs) > 0 {
		// the preferences file: config's user layer (its first line, then name<TAB>value)
		cfg := fmt.tprintf("%s/config/papier", s.dir)
		if os.make_directory_all(cfg) != nil { return fmt.tprintf("%s cannot be made", cfg) }
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "wbprefs 1\n")
		for p in prefs { strings.write_string(&b, p); strings.write_byte(&b, '\n') }
		_ = os.write_entire_file(fmt.tprintf("%s/prefs", cfg), strings.to_string(b))
	}
	devtools := fmt.tprintf("TOOLKIT_DEVTOOLS=%d", port)
	s.env = make([]string, len(s.sway.env) + 1)
	for e, i in s.sway.env { s.env[i] = strings.clone(e) }
	s.env[len(s.sway.env)] = strings.clone(devtools)
	p, pwhy := toolbox.sway_program(&s.sway, {PROGRAM, "--hidden"}, {devtools}, fmt.tprintf("%s/papier.log", s.dir))
	if pwhy != "" { return pwhy }
	s.papier, s.running = p, true
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if out, _ := run_in(s, PROGRAM, "--status"); strings.contains(out, "running: true") { return "" }
		time.sleep(SESSION_POLL)
	}
	return "papier does not answer"
}

// Ends papier (quit, then stopped with the session after SESSION_WAIT) and sway. `exit_code` is papier's (-1: it was
// stopped).
session_stop :: proc(s: ^Session) -> (exit_code: int) {
	exit_code = -1
	if s.running {
		_, _ = run_in(s, PROGRAM, "quit")
		if state, ended := toolbox.sway_wait(&s.sway, s.papier, SESSION_WAIT); ended && state.exited { exit_code = state.exit_code }
		s.running = false
	}
	toolbox.sway_stop(&s.sway)
	for e in s.env { delete(e) }
	delete(s.env)
	s.env, s.dir = nil, ""
	return
}

// A command of the session, its standard output kept.
run_in :: proc(s: ^Session, command: ..string) -> (out: string, code: int) {
	return toolbox.capture(command, {env = s.env})
}

// wl-copy of `text` (or of the file `file`) as `mime` ("": text). wl-copy leaves a process of its own that serves the
// selection: this one waits only for the one it starts, whose output goes nowhere.
wl_copy :: proc(s: ^Session, text: string, mime := "", file := "") -> bool {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "wl-copy")
	if mime != "" { append(&cmd, "-t", mime) }
	stdin: ^os.File
	if file != "" {
		f, err := os.open(file)
		if err != nil { return false }
		stdin = f
	} else {
		append(&cmd, text)
	}
	defer if stdin != nil { os.close(stdin) }
	p, err := os.process_start({command = cmd[:], env = s.env, stdin = stdin})
	if err != nil { return false }
	state, werr := os.process_wait(p, SESSION_WAIT)
	return werr == nil && state.exited && state.exit_code == 0
}

// `papier list` until `done` says yes, at most SESSION_WAIT.
wait_list :: proc(s: ^Session, done: proc(list: string, data: rawptr) -> bool, data: rawptr) -> (list: string, ok: bool) {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		out, code := run_in(s, PROGRAM, "list", "100")
		if code == 0 && done(out, data) { return out, true }
		time.sleep(SESSION_POLL)
	}
	out, _ := run_in(s, PROGRAM, "list", "100")
	return out, false
}

lists :: proc(list: string, data: rawptr) -> bool { return strings.contains(list, (^string)(data)^) }

// Copies `text` and waits until the history has it.
copy_and_wait :: proc(s: ^Session, text: string, mime := "", file := "", seen := "") -> bool {
	if !wl_copy(s, text, mime, file) { return false }
	want := seen != "" ? seen : text
	_, ok := wait_list(s, lists, &want)
	return ok
}

// A connection to the window's DevTools server, tried until SESSION_WAIT.
window_connect :: proc(s: ^Session) -> (c: cdp.Client, ok: bool) {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if c, ok = cdp.connect(s.port); ok { return }
		time.sleep(SESSION_POLL)
	}
	return
}
