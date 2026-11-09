package papier

// The window's interface: the title bar is the window's own (search, filters, close), then the list of the history and
// the selected entry in full beside it, then a status bar.
//
//   typing                  filters (every word must be in the entry, case ignored)
//   Tab / Shift+Tab         the next / previous filter (All, Text, Images, Files, Pinned)
//   Up / Down, Page Up / Page Down, Ctrl+Home / Ctrl+End    move in the list
//   Enter, a double click   put the entry back on the clipboard (and hide)
//   Alt+1 .. Alt+9          the same for the first nine entries shown
//   Ctrl+P                  pin or unpin (pinned entries stay whatever the limits)
//   Shift+Delete            remove the entry
//   Escape                  clear the search, else hide

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "gt:draw"
import "gt:host"
import "gt:platform"
import "gt:render"
import "gt:ui"
import "history"

// What the preview reads of a text, at most.
VIEW_TEXT_MAX_BYTES :: 16 * 1024
// Rows Page Up / Page Down move by.
PAGE_ROWS :: 10
// Builds a selected row is pulled into view for (as the list's own keys do).
REVEAL_BUILDS :: 3
// The list's width when none was chosen, of the window's; its least and the preview's least, in logical pixels.
LIST_SHARE    :: 0.48
LIST_MIN_PX   :: 220
VIEW_MIN_PX   :: 200
// The heights of the bars and the rows, in ems.
TITLE_EM  :: 2.7
FILTER_EM :: 23   // the filter's segmented control
ROW_EM    :: 2.05
STATUS_EM :: 1.9
// The grip between the search and the filters: its width in ems, its lines' share of the bar's height, their spacing in
// logical pixels and their opacity (of the weak text's colour).
GRIP_EM     :: 2.4
GRIP_HEIGHT :: 0.36
GRIP_GAP_PX :: 4
GRIP_ALPHA  :: 0.7

KIND_ICONS := [history.Kind]string{.Text = ICO_TEXT, .Html = ICO_RICH, .Image = ICO_IMAGE, .Files = ICO_FILES, .Other = ICO_DATA}
KIND_LABELS := [history.Kind]string{.Text = "Text", .Html = "Rich text", .Image = "Image", .Files = "Files", .Other = "Data"}

// The selected entry, read in full for the preview.
View :: struct {
	id:      u64,
	loaded:  bool,
	text:    string,            // owned
	tex:     render.Texture,
	size:    [2]int,
	has_tex: bool,
	loading: bool,              // its picture is being decoded (decoder.odin)
	image:   int,               // the representation of the picture, in the entry's reps
}

////////////////////////////////
// The list and the search

// Whether an entry passes the filter.
@(private = "file")
filter_keeps :: proc(f: Filter, e: history.Entry) -> bool {
	switch f {
	case .All:    return true
	case .Text:   return e.kind == .Text || e.kind == .Html
	case .Images: return e.kind == .Image
	case .Files:  return e.kind == .Files
	case .Pinned: return e.pinned
	}
	return true
}

// The entries that pass the filter and hold every word of the search, in the history's order.
refilter :: proc(app: ^App) {
	if len(app.lowered) != len(app.store.entries) {
		for s in app.lowered { delete(s) }
		clear(&app.lowered)
		for e in app.store.entries { append(&app.lowered, strings.to_lower(e.preview)) }
	}
	words := strings.fields(strings.to_lower(app.query, context.temp_allocator), context.temp_allocator)
	clear(&app.shown)
	clear(&app.ids)
	outer: for e, i in app.store.entries {
		if !filter_keeps(app.filter, e) { continue }
		for w in words { if !strings.contains(app.lowered[i], w) { continue outer } }
		append(&app.shown, i)
		append(&app.ids, e.id)
	}
	app.vl.sel = len(app.shown) > 0 ? clamp(app.vl.sel, 0, len(app.shown) - 1) : -1
}

selected :: proc(app: ^App) -> ^history.Entry {
	if app.vl.sel < 0 || app.vl.sel >= len(app.shown) { return nil }
	return &app.store.entries[app.shown[app.vl.sel]]
}

selected_id :: proc(app: ^App) -> u64 {
	e := selected(app)
	return e != nil ? e.id : 0
}

select_row :: proc(app: ^App, row: int) {
	if len(app.shown) == 0 { return }
	app.vl.sel = clamp(row, 0, len(app.shown) - 1)
	app.vl.reveal = REVEAL_BUILDS
}

@(private = "file")
set_filter :: proc(app: ^App, f: Filter) {
	if app.filter == f { return }
	app.filter = f
	refilter(app)
	select_row(app, 0)
	ui.vlist_scroll_to(&app.vl, 0)
}

// Puts the entry back on the clipboard (the watcher serves it) and hides the window.
@(private = "file")
copy_entry :: proc(app: ^App, id: u64) {
	watcher_send(&app.watcher, {verb = .Copy, id = id})
	if app.settings.close_on_copy { app_hide(app) } else { say(app, "Copied") }
}

@(private = "file")
toggle_pin :: proc(app: ^App, e: ^history.Entry) {
	watcher_send(&app.watcher, {verb = e.pinned ? .Unpin : .Pin, id = e.id})
	e.pinned = !e.pinned   // (shown at once; the watcher's index says the same at the next reload)
}

@(private = "file")
remove_entry :: proc(app: ^App, id: u64) {
	watcher_send(&app.watcher, {verb = .Delete, id = id})
	at := history.find(&app.store, id)
	if at < 0 { return }
	history.remove(&app.store, id)
	delete(app.lowered[at])
	ordered_remove(&app.lowered, at)
	refilter(app)
}

// The keys of the window, taken before the search field sees them.
@(private = "file")
view_keys :: proc(app: ^App) {
	if ui.key_press(.Down) || ui.key_press(.N, {.Ctrl}) { select_row(app, app.vl.sel + 1) }
	if ui.key_press(.Up) || ui.key_press(.P, {.Alt}) { select_row(app, app.vl.sel - 1) }
	if ui.key_press(.Page_Down) { select_row(app, app.vl.sel + PAGE_ROWS) }
	if ui.key_press(.Page_Up) { select_row(app, app.vl.sel - PAGE_ROWS) }
	if ui.key_press(.Home, {.Ctrl}) { select_row(app, 0) }
	if ui.key_press(.End, {.Ctrl}) { select_row(app, len(app.shown) - 1) }
	if ui.key_press(.Tab) { set_filter(app, Filter((int(app.filter) + 1) % len(Filter))) }
	if ui.key_press(.Tab, {.Shift}) { set_filter(app, Filter((int(app.filter) + len(Filter) - 1) % len(Filter))) }
	if ui.key_press(.Return) { if e := selected(app); e != nil { copy_entry(app, e.id) } }
	digits := [9]platform.Key{.N1, .N2, .N3, .N4, .N5, .N6, .N7, .N8, .N9}
	for k, i in digits {
		if ui.key_press(k, {.Alt}) && i < len(app.shown) { copy_entry(app, app.store.entries[app.shown[i]].id) }
	}
	if ui.key_press(.P, {.Ctrl}) { if e := selected(app); e != nil { toggle_pin(app, e) } }
	if ui.key_press(.Delete, {.Shift}) { if e := selected(app); e != nil { remove_entry(app, e.id) } }
	if ui.key_press(.Escape) {
		if len(app.search.buf) > 0 { ui.field_clear(&app.search) } else { app_hide(app) }
	}
}

////////////////////////////////
// The window

view_build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	em := ui.font_size()
	app.room = size.x / max(ui.scale(), 0.01)
	if app.search_key != 0 && ui.focus_key() != app.search_key { ui.set_focus(app.search_key) }
	view_keys(app)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if ui.parent(page) { build_page(app, em) }
}

@(private = "file")
build_page :: proc(app: ^App, em: f32) {
	build_title(app, em)
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row() { build_body(app, em) }
	ui.hline(ui.fill())
	build_status(app, em)
}

// An icon of Lucide, `size` ems wide.
@(private = "file")
glyph :: proc(app: ^App, g: string, width: f32, fg: Maybe(ui.Color) = nil) {
	ui.next({width = ui.px(width), height = ui.pct(1), font = app.icons, text_align = .Center, fg = fg})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###g%d", g, ui.parent_box().child_count))
}

// A small button with a Lucide icon; its tooltip says what it does.
@(private = "file")
icon_action :: proc(app: ^App, id, g, tip: string, em: f32) -> bool {
	ui.next({width = ui.px(em * 2.1), height = ui.px(em * 2.1), font = app.icons, radius = em * 0.4})
	sig: ui.Signal
	if ui.tags("ghost_button") { sig = ui.button(fmt.tprintf("%s###%s", g, id)) }
	if ui.hovered_for(sig, 0.4) {
		if ui.tooltip() {
			ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 1.8))})
			ui.label(fmt.tprintf("%s###tip", tip))
		}
	}
	return sig.clicked
}

@(private = "file")
build_title :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * TITLE_EM))})
	if ui.title_bar("###titlebar") {
		ui.spacer(ui.px(em * 0.5))
		glyph(app, ICO_CLIPBOARD, em * 1.8, ui.color("accent"))
		ui.spacer(ui.px(em * 0.3))
		// the search: a field with its icon, as wide as the title leaves
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.95)), radius = em * 0.45})
		if ui.row(.Center, {.Draw_Background, .Draw_Border}, "###searchbox") {
			if ui.tags("weak") { glyph(app, ICO_SEARCH, em * 1.9) }
			ui.next({width = ui.fill(), height = ui.pct(1)})
			if ui.tags("bare") {
				res := ui.line_edit("###search", &app.search, "Search the history")
				app.search_key = res.box.key
			}
		}
		if q := ui.field_string(&app.search); q != app.query {
			delete(app.query)
			app.query = strings.clone(q)
			refilter(app)
			select_row(app, 0)
			ui.vlist_scroll_to(&app.vl, 0)
		}
		// a grip between the search and the filters: the window is moved from there (an empty part of the title bar)
		d := ui.frame_new(Grip_Draw)
		d^ = {ui.color("weak"), ui.scale()}
		ui.next({width = ui.px(em * GRIP_EM), height = ui.pct(1)})
		ui.custom("###grip", grip_draw, d)
		ui.next({width = ui.px(em * FILTER_EM), height = ui.px(ui.dense(em * 1.95))})
		sel := int(app.filter)
		if ui.segmented("###filter", filter_labels[:], &sel) { set_filter(app, Filter(sel)) }
		ui.spacer(ui.px(em * 0.3))
		if icon_action(app, "close", ICO_CLOSE, "Hide (Escape)", em) { app_hide(app) }
		ui.spacer(ui.px(em * 0.4))
	}
}

@(private = "file")
Grip_Draw :: struct { color: ui.Color, scale: f32 }

// Three short vertical lines in the middle of the grip, faint: they say "hold here" without drawing the eye.
@(private = "file")
grip_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Grip_Draw)(user)
	c := d.color
	c.a *= GRIP_ALPHA
	mid := (b.rect.min + b.rect.max) * 0.5
	w, gap := max(1, d.scale), GRIP_GAP_PX * d.scale
	h := (b.rect.max.y - b.rect.min.y) * GRIP_HEIGHT
	for i in -1 ..= 1 {
		x := mid.x + f32(i) * gap - w * 0.5
		draw.rect(dc, {{x, mid.y - h * 0.5}, {x + w, mid.y + h * 0.5}}, c, radius = w * 0.5)
	}
}

@(private = "file")
build_body :: proc(app: ^App, em: f32) {
	scale := ui.scale()
	room := app.room   // the window's width, logical pixels
	if app.place.split <= 0 { app.place.split = max(room * LIST_SHARE, LIST_MIN_PX) }
	app.place.split = clamp(app.place.split, LIST_MIN_PX, max(room - VIEW_MIN_PX, LIST_MIN_PX))   // (a window made narrower)
	ui.next({width = ui.px(app.place.split * scale), height = ui.fill()})
	build_list(app, em)
	ui.splitter("###split", .X, &app.place.split, LIST_MIN_PX, max(room - VIEW_MIN_PX, LIST_MIN_PX), {default_size = room * LIST_SHARE, total = room, min_other = VIEW_MIN_PX})
	ui.next({width = ui.fill(), height = ui.fill()})
	build_view(app, em)
}

@(private = "file")
build_list :: proc(app: ^App, em: f32) {
	rows, ok := ui.vlist("###list", &app.vl, app.ids[:])
	if !ok { return }
	now := now_ms()
	for i in rows.first ..< rows.last {
		e := &app.store.entries[app.shown[i]]
		ui.next({height = ui.px(ui.dense(em * ROW_EM))})
		row := ui.list_row(&app.vl, i, "")
		if ui.parent(row.box) {
			ui.spacer(ui.px(em * 0.35))
			if ui.tags("weak") { glyph(app, KIND_ICONS[e.kind], em * 1.9) }
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(fmt.tprintf("%s###t", shown_text(one_line(e.preview, 200))))
			if e.pinned { glyph(app, ICO_PIN, em * 1.6, ui.color("accent")) }
			if i < 9 && len(app.query) == 0 {
				if ui.tags("weak") {
					ui.next({width = ui.text_size(em * 0.3), height = ui.pct(1)})
					if ui.style({font_size = em * 0.8}) { ui.label(fmt.tprintf("Alt+%d###n", i + 1)) }
				}
			}
			if ui.tags("weak") {
				ui.next({width = ui.text_size(em * 0.5), height = ui.pct(1)})
				if ui.style({font_size = em * 0.85}) { ui.label(fmt.tprintf("%s###a", age_text(now - e.time_ms))) }
			}
		}
		if row.double_clicked { copy_entry(app, e.id) }
	}
	if len(app.shown) == 0 {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 5)})
			if ui.style({text_align = .Center}) {
				ui.label(len(app.store.entries) == 0 ? "Nothing copied yet: copy something, it shows here.###empty" : "No entry matches.###empty")
			}
		}
	}
}

@(private = "file")
build_status :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * STATUS_EM))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.7))
		if ui.style({font_size = em * 0.88}) {
			if ui.tags("weak") {
				ui.next({width = ui.fill()})
				msg := app.status
				if msg == "" || ui.now_ms() > app.status_until {
					pinned := 0
					for e in app.store.entries { if e.pinned { pinned += 1 } }
					msg = fmt.tprintf("%d of %d entries · %d pinned", len(app.shown), len(app.store.entries), pinned)
				}
				ui.label(fmt.tprintf("%s###status", msg))
				for hint in ([?][2]string{{"Enter", "copy"}, {"Ctrl+P", "pin"}, {"Shift+Del", "remove"}, {"Tab", "filter"}, {"Esc", "hide"}}) {
					ui.kbd(hint[0])
					ui.next({width = ui.text_size(em * 0.3)})
					ui.label(fmt.tprintf("%s###h%s", hint[1], hint[0]))
					ui.spacer(ui.px(em * 0.4))
				}
			}
		}
		ui.spacer(ui.px(em * 0.3))
	}
}

////////////////////////////////
// The preview

view_clear :: proc(app: ^App) {
	if app.view.has_tex { render.destroy_texture(&app.shared.r, app.view.tex) }
	delete(app.view.text)
	app.view = {}
}

// Reads the selected entry for the preview, once per selection.
@(private = "file")
view_load :: proc(app: ^App, e: ^history.Entry) {
	if app.view.loaded && app.view.id == e.id { return }
	view_clear(app)
	app.view.id, app.view.loaded = e.id, true
	switch e.kind {
	case .Image:
		at := -1
		for r, i in e.reps { if strings.has_prefix(r.mime, "image/") { at = i; break } }
		if at < 0 { break }
		app.view.image, app.view.loading = at, true
		decoder_ask(&app.decoder, e.id, history.blob_path(&app.store, e.reps[at].hash), e.reps[at].mime)
	case .Files:
		app.view.text = strings.clone(e.preview)
	case .Text, .Html, .Other:
		main := 0
		for r, i in e.reps { if r.hash == e.key { main = i } }
		data := history.blob_read(&app.store, e.reps[main].hash, context.temp_allocator)
		// rich text reads as its text: the program's own when it gave one, else the markup without its tags
		if e.kind == .Html && e.reps[main].mime == HTML_MIME { data = transmute([]u8)strip_tags(string(data)) }
		text := string(data[:min(len(data), VIEW_TEXT_MAX_BYTES)])
		for len(text) > 0 && !utf8.valid_string(text) { text = text[:len(text) - 1] }   // (cut inside a character)
		app.view.text = strings.clone(text)
	}
}

// A picture the decoder made: the texture of the entry shown, or nothing when the selection moved on.
view_decoded :: proc(app: ^App) -> bool {
	p, ok := decoder_take(&app.decoder)
	if !ok { return false }
	defer decoded_free(&p)
	if !app.view.loading || p.id != app.view.id { return false }
	app.view.loading = false
	e := selected(app)
	if !p.ok {
		if e != nil && e.id == p.id && app.view.image < len(e.reps) {
			r := e.reps[app.view.image]
			app.view.text = fmt.aprintf("%s, %s: no preview for this format", r.mime, size_text(r.size))
		}
		return true
	}
	app.view.tex = render.create_texture_rgba(&app.shared.r, p.size.x, p.size.y)
	render.update_texture_rgba(&app.shared.r, app.view.tex, 0, 0, p.size.x, p.size.y, p.rgba)
	app.view.size, app.view.has_tex = p.size, true
	return true
}

@(private = "file")
Image_Draw :: struct { tex: render.Texture, size: [2]f32 }

// The image, as large as it fits without growing past its own size, centred.
@(private = "file")
image_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Image_Draw)(user)
	r := b.rect
	room := r.max - r.min
	if d.size.x <= 0 || d.size.y <= 0 || room.x <= 0 || room.y <= 0 { return }
	scale := min(room.x / d.size.x, room.y / d.size.y, 1)
	sz := d.size * scale
	at := r.min + (room - sz) * 0.5
	draw.image(dc, d.tex, {at, at + sz}, radius = 6)
}

@(private = "file")
build_view :: proc(app: ^App, em: f32) {
	panel := ui.build_box({.Draw_Background, .Clip}, "###view")
	if ui.parent(panel) { build_view_body(app, em) }
}

@(private = "file")
build_view_body :: proc(app: ^App, em: f32) {
	e := selected(app)
	if e == nil { return }
	view_load(app, e)
	// the header: what it is, its size, its types, and what can be done with it
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.5))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.6))
		glyph(app, KIND_ICONS[e.kind], em * 1.6, ui.color("accent"))
		ui.next({width = ui.text_size(em * 0.3), height = ui.pct(1)})
		ui.label(fmt.tprintf("%s###kind", KIND_LABELS[e.kind]))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			if ui.style({font_size = em * 0.88}) {
				ui.label(fmt.tprintf("%s · %d type%s · %s ago###meta", size_text(history.entry_size(e^)), len(e.reps), len(e.reps) == 1 ? "" : "s", age_text(now_ms() - e.time_ms)))
			}
		}
		if icon_action(app, "copy", ICO_COPY, "Copy (Enter)", em) { copy_entry(app, e.id) }
		if icon_action(app, "pin", e.pinned ? ICO_PIN_OFF : ICO_PIN, e.pinned ? "Unpin (Ctrl+P)" : "Pin (Ctrl+P)", em) { toggle_pin(app, e) }
		if icon_action(app, "delete", ICO_TRASH, "Remove (Shift+Delete)", em) { remove_entry(app, e.id); return }
		ui.spacer(ui.px(em * 0.4))
	}
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.fill()})
	if app.view.has_tex {
		d := ui.frame_new(Image_Draw)
		d^ = {app.view.tex, {f32(app.view.size.x), f32(app.view.size.y)}}
		if ui.row() {
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.fill(), height = ui.fill()})
			ui.custom("image", image_draw, d)
			ui.spacer(ui.px(em * 0.8))
		}
		return
	}
	if app.view.loading {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 5)})
			if ui.style({text_align = .Center}) { ui.label("Loading the image…###loading") }
		}
		return
	}
	if ui.scroll_y("###text") {
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill()})
		if ui.row() {
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.fill()})
			if ui.style({font = app.mono, font_size = em * 0.95}) {
				ui.paragraph(fmt.tprintf("%s###body%d", shown_text(app.view.text), e.id))
			}
			ui.spacer(ui.px(em * 0.8))
		}
	}
}

size_text :: proc(n: int, allocator := context.temp_allocator) -> string {
	switch {
	case n < 1024:        return fmt.aprintf("%d B", n, allocator = allocator)
	case n < 1024 * 1024: return fmt.aprintf("%.1f KB", f64(n) / 1024, allocator = allocator)
	}
	return fmt.aprintf("%.1f MB", f64(n) / (1024 * 1024), allocator = allocator)
}

// Text to show as it is: a "##" in it would end the shown part of a box's id string (ui's key rules), so a zero-width
// space goes between the two signs.
shown_text :: proc(text: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(text, "##") { return text }
	out, _ := strings.replace_all(text, "##", "#​#", allocator)
	return out
}

@(private = "file", rodata) filter_labels := [len(Filter)]string{"All", "Text", "Images", "Files", "Pinned"}
