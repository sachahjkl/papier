#+build linux
package papiertool

// live: the real program against a real compositor that nobody sees (session.odin), and what a person does through
// wl-clipboard and over the DevTools protocol: copies of each kind, a secret, a copy of an entry already there, an entry
// put back, the clipboard emptied, the window shown, searched, hidden and shown again. Each wait is for a condition, with
// a bound.
//
//   papiertool live [--keep]     (--keep: build/live stays, with the logs and the window's pictures)
//
// Needs sway and wl-clipboard on the PATH (nix develop has them).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import cdp "gt:cdp"
import ocr "gt:ocr"

LIVE_DIR  :: "build/live"
LIVE_PORT :: 9361

@(private = "file")
Live :: struct {
	using session: Session,
	failures:      int,
	checks:        int,
}

@(private = "file")
check :: proc(l: ^Live, ok: bool, what: string, args: ..any) {
	l.checks += 1
	msg := fmt.tprintf(what, ..args)
	if ok { fmt.printfln("  ok    %s", msg); return }
	l.failures += 1
	fmt.printfln("  FAIL  %s", msg)
}

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
line_count :: proc(list: string) -> int {
	t := strings.trim_space(list)
	return t == "" ? 0 : strings.count(t, "\n") + 1
}

run_live :: proc(args: []string) -> int {
	keep := len(args) > 0 && args[0] == "--keep"
	if run_build(nil) != 0 { return 1 }
	l: Live
	if why := session_start(&l.session, LIVE_DIR, LIVE_PORT); why != "" {
		fmt.eprintfln("papiertool live: %s", why)
		session_stop(&l.session)
		return 1
	}
	dir := strings.clone(l.dir, context.temp_allocator)
	fmt.printfln("live: papier runs in a headless sway (%s)", dir)
	check(&l, true, "papier --hidden runs and answers")
	live_clipboard(&l)
	live_window(&l)
	code := session_stop(&l.session)
	check(&l, code == 0, "papier quit: it ends, with 0 (%d)", code)
	log, _ := os.read_entire_file(fmt.tprintf("%s/papier.log", dir), context.temp_allocator)
	check(&l, !strings.contains(string(log), "error"), "papier wrote no error (%s/papier.log)", dir)
	fmt.printfln("live: %d checks, %d failed", l.checks, l.failures)
	if !keep && l.failures == 0 { _ = os.remove_all(dir) }
	return l.failures == 0 ? 0 : 1
}

// Copies of each kind and what papier makes of them.
@(private = "file")
live_clipboard :: proc(l: ^Live) {
	TEXT :: "hello from papier live"
	check(l, copy_and_wait(l, TEXT), "a text copied is in the history")
	list, _ := run_in(l, PROGRAM, "list", "100")
	if f, found := entry_of(list, TEXT); found { check(l, f[1] == "text", "its kind is text (%s)", f[1]) }

	rich := "rich bold live"
	check(l, copy_and_wait(l, "<p>rich <b>bold</b> live</p>", "text/html", seen = rich), "HTML copied is in the history, its tags out of the preview")
	list, _ = run_in(l, PROGRAM, "list", "100")
	if f, found := entry_of(list, rich); found { check(l, f[1] == "html", "its kind is html (%s)", f[1]) }

	image := "image/png 64 × 64"
	check(l, copy_and_wait(l, "", "image/png", "assets/logo_64.png", seen = image), "a PNG copied is in the history with its size")

	file := "/etc/hostname"
	check(l, copy_and_wait(l, "file:///etc/hostname\r\n", "text/uri-list", seen = file), "a file copied is in the history")
	list, _ = run_in(l, PROGRAM, "list", "100")
	if f, found := entry_of(list, file); found { check(l, f[1] == "files", "its kind is files (%s)", f[1]) }

	// a password manager's secret, then a marker: once the marker is there, the secret was seen and left out
	check(l, wl_copy(l, "hunter2-secret", "x-kde-passwordManagerHint"), "wl-copy a secret")
	marker := "after the secret"
	check(l, copy_and_wait(l, marker), "a marker after it is in the history")
	list, _ = run_in(l, PROGRAM, "list", "100")
	check(l, !strings.contains(list, "hunter2"), "the secret is not in the history")

	// the same text again: the entry moves to the top, nothing is added
	before := line_count(list)
	check(l, wl_copy(l, TEXT), "wl-copy the first text again")
	text := TEXT
	top_is :: proc(list: string, data: rawptr) -> bool { return strings.contains(strings.split_lines(list, context.temp_allocator)[0], (^string)(data)^) }
	ok: bool
	list, ok = wait_list(l, top_is, &text)
	check(l, ok, "it is first again")
	check(l, line_count(list) == before, "nothing was added (%d entries, %d before)", line_count(list), before)

	// an entry put back on the clipboard: every type it had
	if f, found := entry_of(list, image); found {
		_, code := run_in(l, PROGRAM, "copy", f[0])
		check(l, code == 0, "papier copy %s", f[0])
		deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
		types := ""
		for time.tick_diff(time.tick_now(), deadline) > 0 {
			types, _ = run_in(l, "wl-paste", "-l")
			if strings.contains(types, "image/png") { break }
			time.sleep(SESSION_POLL)
		}
		check(l, strings.contains(types, "image/png"), "the clipboard offers image/png")
		png, _ := run_in(l, "wl-paste", "-t", "image/png")
		want, _ := os.read_entire_file("assets/logo_64.png", context.temp_allocator)
		check(l, png == string(want), "its bytes are the file's (%d bytes)", len(png))
	}

	// the clipboard emptied (its owner quit): papier puts the last entry back
	_, _ = run_in(l, "wl-copy", "--clear")
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	types := ""
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		types, _ = run_in(l, "wl-paste", "-l")
		if strings.trim_space(types) != "" { break }
		time.sleep(SESSION_POLL)
	}
	check(l, strings.trim_space(types) != "", "an emptied clipboard gets the last entry back")
}

// The menu of an image offers to read its text when the system can (OCR: libtesseract and a language; papier asks on a
// worker, this process asks too). Starts and ends with "bold" in the search, as live_window has it.
@(private = "file")
live_image_menu :: proc(l: ^Live, c: ^cdp.Client) {
	check(l, cdp.key(c, "Escape"), "Escape clears the search")
	check(l, cdp.type_text(c, "image/png"), "search the image")
	check(l, cdp.wait_for(c, "rich bold live", SESSION_WAIT, gone = true), "the image alone is listed")
	if _, available := ocr.available(); available {
		check(l, cdp.key(c, "ContextMenu"), "the Menu key on the image")
		check(l, cdp.wait_for(c, "Copy the text of the image", SESSION_WAIT), "the image's menu offers to read its text")
		check(l, cdp.key(c, "Escape"), "Escape closes the menu")
		check(l, cdp.wait_for(c, "Copy the text of the image", SESSION_WAIT, gone = true), "and it closes")
	} else {
		fmt.println("  skip  the image's menu and OCR: this system has no OCR engine or language (tesseract)")
	}
	check(l, cdp.key(c, "Escape"), "Escape clears the search")
	check(l, cdp.type_text(c, "bold"), "type in the search again")
	check(l, cdp.wait_for(c, "hello from papier live", SESSION_WAIT, gone = true), "the search leaves the other entries out again")
	check(l, cdp.wait_for(c, "rich bold live", SESSION_WAIT), "and keeps the match")
}

// The window: shown, read, searched, hidden and shown again; each time a frame comes, and the DevTools server takes a
// new connection.
@(private = "file")
live_window :: proc(l: ^Live) {
	_, code := run_in(l, PROGRAM, "show")
	check(l, code == 0, "papier show")
	c, ok := window_connect(l)
	check(l, ok, "the window serves the DevTools protocol")
	if !ok { return }
	check(l, cdp.wait_for(&c, "hello from papier live", SESSION_WAIT), "the window lists the history")
	check(l, cdp.shot(&c, fmt.tprintf("%s/window.png", l.dir)), "a picture of the window")
	check(l, cdp.type_text(&c, "bold"), "type in the search")
	check(l, cdp.wait_for(&c, "hello from papier live", SESSION_WAIT, gone = true), "the search leaves the other entries out")
	check(l, cdp.wait_for(&c, "rich bold live", SESSION_WAIT), "and keeps the match")
	// the entry's menu, from the keyboard
	check(l, cdp.key(&c, "ContextMenu"), "the Menu key")
	check(l, cdp.wait_for(&c, "Open with", SESSION_WAIT), "the entry's menu opens")
	check(l, cdp.key(&c, "Escape"), "Escape")
	check(l, cdp.wait_for(&c, "Open with", SESSION_WAIT, gone = true), "and closes")
	live_image_menu(l, &c)
	// the edit view: the rich text edited as text, saved in place of its entry
	EDITED :: "rich bold live, edited"
	check(l, cdp.key(&c, "ctrl+e"), "Ctrl+E")
	check(l, cdp.wait_for(&c, "Editing", SESSION_WAIT), "the edit view opens")
	check(l, cdp.type_text(&c, ", edited"), "type in the editor")
	check(l, cdp.key(&c, "ctrl+s"), "Ctrl+S")
	check(l, cdp.wait_for(&c, EDITED, SESSION_WAIT), "the entry is saved, edited")
	list, _ := run_in(l, PROGRAM, "list", "100")
	f, found := entry_of(list, EDITED)
	check(l, found && f[1] == "text", "the history has it, as text")

	// a theme chosen in the settings: saved, its folder made when it is not there, and still chosen after the reload
	cfg := fmt.tprintf("%s/config/papier", l.dir)
	_ = os.remove_all(cfg)
	check(l, cdp.key(&c, "ctrl+,"), "Ctrl+,")
	check(l, cdp.wait_for(&c, "Graphite", SESSION_WAIT), "the settings show the themes")
	check(l, cdp.click_text(&c, "Graphite"), "click Graphite's card")
	saved := false
	for _ in 0 ..< 50 {
		if data, err := os.read_entire_file(fmt.tprintf("%s/prefs", cfg), context.temp_allocator); err == nil && strings.contains(string(data), "picker.theme\tGraphite") { saved = true; break }
		time.sleep(100 * time.Millisecond)
	}
	check(l, saved, "the theme is in %s/prefs", cfg)
	time.sleep(300 * time.Millisecond)   // (the running papier reads its preferences again)
	prefs, _ := run_in(l, PROGRAM, "prefs")
	check(l, strings.contains(prefs, "picker.theme = Graphite"), "papier prefs: picker.theme is Graphite after the reload")
	check(l, cdp.key(&c, "ctrl+,"), "Ctrl+, again")
	check(l, cdp.wait_for(&c, EDITED, SESSION_WAIT), "the history is back")

	// Enter on the entry (paste.on_select): it goes on the clipboard, the window hides, and papier presses the paste keys
	// for what has the keyboard (sway has a virtual keyboard; the toolkit's desktop tests see the keys arrive)
	check(l, cdp.key(&c, "Escape"), "Escape clears the search (\"bold\", typed above)")
	check(l, cdp.type_text(&c, "edited"), "search the edited entry")
	check(l, cdp.wait_for(&c, "hello from papier live", SESSION_WAIT, gone = true), "it alone is listed")
	check(l, cdp.wait_for(&c, EDITED, SESSION_WAIT), "it is listed")
	_ = cdp.key(&c, "Enter")   // (its release finds the window gone: what follows says whether Enter did its work)
	pasted := false
	got: string
	for _ in 0 ..< 50 {
		out, pcode := run_in(l, "wl-paste", "-n")
		got = out
		if pcode == 0 && out == EDITED { pasted = true; break }
		time.sleep(100 * time.Millisecond)
	}
	check(l, pasted, "it is on the clipboard (%q)", got[:min(len(got), 60)])
	time.sleep(300 * time.Millisecond)
	plog, _ := os.read_entire_file(fmt.tprintf("%s/papier.log", l.dir), context.temp_allocator)
	check(l, !strings.contains(string(plog), "press keys"), "papier pressed the paste keys (%s/papier.log)", l.dir)
	cdp.close(&c)

	for round in 1 ..= 3 {
		_, hcode := run_in(l, PROGRAM, "hide")
		check(l, hcode == 0, "round %d: papier hide", round)
		_, scode := run_in(l, PROGRAM, "show")
		check(l, scode == 0, "round %d: papier show", round)
		rc, rok := window_connect(l)
		check(l, rok, "round %d: the DevTools server takes a connection", round)
		if !rok { continue }
		// (a show starts from an empty search: the first entry is back)
		asked := time.tick_now()
		check(l, cdp.wait_for(&rc, "hello from papier live", SESSION_WAIT), "round %d: a frame of the window again (%.0f ms)", round, time.duration_milliseconds(time.tick_since(asked)))
		cdp.close(&rc)
	}
}
