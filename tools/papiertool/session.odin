package papiertool

// A session nobody sees, for `live` and `shots`: a sway with no screen (headless, pixman) in a runtime directory of its
// own, and papier started in it, hidden, with its own history, preferences and state, no session bus (no tray icon in the
// person's panel) and the DevTools server on a port. wl-clipboard's commands and papier's own run in it (run_in, wl_copy).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import cdp "gt:cdp"
import toolbox "gt:toolbox"

SESSION_WAIT   :: 8 * time.Second
SESSION_POLL   :: 50 * time.Millisecond
// (papier floats at a size of its own, as a popup over the desktop would: the pictures have its real proportions)
SWAY_CONFIG    :: "output HEADLESS-1 resolution 1600x1000\nxwayland disable\nfor_window [app_id=\"papier\"] floating enable, resize set 1100 680\n"

Session :: struct {
	dir:    string,     // absolute: run/, data/, config/, state/, the logs
	port:   int,        // the window's DevTools port
	env:    []string,   // papier's and wl-clipboard's
	sway:   os.Process,
	papier: os.Process,
	up:     bool,       // sway runs (session_stop stops it)
}

// Starts sway and papier in `dir` (made anew). `why` says what failed.
session_start :: proc(s: ^Session, dir: string, port: int, prefs: []string = nil) -> (why: string) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	s.dir = strings.clone(fmt.tprintf("%s/%s", cwd, dir))
	s.port = port
	_ = os.remove_all(s.dir)
	run := fmt.tprintf("%s/run", s.dir)
	for d in ([]string{run, fmt.tprintf("%s/data", s.dir), fmt.tprintf("%s/config/papier", s.dir), fmt.tprintf("%s/state", s.dir)}) {
		if os.make_directory_all(d) != nil { return fmt.tprintf("%s cannot be made", d) }
	}
	_ = os.chmod(run, {.Read_User, .Write_User, .Execute_User})   // (a runtime directory is the user's alone)
	if len(prefs) > 0 {
		// the preferences file: config's user layer (its first line, then name<TAB>value)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "wbprefs 1\n")
		for p in prefs { strings.write_string(&b, p); strings.write_byte(&b, '\n') }
		_ = os.write_entire_file(fmt.tprintf("%s/config/papier/prefs", s.dir), strings.to_string(b))
	}
	conf := fmt.tprintf("%s/sway.conf", s.dir)
	_ = os.write_entire_file(conf, SWAY_CONFIG)

	sway_env := toolbox.env_with({"WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "SWAYSOCK"},
		fmt.tprintf("XDG_RUNTIME_DIR=%s", run), "WLR_BACKENDS=headless", "WLR_RENDERER=pixman", "WLR_LIBINPUT_NO_DEVICES=1")
	log, lerr := os.open(fmt.tprintf("%s/sway.log", s.dir), {.Write, .Create, .Trunc})
	if lerr != nil { return "the log cannot be written" }
	sway, serr := os.process_start({command = {"sway", "--unsupported-gpu", "-c", conf}, env = sway_env, stdout = log, stderr = log})
	os.close(log)
	if serr != nil { return "sway does not start (is it on the PATH? nix develop has it)" }
	s.sway, s.up = sway, true
	socket := ""
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for socket == "" && time.tick_diff(time.tick_now(), deadline) > 0 {
		if fis, err := os.read_all_directory_by_path(run, context.temp_allocator); err == nil {
			for fi in fis { if strings.has_prefix(fi.name, "wayland-") && !strings.has_suffix(fi.name, ".lock") { socket = strings.clone(fi.name, context.temp_allocator) } }
		}
		if socket == "" { time.sleep(SESSION_POLL) }
	}
	if socket == "" { return fmt.tprintf("sway made no Wayland socket (%s/sway.log)", s.dir) }

	env := toolbox.env_with({"WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME"},
		fmt.tprintf("XDG_RUNTIME_DIR=%s", run), fmt.tprintf("WAYLAND_DISPLAY=%s", socket),
		fmt.tprintf("XDG_DATA_HOME=%s/data", s.dir), fmt.tprintf("XDG_CONFIG_HOME=%s/config", s.dir), fmt.tprintf("XDG_STATE_HOME=%s/state", s.dir),
		fmt.tprintf("TOOLKIT_DEVTOOLS=%d", port))
	s.env = make([]string, len(env))
	for e, i in env { s.env[i] = strings.clone(e) }
	plog, perr := os.open(fmt.tprintf("%s/papier.log", s.dir), {.Write, .Create, .Trunc})
	if perr != nil { return "the log cannot be written" }
	papier, err := os.process_start({command = {PROGRAM, "--hidden"}, env = s.env, stdout = plog, stderr = plog})
	os.close(plog)
	if err != nil { return fmt.tprintf("%s does not start", PROGRAM) }
	s.papier = papier
	deadline = time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if out, _ := run_in(s, PROGRAM, "status"); strings.contains(out, "running: true") { return "" }
		time.sleep(SESSION_POLL)
	}
	return "papier does not answer"
}

// Ends papier (quit, then killed after SESSION_WAIT) and sway. `exit_code` is papier's (-1: it was killed).
session_stop :: proc(s: ^Session) -> (exit_code: int) {
	exit_code = -1
	if s.papier.handle != 0 {
		_, _ = run_in(s, PROGRAM, "quit")
		if state, err := os.process_wait(s.papier, SESSION_WAIT); err == nil && state.exited {
			exit_code = state.exit_code
		} else {
			_ = os.process_kill(s.papier)
		}
		s.papier = {}
	}
	if s.up {
		_ = os.process_kill(s.sway)
		_, _ = os.process_wait(s.sway, SESSION_WAIT)
		s.up = false
	}
	for e in s.env { delete(e) }
	delete(s.env)
	delete(s.dir)
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
