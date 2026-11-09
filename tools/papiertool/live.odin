package papiertool

// live: the real program against a real compositor that nobody sees. A sway with no screen (headless, pixman) in a
// runtime directory of its own, papier started in it hidden, and what a person does through wl-clipboard and over the
// DevTools protocol: copies of each kind, a secret, a copy of an entry already there, an entry put back, the clipboard
// emptied, the window shown, hidden and shown again. Nothing reaches the person's session: no session bus (no tray icon
// in their panel), the history in a scratch folder. Each wait is for a condition, with a bound.
//
//   papiertool live [--keep]     (--keep: the scratch folder stays, with sway's log and the window's pictures)
//
// Needs sway and wl-clipboard on the PATH (nix develop has them).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import cdp "gt:cdp"
import toolbox "gt:toolbox"

LIVE_DIR         :: "build/live"
LIVE_PORT        :: 9361
LIVE_WAIT        :: 8 * time.Second
LIVE_POLL        :: 50 * time.Millisecond
LIVE_SWAY_CONFIG :: "output HEADLESS-1 resolution 1280x800\nxwayland disable\n"

Live :: struct {
	dir:      string,
	env:      []string,   // papier's and wl-clipboard's: the scratch session
	sway:     os.Process,
	papier:   os.Process,
	failures: int,
	checks:   int,
}

@(private = "file")
check :: proc(l: ^Live, ok: bool, what: string, args: ..any) {
	l.checks += 1
	msg := fmt.tprintf(what, ..args)
	if ok { fmt.printfln("  ok    %s", msg); return }
	l.failures += 1
	fmt.printfln("  FAIL  %s", msg)
}

// A command of the scratch session, its standard output kept.
@(private = "file")
run_in :: proc(l: ^Live, command: ..string) -> (out: string, code: int) {
	return toolbox.capture(command, {env = l.env})
}

// wl-copy of `text` as `mime` ("": text). wl-copy leaves a process of its own that serves the selection; this one waits
// only for the one it starts, whose output goes nowhere.
@(private = "file")
wl_copy :: proc(l: ^Live, text: string, mime := "", file := "") -> bool {
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
	p, err := os.process_start({command = cmd[:], env = l.env, stdin = stdin})
	if err != nil { return false }
	state, werr := os.process_wait(p, LIVE_WAIT)
	return werr == nil && state.exited && state.exit_code == 0
}

// `papier list` until `done` says yes, at most LIVE_WAIT.
@(private = "file")
wait_list :: proc(l: ^Live, done: proc(list: string, data: rawptr) -> bool, data: rawptr) -> (list: string, ok: bool) {
	deadline := time.tick_add(time.tick_now(), LIVE_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		out, code := run_in(l, "build/papier", "list", "100")
		if code == 0 && done(out, data) { return out, true }
		time.sleep(LIVE_POLL)
	}
	out, _ := run_in(l, "build/papier", "list", "100")
	return out, false
}

@(private = "file")
lists :: proc(list: string, data: rawptr) -> bool { return strings.contains(list, (^string)(data)^) }

// The fields of the line of `list` whose preview holds `text`: id, kind, age, preview.
@(private = "file")
entry_of :: proc(list, text: string) -> (fields: []string, ok: bool) {
	rest := list
	for line in strings.split_lines_iterator(&rest) {
		if strings.contains(line, text) { return strings.split(line, "\t", context.temp_allocator), true }
	}
	return
}

@(private = "file")
line_count :: proc(list: string) -> int { return strings.count(strings.trim_space(list), "\n") + (strings.trim_space(list) == "" ? 0 : 1) }

run_live :: proc(args: []string) -> int {
	keep := len(args) > 0 && args[0] == "--keep"
	if run_build(nil) != 0 { return 1 }
	l: Live
	cwd, _ := os.get_working_directory(context.temp_allocator)
	l.dir = fmt.tprintf("%s/%s", cwd, LIVE_DIR)
	_ = os.remove_all(l.dir)
	run := fmt.tprintf("%s/run", l.dir)
	for d in ([]string{run, fmt.tprintf("%s/data", l.dir), fmt.tprintf("%s/config", l.dir), fmt.tprintf("%s/state", l.dir)}) {
		if os.make_directory_all(d) != nil { fmt.eprintfln("papiertool: %s cannot be made", d); return 1 }
	}
	_ = os.chmod(run, {.Read_User, .Write_User, .Execute_User})   // (a runtime directory is the user's alone)
	conf := fmt.tprintf("%s/sway.conf", l.dir)
	_ = os.write_entire_file(conf, LIVE_SWAY_CONFIG)

	// the compositor
	sway_env := toolbox.env_with({"WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "SWAYSOCK"},
		fmt.tprintf("XDG_RUNTIME_DIR=%s", run), "WLR_BACKENDS=headless", "WLR_RENDERER=pixman", "WLR_LIBINPUT_NO_DEVICES=1")
	log, lerr := os.open(fmt.tprintf("%s/sway.log", l.dir), {.Write, .Create, .Trunc})
	if lerr != nil { return 1 }
	sway, serr := os.process_start({command = {"sway", "--unsupported-gpu", "-c", conf}, env = sway_env, stdout = log, stderr = log})
	os.close(log)
	if serr != nil { fmt.eprintln("papiertool: sway does not start (is it on the PATH? nix develop has it)"); return 1 }
	l.sway = sway
	defer {
		_ = os.process_kill(l.sway)
		_, _ = os.process_wait(l.sway, LIVE_WAIT)
		if !keep && l.failures == 0 { _ = os.remove_all(fmt.tprintf("%s/run", l.dir)) }
	}
	socket := ""
	deadline := time.tick_add(time.tick_now(), LIVE_WAIT)
	for socket == "" && time.tick_diff(time.tick_now(), deadline) > 0 {
		if fis, err := os.read_all_directory_by_path(run, context.temp_allocator); err == nil {
			for fi in fis { if strings.has_prefix(fi.name, "wayland-") && !strings.has_suffix(fi.name, ".lock") { socket = strings.clone(fi.name, context.temp_allocator) } }
		}
		if socket == "" { time.sleep(LIVE_POLL) }
	}
	if socket == "" { fmt.eprintfln("papiertool: sway made no Wayland socket (%s/sway.log)", l.dir); return 1 }
	fmt.printfln("live: sway on %s in %s", socket, run)

	// papier, hidden, in the scratch session: its own history, no session bus (no tray icon in the person's panel)
	l.env = toolbox.env_with({"WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME"},
		fmt.tprintf("XDG_RUNTIME_DIR=%s", run), fmt.tprintf("WAYLAND_DISPLAY=%s", socket),
		fmt.tprintf("XDG_DATA_HOME=%s/data", l.dir), fmt.tprintf("XDG_CONFIG_HOME=%s/config", l.dir), fmt.tprintf("XDG_STATE_HOME=%s/state", l.dir),
		fmt.tprintf("TOOLKIT_DEVTOOLS=%d", LIVE_PORT))
	plog, perr := os.open(fmt.tprintf("%s/papier.log", l.dir), {.Write, .Create, .Trunc})
	if perr != nil { return 1 }
	papier, err := os.process_start({command = {"build/papier", "--hidden"}, env = l.env, stdout = plog, stderr = plog})
	os.close(plog)
	if err != nil { fmt.eprintln("papiertool: build/papier does not start"); return 1 }
	l.papier = papier
	running := false
	deadline = time.tick_add(time.tick_now(), LIVE_WAIT)
	for !running && time.tick_diff(time.tick_now(), deadline) > 0 {
		_, code := run_in(&l, "build/papier", "status")
		out, _ := run_in(&l, "build/papier", "status")
		running = code == 0 || strings.contains(out, "running: true")
		if !running { time.sleep(LIVE_POLL) }
	}
	check(&l, running, "papier --hidden runs and answers")

	live_clipboard(&l)
	live_window(&l)

	_, qcode := run_in(&l, "build/papier", "quit")
	state, werr := os.process_wait(l.papier, LIVE_WAIT)
	check(&l, qcode == 0 && werr == nil && state.exited && state.exit_code == 0, "papier quit: it ends, with 0")
	if werr != nil { _ = os.process_kill(l.papier) }
	plog_text, _ := os.read_entire_file(fmt.tprintf("%s/papier.log", l.dir), context.temp_allocator)
	check(&l, !strings.contains(string(plog_text), "error"), "papier wrote no error (%s/papier.log)", l.dir)

	fmt.printfln("live: %d checks, %d failed", l.checks, l.failures)
	return l.failures == 0 ? 0 : 1
}

// Copies of each kind and what papier makes of them.
@(private = "file")
live_clipboard :: proc(l: ^Live) {
	TEXT :: "hello from papier live"
	check(l, wl_copy(l, TEXT), "wl-copy a text")
	text := TEXT
	list, ok := wait_list(l, lists, &text)
	check(l, ok, "the text is in the history")
	if f, found := entry_of(list, TEXT); found { check(l, f[1] == "text", "its kind is text (%s)", f[1]) }

	check(l, wl_copy(l, "<p>rich <b>bold</b> live</p>", "text/html"), "wl-copy HTML")
	rich := "rich bold live"
	list, ok = wait_list(l, lists, &rich)
	check(l, ok, "the HTML is in the history, its tags out of the preview")
	if f, found := entry_of(list, rich); found { check(l, f[1] == "html", "its kind is html (%s)", f[1]) }

	check(l, wl_copy(l, "", "image/png", "assets/logo_64.png"), "wl-copy a PNG")
	image := "image/png 64 × 64"
	list, ok = wait_list(l, lists, &image)
	check(l, ok, "the image is in the history with its size")

	check(l, wl_copy(l, "file:///etc/hostname\r\n", "text/uri-list"), "wl-copy a file")
	file := "/etc/hostname"
	list, ok = wait_list(l, lists, &file)
	check(l, ok, "the file is in the history")
	if f, found := entry_of(list, file); found { check(l, f[1] == "files", "its kind is files (%s)", f[1]) }

	// a password manager's secret, then a marker: once the marker is there, the secret was seen and left out
	check(l, wl_copy(l, "hunter2-secret", "x-kde-passwordManagerHint"), "wl-copy a secret")
	marker := "after the secret"
	check(l, wl_copy(l, marker), "wl-copy a marker")
	list, ok = wait_list(l, lists, &marker)
	check(l, ok && !strings.contains(list, "hunter2"), "the secret is not in the history")

	// the same text again: the entry moves to the top, nothing is added
	before := line_count(list)
	check(l, wl_copy(l, TEXT), "wl-copy the first text again")
	top_is :: proc(list: string, data: rawptr) -> bool { return strings.contains(strings.split_lines(list, context.temp_allocator)[0], (^string)(data)^) }
	list, ok = wait_list(l, top_is, &text)
	check(l, ok, "it is first again")
	check(l, line_count(list) == before, "nothing was added (%d entries, %d before)", line_count(list), before)

	// an entry put back on the clipboard: every type it had
	if f, found := entry_of(list, image); found {
		_, code := run_in(l, "build/papier", "copy", f[0])
		check(l, code == 0, "papier copy %s", f[0])
		deadline := time.tick_add(time.tick_now(), LIVE_WAIT)
		types := ""
		for time.tick_diff(time.tick_now(), deadline) > 0 {
			types, _ = run_in(l, "wl-paste", "-l")
			if strings.contains(types, "image/png") { break }
			time.sleep(LIVE_POLL)
		}
		check(l, strings.contains(types, "image/png"), "the clipboard offers image/png")
		png, _ := run_in(l, "wl-paste", "-t", "image/png")
		want, _ := os.read_entire_file("assets/logo_64.png", context.temp_allocator)
		check(l, png == string(want), "its bytes are the file's (%d bytes)", len(png))
	}

	// the clipboard emptied (its owner quit): papier puts the last entry back
	_, _ = run_in(l, "wl-copy", "--clear")
	deadline := time.tick_add(time.tick_now(), LIVE_WAIT)
	types := ""
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		types, _ = run_in(l, "wl-paste", "-l")
		if strings.trim_space(types) != "" { break }
		time.sleep(LIVE_POLL)
	}
	check(l, strings.trim_space(types) != "", "an emptied clipboard gets the last entry back")
}

// A connection to the window's DevTools server, tried until LIVE_WAIT.
@(private = "file")
window_connect :: proc() -> (c: cdp.Client, ok: bool) {
	deadline := time.tick_add(time.tick_now(), LIVE_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if c, ok = cdp.connect(LIVE_PORT); ok { return }
		time.sleep(LIVE_POLL)
	}
	return
}

// The window: shown, read, searched, hidden and shown again; each time a frame comes, and the DevTools server takes a
// new connection.
@(private = "file")
live_window :: proc(l: ^Live) {
	_, code := run_in(l, "build/papier", "show")
	check(l, code == 0, "papier show")
	c, ok := window_connect()
	check(l, ok, "the window serves the DevTools protocol")
	if !ok { return }
	check(l, cdp.wait_for(&c, "hello from papier live", LIVE_WAIT), "the window lists the history")
	check(l, cdp.shot(&c, fmt.tprintf("%s/window.png", l.dir)), "a picture of the window (%s/window.png)", l.dir)
	check(l, cdp.type_text(&c, "bold"), "type in the search")
	check(l, cdp.wait_for(&c, "hello from papier live", LIVE_WAIT, gone = true), "the search leaves the other entries out")
	check(l, cdp.wait_for(&c, "rich bold live", LIVE_WAIT), "and keeps the match")
	check(l, cdp.shot(&c, fmt.tprintf("%s/search.png", l.dir)), "a picture of the search")
	cdp.close(&c)

	for round in 1 ..= 3 {
		_, hcode := run_in(l, "build/papier", "hide")
		check(l, hcode == 0, "round %d: papier hide", round)
		_, scode := run_in(l, "build/papier", "show")
		check(l, scode == 0, "round %d: papier show", round)
		rc, rok := window_connect()
		check(l, rok, "round %d: the DevTools server takes a connection", round)
		if !rok { continue }
		// (a show starts from an empty search: the first entry is back)
		check(l, cdp.wait_for(&rc, "hello from papier live", LIVE_WAIT), "round %d: a frame of the window again", round)
		if round == 3 { check(l, cdp.shot(&rc, fmt.tprintf("%s/window_again.png", l.dir)), "a picture after the shows") }
		cdp.close(&rc)
	}
}
