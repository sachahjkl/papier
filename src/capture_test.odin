package papier

import "core:testing"
import "history"

@(private = "file")
ALL :: Capture_Options{text = true, html = true, image = true, files = true, ignore_secrets = true}

// A browser's copy: the UTF-8 text is read as the stored text type, the HTML beside it, the rest is left.
@(test)
a_browser_copy_reads_text_and_html :: proc(t: ^testing.T) {
	p := plan_capture({"text/_moz_htmlcontext", "text/html", "text/plain;charset=utf-8", "text/plain", "UTF8_STRING"}, ALL)
	testing.expect_value(t, p.skip, Skip.None)
	testing.expect_value(t, p.count, 2)
	testing.expect_value(t, p.wanted[0], Wanted{"text/plain;charset=utf-8", TEXT_MIME})
	testing.expect_value(t, p.wanted[1], Wanted{HTML_MIME, HTML_MIME})
}

// An X11 program's text (through XWayland) is stored under the UTF-8 type.
@(test)
an_x11_text_is_stored_as_utf8 :: proc(t: ^testing.T) {
	p := plan_capture({"UTF8_STRING", "STRING", "TARGETS"}, ALL)
	testing.expect_value(t, p.count, 1)
	testing.expect_value(t, p.wanted[0], Wanted{"UTF8_STRING", TEXT_MIME})
}

// A password manager's secret, a type the user ignores, a type nobody wants: nothing is read.
@(test)
secrets_and_ignored_types_are_skipped :: proc(t: ^testing.T) {
	testing.expect_value(t, plan_capture({"text/plain", SECRET_HINT_MIME}, ALL).skip, Skip.Secret)
	o := ALL
	ignore := []string{"application/x-thing"}
	o.ignore_mimes = ignore
	testing.expect_value(t, plan_capture({"text/plain", "application/x-thing"}, o).skip, Skip.Ignored)
	testing.expect_value(t, plan_capture({"application/octet-stream"}, ALL).skip, Skip.Nothing_Wanted)
	testing.expect_value(t, plan_capture(nil, ALL).skip, Skip.Empty)
	o = ALL
	o.ignore_secrets = false
	testing.expect_value(t, plan_capture({"text/plain", SECRET_HINT_MIME}, o).skip, Skip.None)
}

// Files win over the text a file manager gives with them; an image with only HTML beside it is an image; text with HTML
// is rich text keyed by its text.
@(test)
classify_picks_the_main_representation :: proc(t: ^testing.T) {
	files := []history.Rep_Data{{"text/uri-list", transmute([]u8)string("file:///tmp/a%20b\r\n")}, {TEXT_MIME, transmute([]u8)string("/tmp/a b")}}
	kind, main, preview, ok := classify(files)
	testing.expect(t, ok)
	testing.expect_value(t, kind, history.Kind.Files)
	testing.expect_value(t, main, 0)
	testing.expect_value(t, preview, "/tmp/a b")

	png := []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 3, 0, 0, 0, 2}
	image := []history.Rep_Data{{HTML_MIME, transmute([]u8)string("<img src=x>")}, {"image/png", png}}
	kind, main, preview, ok = classify(image)
	testing.expect_value(t, kind, history.Kind.Image)
	testing.expect_value(t, main, 1)
	testing.expect_value(t, preview, "image/png 3 × 2")

	rich := []history.Rep_Data{{TEXT_MIME, transmute([]u8)string("bold")}, {HTML_MIME, transmute([]u8)string("<b>bold</b>")}}
	kind, main, _, ok = classify(rich)
	testing.expect_value(t, kind, history.Kind.Html)
	testing.expect_value(t, main, 0)

	_, _, _, ok = classify([]history.Rep_Data{{TEXT_MIME, transmute([]u8)string("  \n")}})
	testing.expect(t, !ok, "blank text is not an entry")
}

@(test)
html_without_text_is_read_without_its_tags :: proc(t: ^testing.T) {
	testing.expect_value(t, strip_tags("<p>one\n  <b>two</b></p>"), "one two")
}

// A program that offers its markup as text too (wl-copy -t text/html): the entry is HTML, keyed and previewed by it.
@(test)
markup_offered_as_text_is_html :: proc(t: ^testing.T) {
	markup := transmute([]u8)string("<p>rich <b>bold</b></p>")
	reps := []history.Rep_Data{{TEXT_MIME, markup}, {HTML_MIME, markup}}
	kind, main, preview, ok := classify(reps)
	testing.expect(t, ok)
	testing.expect_value(t, kind, history.Kind.Html)
	testing.expect_value(t, main, 1)
	testing.expect_value(t, preview, "rich bold")
}

@(test)
commands_read_back :: proc(t: ^testing.T) {
	for c in ([]Command{{.Copy, 42}, {.Clear, 0}, {.Pin, 7}}) {
		back, ok := command_parse(command_format(c))
		testing.expect(t, ok)
		testing.expect_value(t, back, c)
	}
	_, ok := command_parse("copy")
	testing.expect(t, !ok, "copy needs an id")
	_, ok = command_parse("clear 3")
	testing.expect(t, !ok, "clear takes none")
}
