package papier

// What a copy is worth recording, and as what. Pure: the daemon gives the MIME types a selection offers and the bytes it
// read; this file says which types to read, what kind of entry they make, its key and its preview, and which types an
// entry is served under when it goes back on the clipboard.

import "core:fmt"
import "core:strings"
import "gt:platform"
import "history"

// The text types, best first. The first is the one an entry stores; the others are aliases for older programs (X11
// through XWayland).
TEXT_MIMES  :: [?]string{"text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT"}
TEXT_MIME   :: "text/plain;charset=utf-8"
HTML_MIME   :: "text/html"
FILES_MIMES :: [?]string{"text/uri-list", "x-special/gnome-copied-files"}
// Image types, best first: one is kept as offered (PNG keeps alpha; a screenshot tool or a browser offers PNG).
IMAGE_MIMES :: [?]string{"image/png", "image/webp", "image/jpeg", "image/gif", "image/bmp", "image/x-bmp", "image/svg+xml"}
// What KeePassXC and other password managers set on a secret (KDE's convention).
SECRET_HINT_MIME :: "x-kde-passwordManagerHint"

Capture_Options :: struct {
	text, html, image, files: bool,
	ignore_secrets:           bool,
	ignore_mimes:             []string,   // a selection that offers one of these is not recorded
}

Skip :: enum u8 { None, Empty, Secret, Ignored, Nothing_Wanted }

// One type to read, and the type the entry stores it under.
Wanted :: struct { read, store: string }

Plan :: struct {
	wanted: [4]Wanted,
	count:  int,
	skip:   Skip,
}

// Which types of a selection offering `offered` are read (at most one text, one HTML, one image, one file list).
plan_capture :: proc(offered: []string, o: Capture_Options) -> (p: Plan) {
	if len(offered) == 0 { p.skip = .Empty; return }
	if o.ignore_secrets && has_mime(offered, SECRET_HINT_MIME) { p.skip = .Secret; return }
	for m in o.ignore_mimes { if m != "" && has_mime(offered, m) { p.skip = .Ignored; return } }
	add :: proc(p: ^Plan, read, store: string) { p.wanted[p.count] = {read, store}; p.count += 1 }
	if o.files {
		files := FILES_MIMES
		if m := first_of(offered, files[:]); m != "" { add(&p, m, m) }
	}
	if o.text {
		texts := TEXT_MIMES
		if m := first_of(offered, texts[:]); m != "" { add(&p, m, TEXT_MIME) }
	}
	if o.html && has_mime(offered, HTML_MIME) { add(&p, HTML_MIME, HTML_MIME) }
	if o.image {
		images := IMAGE_MIMES
		m := first_of(offered, images[:])
		if m == "" { for x in offered { if strings.has_prefix(x, "image/") { m = x; break } } }
		if m != "" { add(&p, m, m) }
	}
	if p.count == 0 { p.skip = .Nothing_Wanted }
	return
}

// What the representations read make: the kind, the representation that is the key, the preview. ok = false when they
// hold nothing worth an entry (an empty text, no bytes).
classify :: proc(reps: []history.Rep_Data, allocator := context.temp_allocator) -> (kind: history.Kind, main: int, preview: string, ok: bool) {
	files, text, html, image := -1, -1, -1, -1
	for r, i in reps {
		if len(r.data) == 0 { continue }
		switch {
		case r.mime == TEXT_MIME:                 text = i
		case r.mime == HTML_MIME:                 html = i
		case strings.has_prefix(r.mime, "image/"): image = i
		case is_files_mime(r.mime):               files = i
		}
	}
	// a program that offers its markup as text too (wl-copy -t text/html does): the entry is the HTML
	if text >= 0 && html >= 0 && string(reps[text].data) == string(reps[html].data) { text = -1 }
	switch {
	case files >= 0:
		paths := platform.uri_list_to_paths(string(reps[files].data), allocator)
		if len(paths) == 0 { break }
		return .Files, files, strings.join(paths, "\n", allocator), true
	case text >= 0 && strings.trim_space(string(reps[text].data)) != "":
		return html >= 0 ? .Html : .Text, text, string(reps[text].data), true
	case image >= 0:
		w, h := image_size(reps[image].data)
		if w > 0 { return .Image, image, fmt.aprintf("%s %d × %d", reps[image].mime, w, h, allocator = allocator), true }
		return .Image, image, reps[image].mime, true
	case html >= 0:
		return .Html, html, strip_tags(string(reps[html].data), allocator), true
	}
	return .Other, -1, "", false
}

// The types an entry goes back on the clipboard under: each stored type, and the aliases of its text.
served_mimes :: proc(rep_mime: string) -> []string {
	if rep_mime == TEXT_MIME { return text_aliases[:] }
	return nil
}

@(private = "file", rodata) text_aliases := TEXT_MIMES

is_files_mime :: proc(m: string) -> bool {
	files := FILES_MIMES
	return has_mime(files[:], m)
}

has_mime :: proc(list: []string, m: string) -> bool {
	for x in list { if x == m { return true } }
	return false
}

first_of :: proc(offered, wanted: []string) -> string {
	for w in wanted { if has_mime(offered, w) { return w } }
	return ""
}

// The size of a PNG from its header (0, 0 when it is not one). Other formats: 0, 0 (the picker decodes them).
image_size :: proc(b: []u8) -> (w, h: int) {
	PNG_SIGNATURE :: "\x89PNG\r\n\x1a\n"
	if len(b) < 24 || string(b[:8]) != PNG_SIGNATURE || string(b[12:16]) != "IHDR" { return }
	be :: proc(b: []u8) -> int { return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3]) }
	return be(b[16:20]), be(b[20:24])
}

// The text of HTML without its tags, its blanks run together (for a preview: the entities stay as they are).
strip_tags :: proc(html: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	in_tag, blank := false, false
	for c in html {
		switch {
		case c == '<': in_tag = true
		case c == '>': in_tag = false
		case in_tag:
		case c == ' ' || c == '\n' || c == '\t' || c == '\r':
			blank = strings.builder_len(b) > 0
		case:
			if blank { strings.write_byte(&b, ' '); blank = false }
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}
