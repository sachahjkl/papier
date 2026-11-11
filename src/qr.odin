package papier

// An entry as a QR code (Ctrl+Shift+Q, the entry's menu, the palette): its text in a dialog, for a phone's camera. A text
// holds at most QR_MAX_BYTES (a QR code at its largest, with medium error correction, holds 2331 bytes; a phone reads a
// smaller one better).

import "core:fmt"
import "core:strings"
import "gt:ui"
import "history"

QR_MAX_BYTES :: 1200

Qr_View :: struct {
	open: bool,
	text: string,   // owned
}

// The text an entry's code would hold ("" when it has none, or too much): a text, an address, a file's path.
qr_text :: proc(app: ^App, e: ^history.Entry) -> string {
	t: string
	switch e.kind {
	case .Text, .Html: t = entry_text(app, e)
	case .Files:       t = e.preview
	case .Image, .Other:
	}
	t = strings.trim_space(t)
	return len(t) <= QR_MAX_BYTES ? t : ""
}

qr_open :: proc(app: ^App, e: ^history.Entry) {
	delete(app.qr.text)
	app.qr.text = strings.clone(qr_text(app, e))
	app.qr.open = app.qr.text != ""
}

qr_destroy :: proc(app: ^App) {
	delete(app.qr.text)
	app.qr = {}
}

// The dialog, while it is open: the code, as large as the window allows, the text under it.
qr_build :: proc(app: ^App, em: f32) {
	if !app.qr.open { return }
	side := clamp(min(app.room, f32(app.settings.size.y)) * 0.6, em * 12, em * 26)
	if ui.modal("###qr", side + em * 3, &app.qr.open) {
		ui.spacer(ui.px(em * 1.2))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row() {
			ui.spacer(ui.px(em * 1.5))
			// (dark on white, its quiet zone included, whatever the theme: a camera reads that)
			ui.qr_code("###qr_code", app.qr.text, side)
		}
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), font_size = em * 0.85, text_align = .Center})
			ui.paragraph(fmt.tprintf("%s###qr_words", shown_text(one_line(app.qr.text, 160))))
		}
		ui.spacer(ui.px(em * 1))
	}
}
