package papier

// Mermaid diagrams in a Markdown entry: a ```mermaid block is drawn as its diagram (gt:mermaid lays it out, gt:svg draws it
// with the window's paths and fonts). The layout takes milliseconds: the reader does it once, with the load, for the light
// and the dark theme, so the window only draws (no layout at each frame, none on the window's thread, none again when the
// theme changes). A block that is no diagram shows its text, with why.

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:font"
import "gt:markdown"
import mermaid "gt:mermaid"
import svg "gt:svg"
import i18n "gt:i18n"
import "gt:ui"

// A ```mermaid block of the loaded entry, laid out by the reader (heap; diagrams_free).
Diagram :: struct {
	code:        string,         // the block's text as the doc keeps it: the view finds the diagram by where it lies
	light, dark: svg.Document,
	why:         string,         // not a diagram: what mermaid says ("" it is one)
}

// The diagrams laid out for one entry, at most (each takes milliseconds; the blocks past it show as code).
DIAGRAMS_MAX :: 32
// Mermaid draws its text at 14 px: at this scale it is as large as the text around it.
DIAGRAM_FONT_PX :: 14

// The reader's side: each closed ```mermaid block of `doc` laid out, in the reader's heap.
diagrams_make :: proc(doc: ^markdown.Doc) -> []Diagram {
	out := make([dynamic]Diagram)
	for bl, n in doc.blocks {
		if bl.kind != .Code || !bl.closed || !is_mermaid(bl.lang) { continue }
		if len(out) >= DIAGRAMS_MAX { break }
		// (block_text keeps the text in the doc: the view gets the same string back, at the same place)
		code := markdown.block_text(doc, n)
		d := Diagram{code = code}
		why: string
		d.light, why = mermaid.diagram(code, false)
		if why == "" { d.dark, why = mermaid.diagram(code, true) }
		if why != "" {
			svg.destroy(&d.light)
			d.why = strings.clone(first_line(why))
		}
		append(&out, d)
	}
	return out[:]
}

diagrams_free :: proc(ds: []Diagram) {
	for &d in ds {
		svg.destroy(&d.light)
		svg.destroy(&d.dark)
		delete(d.why)
	}
	delete(ds)
}

// "mermaid" after a fence, in any case, with or without words after it.
is_mermaid :: proc(lang: string) -> bool {
	word := lang
	if i := strings.index_any(word, " \t{"); i >= 0 { word = word[:i] }
	return strings.equal_fold(word, "mermaid")
}

@(private = "file")
first_line :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.index_byte(t, '\n'); i >= 0 { t = strings.trim_space(t[:i]) }
	return t
}

// The diagram of a block's text: matched by where the text lies (the doc gives the text the reader laid out), else by its
// content (a doc that made the text again).
diagram_find :: proc(ds: []Diagram, code: string) -> ^Diagram {
	for &d in ds {
		if raw_data(d.code) == raw_data(code) && len(d.code) == len(code) { return &d }
	}
	for &d in ds {
		if d.code == code { return &d }
	}
	return nil
}

// What the Markdown view's procedures are given: the window and the room the text has (this frame's).
Markdown_User :: struct {
	app:   ^App,
	loaded: ^Loaded_Entry,
	width: f32,   // the column's width in pixels
	cfg:   markdown.Config,
}

// A fenced block of the Markdown shown: a diagram, or (not a diagram, too many of them, another language) its code.
markdown_code :: proc(user: rawptr, id: string, c: markdown.Code) {
	u := (^Markdown_User)(user)
	if !is_mermaid(c.lang) { markdown.code_block(id, c, u.cfg); return }
	d := diagram_find(u.loaded.diagrams, c.text)
	if d != nil && d.why == "" {
		diagram_box(u, d, id)
		return
	}
	if d != nil {
		if ui.tags("warn") {
			ui.next({width = ui.fill(), text_pad = 0})
			ui.paragraph(fmt.tprintf("%s###%s_why", fmt.tprintf(i18n.tr("Not a diagram: %s"), d.why), id))
		}
		ui.spacer(ui.px(math.round(ui.font_size() * 0.3)))
	}
	markdown.code_block(id, c, u.cfg)
}

@(private = "file")
Diagram_Draw :: struct { doc: ^svg.Document, scale: f32, regular, bold: font.Font_Id }

// The diagram as large as the text around it, never wider than the column, centred.
@(private = "file")
diagram_box :: proc(u: ^Markdown_User, d: ^Diagram, id: string) {
	app := u.app
	em := ui.font_size()
	doc := app.theme_shown.light ? &d.light : &d.dark
	scale := min(em / DIAGRAM_FONT_PX, max(u.width, em * 8) / max(doc.view[2], 1))
	sz := svg.size(doc, scale)
	ui.next({width = ui.fill(), height = ui.px(math.ceil(sz.y)), axis = .X})
	if ui.row(id = fmt.tprintf("%s_diagram_row", id)) {
		ui.spacer(ui.fill())
		dd := ui.frame_new(Diagram_Draw)
		dd^ = {doc = doc, scale = scale, regular = app.shared.font, bold = ui.styled_face(app.shared.font, true, false)}
		ui.a11y({role = .Image, name = i18n.tr("A diagram")})
		ui.next({width = ui.px(math.ceil(sz.x)), height = ui.px(math.ceil(sz.y))})
		ui.custom(fmt.tprintf("%s_diagram", id), diagram_draw, dd)
		ui.spacer(ui.fill())
	}
}

@(private = "file")
diagram_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	dd := (^Diagram_Draw)(user)
	svg.draw_doc(dc, dd.doc, b.rect.min, dd.scale, {regular = dd.regular, bold = dd.bold})
}
