#+build linux
package papiertool

// shots: the pictures of the README, the documentation and the site, the program's own frames (over the DevTools protocol,
// session.odin): a history of made-up entries (never the person's clipboard), then the window as each picture shows it.
//
//   papiertool shots [--out folder]      (default: docs/screenshots, copied to site/img)

import "core:fmt"
import "core:os"
import "core:strings"
import cdp "gt:cdp"

SHOTS_DIR     :: "build/shots"
SHOTS_PORT    :: 9362
SHOTS_OUT     :: "docs/screenshots"
SHOTS_SITE    :: "site/img"

// What is copied, oldest first (the last one is on top of the list).
@(private = "file")
Sample :: struct { text, mime, file, seen: string }

@(private = "file")
SAMPLES :: [?]Sample{
	{text = "SELECT name, email FROM users\nWHERE created_at > now() - interval '7 days'\nORDER BY created_at DESC;", seen = "SELECT name, email"},
	{text = "Meeting moved to Thursday 10:00, room B. Bring the printed agenda and the budget figures.", seen = "Meeting moved"},
	{text = "<h2>Release notes</h2><p>Papier <b>0.1.0</b> keeps the clipboard's history: text, rich text, images and files.</p>", mime = "text/html", seen = "Release notes"},
	{text = "file:///home/ada/Documents/report-2026.pdf\r\nfile:///home/ada/Pictures/harbour.jpg\r\n", mime = "text/uri-list", seen = "report-2026.pdf"},
	{text = "https://github.com/sachahjkl/papier", seen = "github.com/sachahjkl/papier"},
	{mime = "image/png", file = "assets/logo_256.png", seen = "image/png 256 × 256"},
	{text = "#!/usr/bin/env bash\nset -euo pipefail\nfor f in *.png; do\n  magick \"$f\" -resize 50% \"small-$f\"\ndone", seen = "#!/usr/bin/env bash"},
	{text = "proc fibonacci(n: u64) -> u64 {\n\tif n < 2 { return n }\n\treturn fibonacci(n - 1) + fibonacci(n - 2)\n}", seen = "proc fibonacci"},
}

run_shots :: proc(args: []string) -> int {
	out := SHOTS_OUT
	if len(args) == 2 && args[0] == "--out" { out = args[1] }
	if run_build({"release"}) != 0 { return 1 }
	s: Session
	defer session_stop(&s)
	if why := session_start(&s, SHOTS_DIR, SHOTS_PORT, {"picker.mode\tdark"}); why != "" { fmt.eprintfln("papiertool shots: %s", why); return 1 }
	samples := SAMPLES
	for x in samples {
		if !copy_and_wait(&s, x.text, x.mime, x.file, x.seen) { fmt.eprintfln("papiertool shots: %q did not reach the history", x.seen); return 1 }
	}
	// the address pinned
	list, _ := run_in(&s, PROGRAM, "list", "100")
	rest := list
	for line in strings.split_lines_iterator(&rest) {
		if strings.contains(line, "github.com/sachahjkl/papier") { _, _ = run_in(&s, PROGRAM, "pin", strings.split(line, "\t", context.temp_allocator)[0]) }
	}

	_ = os.make_directory_all(out)
	_, _ = run_in(&s, PROGRAM, "show")
	c, ok := window_connect(&s)
	if !ok { fmt.eprintln("papiertool shots: the window does not answer"); return 1 }
	defer cdp.close(&c)
	failed := false
	shot :: proc(c: ^cdp.Client, out, name: string, failed: ^bool) {
		cdp.wait_idle(c, SESSION_WAIT)
		path := fmt.tprintf("%s/%s.png", out, name)
		if cdp.shot(c, path) { fmt.printfln("wrote %s", path) } else { failed^ = true }
	}
	cdp.wait_for(&c, "proc fibonacci", SESSION_WAIT)
	shot(&c, out, "main", &failed)
	cdp.key(&c, "Tab")
	cdp.key(&c, "Tab")   // Images
	cdp.wait_for(&c, "image/png 256 × 256", SESSION_WAIT)
	shot(&c, out, "images", &failed)
	cdp.key(&c, "shift+Tab")
	cdp.key(&c, "shift+Tab")   // All
	cdp.type_text(&c, "release")
	cdp.wait_for(&c, "proc fibonacci", SESSION_WAIT, gone = true)
	shot(&c, out, "search", &failed)
	// the entry's menu, then the edit view, on the first entry
	cdp.key(&c, "Escape")   // (the search, cleared)
	cdp.wait_for(&c, "proc fibonacci", SESSION_WAIT)
	cdp.key(&c, "ContextMenu")
	cdp.wait_for(&c, "Open with", SESSION_WAIT)
	shot(&c, out, "menu", &failed)
	cdp.key(&c, "Escape")
	cdp.wait_for(&c, "Open with", SESSION_WAIT, gone = true)
	cdp.key(&c, "ctrl+e")
	cdp.wait_for(&c, "Editing", SESSION_WAIT)
	shot(&c, out, "edit", &failed)
	cdp.key(&c, "Escape")
	cdp.wait_for(&c, "Editing", SESSION_WAIT, gone = true)
	// the command palette, searched
	cdp.key(&c, "ctrl+k")
	cdp.wait_for(&c, "Keyboard shortcuts", SESSION_WAIT)
	cdp.type_text(&c, "theme")
	cdp.wait_for(&c, "Show every entry", SESSION_WAIT, gone = true)
	shot(&c, out, "palette", &failed)
	// a setting chosen: the settings, on it alone
	cdp.key(&c, "Enter")
	if !cdp.wait_for(&c, "The window's colours", SESSION_WAIT) { fmt.eprintln("papiertool shots: the palette's setting did not open the settings"); failed = true }
	cdp.key(&c, "ctrl+,")
	cdp.wait_for(&c, "The window's colours", SESSION_WAIT, gone = true)
	// the address as a QR code
	cdp.type_text(&c, "github")
	cdp.wait_for(&c, "proc fibonacci", SESSION_WAIT, gone = true)
	cdp.key(&c, "ctrl+shift+q")
	shot(&c, out, "qr", &failed)
	cdp.key(&c, "Escape")
	cdp.key(&c, "Escape")   // (the search, cleared)
	cdp.wait_for(&c, "proc fibonacci", SESSION_WAIT)
	// the settings
	cdp.key(&c, "ctrl+,")
	cdp.wait_for(&c, "Max entries", SESSION_WAIT, gone = true)   // (the first page: Appearance)
	cdp.wait_for(&c, "Theme", SESSION_WAIT)
	shot(&c, out, "settings", &failed)
	cdp.key(&c, "ctrl+,")
	cdp.close(&c)

	_, _ = run_in(&s, PROGRAM, "set", "picker.mode", "light")
	_, _ = run_in(&s, PROGRAM, "hide")
	_, _ = run_in(&s, PROGRAM, "show")
	if lc, lok := window_connect(&s); lok {
		cdp.wait_for(&lc, "proc fibonacci", SESSION_WAIT)
		shot(&lc, out, "light", &failed)
		cdp.close(&lc)
	} else {
		failed = true
	}
	if failed { return 1 }

	// the site shows the same pictures
	_ = os.make_directory_all(SHOTS_SITE)
	for name in ([]string{"main", "images", "search", "menu", "edit", "palette", "qr", "settings", "light"}) {
		data, err := os.read_entire_file(fmt.tprintf("%s/%s.png", out, name), context.temp_allocator)
		if err == nil { _ = os.write_entire_file(fmt.tprintf("%s/%s.png", SHOTS_SITE, name), data) }
	}
	return 0
}
