package papier

// The picker: a window that lists the history, newest first, filtered as one types, with the selected entry shown in
// full beside the list. It reads the history; what it changes it asks the daemon (commands.odin).
//
//   typing              filters (every word must be in the entry, case ignored)
//   Up / Down, Page Up / Page Down, Ctrl+Home / Ctrl+End   move in the list
//   Enter, a double click   put the entry back on the clipboard (and close)
//   Alt+1 .. Alt+9      the same for the first nine entries shown
//   Ctrl+P              pin or unpin (pinned entries stay whatever the limits)
//   Shift+Delete        remove the entry
//   Escape              clear the search, else close

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import config "gt:config"
import "gt:devtools"
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
// Builds a selected row is pulled into view for (the list's own value).
REVEAL_BUILDS :: 3
LIST_SHARE :: 0.52

KIND_LABELS := [history.Kind]string{.Text = "Text", .Html = "Rich", .Image = "Image", .Files = "Files", .Other = "Data"}

Picker :: struct {
	shared:     host.Shared,
	main:       host.Host,
	settings:   Settings,
	store:      history.Store,
	lowered:    [dynamic]string,   // each entry's preview in lower case (the search reads them)
	search:     ui.Text_Field,
	search_key: ui.Key,
	query:      string,            // what `shown` was filtered with (owned)
	vl:         ui.Virtual_List,
	shown:      [dynamic]int,      // the entries the search keeps: indices in store.entries
	ids:        [dynamic]u64,      // their ids (the list's row identities)
	view:       View,
	daemon:     bool,              // a daemon answered at start
	status:     string,            // a message for the status bar (owned)
	devtools:   ^devtools.Server,  // TOOLKIT_DEVTOOLS=<port>: driven and captured over the Chrome DevTools Protocol
}

// The selected entry, read in full for the preview.
View :: struct {
	id:      u64,
	loaded:  bool,
	text:    string,            // owned
	tex:     render.Texture,
	size:    [2]int,
	has_tex: bool,
}

picker_run :: proc(prefs: ^config.Prefs) -> int {
	p := new(Picker)
	defer free(p)
	p.settings = prefs_read(prefs)
	defer settings_free(&p.settings)
	history.open(&p.store, history_dir(p.settings.persist))
	defer history.close(&p.store)
	p.daemon = daemon_running()
	p.vl.sel = 0
	refilter(p)

	if !host.host_open(&p.main, &p.shared, {title = "Papier", size = p.settings.size}, picker_build, p) { return 1 }
	defer host.host_close(&p.main)
	defer picker_free(p)
	h := &p.main
	h.after_input = 3
	h.settle = 4
	h.params = picker_params
	p.devtools = devtools.start_from_env(h.win, "papier")
	defer devtools.stop(p.devtools)
	h.before_input = proc(h: ^host.Host) { p := (^Picker)(h.user); devtools.service(p.devtools, &h.state, &p.shared.r) }
	h.background = ui.theme_lookup(&p.shared.theme, {}, "background")
	platform.set_dark_title(h.win, !strings.has_suffix(p.settings.theme, "light") && p.settings.theme != "daylight")
	platform.show_window(h.win)
	for !platform.is_closed(h.win) {
		host.hosts_wait({h})
		host.host_frame(h)
	}
	return 0
}

@(private = "file")
picker_free :: proc(p: ^Picker) {
	view_clear(p)
	for s in p.lowered { delete(s) }
	delete(p.lowered)
	delete(p.shown)
	delete(p.ids)
	delete(p.query)
	delete(p.status)
	ui.field_destroy(&p.search)
	ui.vlist_destroy(&p.vl)
}

@(private = "file")
picker_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	p := (^Picker)(h.user)
	ui.apply_palette(&p.shared.theme, palette_of(p.settings.theme))
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(32)}, font = p.shared.font, font_size = p.settings.font_size, text_pad = 7, cursor = .Arrow}
}

palette_of :: proc(name: string) -> ui.Palette {
	switch name {
	case "daylight":         return ui.PALETTE_DAYLIGHT
	case "graphite":         return ui.PALETTE_GRAPHITE
	case "nord":             return ui.PALETTE_NORD
	case "dracula":          return ui.PALETTE_DRACULA
	case "gruvbox":          return ui.PALETTE_GRUVBOX
	case "tokyo-night":      return ui.PALETTE_TOKYO_NIGHT
	case "catppuccin":       return ui.PALETTE_CATPPUCCIN
	case "catppuccin-latte": return ui.PALETTE_CATPPUCCIN_LATTE
	case "one-dark":         return ui.PALETTE_ONE_DARK
	case "everforest":       return ui.PALETTE_EVERFOREST
	case "solarized":        return ui.PALETTE_SOLARIZED
	case "solarized-light":  return ui.PALETTE_SOLARIZED_LIGHT
	}
	return ui.PALETTE_MIDNIGHT
}

////////////////////////////////
// The list and the search

// The entries that hold every word of the search, in the history's order.
refilter :: proc(p: ^Picker) {
	if len(p.lowered) != len(p.store.entries) {
		for s in p.lowered { delete(s) }
		clear(&p.lowered)
		for e in p.store.entries { append(&p.lowered, strings.to_lower(e.preview)) }
	}
	words := strings.fields(strings.to_lower(p.query, context.temp_allocator), context.temp_allocator)
	clear(&p.shown)
	clear(&p.ids)
	outer: for e, i in p.store.entries {
		for w in words {
			if !strings.contains(p.lowered[i], w) && !strings.contains(history.KIND_NAMES[e.kind], w) { continue outer }
		}
		append(&p.shown, i)
		append(&p.ids, e.id)
	}
	p.vl.sel = len(p.shown) > 0 ? clamp(p.vl.sel, 0, len(p.shown) - 1) : -1
}

@(private = "file")
selected :: proc(p: ^Picker) -> ^history.Entry {
	if p.vl.sel < 0 || p.vl.sel >= len(p.shown) { return nil }
	return &p.store.entries[p.shown[p.vl.sel]]
}

@(private = "file")
select_row :: proc(p: ^Picker, row: int) {
	if len(p.shown) == 0 { return }
	p.vl.sel = clamp(row, 0, len(p.shown) - 1)
	p.vl.reveal = REVEAL_BUILDS
}

@(private = "file")
say :: proc(p: ^Picker, format: string, args: ..any) {
	delete(p.status)
	p.status = fmt.aprintf(format, ..args)
}

// Puts the entry back on the clipboard through the daemon (started when it does not run).
@(private = "file")
copy_entry :: proc(p: ^Picker, id: u64) {
	if !command_send({verb = .Copy, id = id}, start = true) {
		say(p, "The daemon does not answer: start it with `papier daemon`.")
		return
	}
	p.daemon = true
	if p.settings.close_on_copy {
		platform.request_close(p.main.win)
		return
	}
	at := history.find(&p.store, id)
	if at > 0 {   // (what the daemon does: the entry goes first)
		e := p.store.entries[at]
		ordered_remove(&p.store.entries, at)
		inject_at(&p.store.entries, 0, e)
		l := p.lowered[at]
		ordered_remove(&p.lowered, at)
		inject_at(&p.lowered, 0, l)
		refilter(p)
	}
	say(p, "Copied.")
}

@(private = "file")
ask :: proc(p: ^Picker, verb: Verb, id: u64) -> bool {
	if command_send({verb = verb, id = id}) { return true }
	say(p, "The daemon does not run: start it with `papier daemon`.")
	return false
}

// The keys of the picker, taken before the search field sees them.
@(private = "file")
picker_keys :: proc(p: ^Picker) {
	if ui.key_press(.Down) || ui.key_press(.N, {.Ctrl}) { select_row(p, p.vl.sel + 1) }
	if ui.key_press(.Up) || ui.key_press(.P, {.Alt}) { select_row(p, p.vl.sel - 1) }
	if ui.key_press(.Page_Down) { select_row(p, p.vl.sel + PAGE_ROWS) }
	if ui.key_press(.Page_Up) { select_row(p, p.vl.sel - PAGE_ROWS) }
	if ui.key_press(.Home, {.Ctrl}) { select_row(p, 0) }
	if ui.key_press(.End, {.Ctrl}) { select_row(p, len(p.shown) - 1) }
	if ui.key_press(.Return) { if e := selected(p); e != nil { copy_entry(p, e.id) } }
	digits := [9]platform.Key{.N1, .N2, .N3, .N4, .N5, .N6, .N7, .N8, .N9}
	for k, i in digits {
		if ui.key_press(k, {.Alt}) && i < len(p.shown) { copy_entry(p, p.store.entries[p.shown[i]].id) }
	}
	if ui.key_press(.P, {.Ctrl}) {
		if e := selected(p); e != nil && ask(p, e.pinned ? .Unpin : .Pin, e.id) { e.pinned = !e.pinned }
	}
	if ui.key_press(.Delete, {.Shift}) {
		if e := selected(p); e != nil && ask(p, .Delete, e.id) {
			at := history.find(&p.store, e.id)
			history.remove(&p.store, e.id)
			delete(p.lowered[at])
			ordered_remove(&p.lowered, at)
			refilter(p)
		}
	}
	if ui.key_press(.Escape) {
		if len(p.search.buf) > 0 { ui.field_clear(&p.search) } else { platform.request_close(p.main.win) }
	}
}

////////////////////////////////
// The window

@(private = "file")
picker_build :: proc(h: ^host.Host, size: host.Vec2) {
	p := (^Picker)(h.user)
	em := ui.font_size()
	if p.search_key != 0 && ui.focus_key() != p.search_key { ui.set_focus(p.search_key) }
	picker_keys(p)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if ui.parent(page) { build_page(p, em) }
}

@(private = "file")
build_page :: proc(p: ^Picker, em: f32) {
	// the search
	ui.spacer(ui.px(em * 0.6))
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4)), radius = em * 0.4})
		res := ui.line_edit("###search", &p.search, "Search the clipboard history")
		p.search_key = res.box.key
		ui.spacer(ui.px(em * 0.6))
	}
	if q := ui.field_string(&p.search); q != p.query {
		delete(p.query)
		p.query = strings.clone(q)
		p.vl.sel = 0
		refilter(p)
		ui.vlist_scroll_to(&p.vl, 0)
	}
	ui.spacer(ui.px(em * 0.6))

	// the list and the preview
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row() {
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.pct(LIST_SHARE), height = ui.fill()})
		build_list(p, em)
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.fill(), radius = em * 0.4})
		build_view(p, em)
		ui.spacer(ui.px(em * 0.6))
	}

	// the status bar
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.7))
		if ui.tags("weak") {
			ui.next({width = ui.fill()})
			status := p.status
			if status == "" {
				status = fmt.tprintf("%d of %d entries%s   ·   Enter copy   Ctrl+P pin   Shift+Del remove   Esc close", len(p.shown), len(p.store.entries), p.daemon ? "" : "   ·   daemon not running")
			}
			ui.label(fmt.tprintf("%s###status", status))
		}
	}
}

@(private = "file")
build_list :: proc(p: ^Picker, em: f32) {
	rows, ok := ui.vlist("###list", &p.vl, p.ids[:])
	if !ok { return }
	now := now_ms()
	for i in rows.first ..< rows.last {
		e := &p.store.entries[p.shown[i]]
		ui.next({height = ui.px(ui.dense(em * 2.2))})
		row := ui.list_row(&p.vl, i, "")
		if ui.parent(row.box) {
			ui.spacer(ui.px(em * 0.5))
			if ui.tags("weak") {
				ui.next({width = ui.px(em * 3.4), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s%s###k", e.pinned ? "★ " : "", KIND_LABELS[e.kind]))
			}
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(fmt.tprintf("%s###t", shown_text(one_line(e.preview, 200))))
			if ui.tags("weak") {
				ui.next({width = ui.text_size(em * 0.4), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###a", age_text(now - e.time_ms)))
			}
		}
		if row.double_clicked { copy_entry(p, e.id) }
	}
	if len(p.shown) == 0 {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 4)})
			if ui.style({text_align = .Center}) {
				ui.label(len(p.store.entries) == 0 ? "Nothing copied yet.###empty" : "No entry matches.###empty")
			}
		}
	}
}

////////////////////////////////
// The preview

@(private = "file")
view_clear :: proc(p: ^Picker) {
	if p.view.has_tex { render.destroy_texture(&p.shared.r, p.view.tex) }
	delete(p.view.text)
	p.view = {}
}

// Reads the selected entry for the preview, once per selection.
@(private = "file")
view_load :: proc(p: ^Picker, e: ^history.Entry) {
	if p.view.loaded && p.view.id == e.id { return }
	view_clear(p)
	p.view.id, p.view.loaded = e.id, true
	switch e.kind {
	case .Image:
		at := -1
		for r, i in e.reps { if strings.has_prefix(r.mime, "image/") { at = i; break } }
		if at < 0 { break }
		data := history.blob_read(&p.store, e.reps[at].hash, context.temp_allocator)
		img, ok := platform.clipboard_image_decode(e.reps[at].mime, data, context.temp_allocator)
		if !ok { p.view.text = fmt.aprintf("%s, %s (no preview for this format)", e.reps[at].mime, size_text(e.reps[at].size)); break }
		p.view.tex = render.create_texture_rgba(&p.shared.r, img.size.x, img.size.y)
		render.update_texture_rgba(&p.shared.r, p.view.tex, 0, 0, img.size.x, img.size.y, img.rgba)
		p.view.size, p.view.has_tex = img.size, true
	case .Text, .Html, .Files, .Other:
		main := 0
		for r, i in e.reps { if r.hash == e.key { main = i } }
		data := history.blob_read(&p.store, e.reps[main].hash, context.temp_allocator)
		text := string(data[:min(len(data), VIEW_TEXT_MAX_BYTES)])
		if e.kind == .Files { text = e.preview }
		for len(text) > 0 && !utf8.valid_string(text) { text = text[:len(text) - 1] }   // (cut inside a character)
		p.view.text = strings.clone(text)
	}
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
	draw.image(dc, d.tex, {at, at + sz})
}

@(private = "file")
build_view :: proc(p: ^Picker, em: f32) {
	if ui.tags("card") {
		panel := ui.build_box({.Draw_Background, .Draw_Border, .Clip}, "###view")
		if ui.parent(panel) { build_view_body(p, em) }
	}
}

@(private = "file")
build_view_body :: proc(p: ^Picker, em: f32) {
	{
		e := selected(p)
		if e == nil { return }
		view_load(p, e)
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.7))
			if ui.tags("weak") {
				ui.next({width = ui.fill()})
				mimes := make([dynamic]string, context.temp_allocator)
				for r in e.reps { append(&mimes, r.mime) }
				ui.label(fmt.tprintf("%s%s · %s · %s###meta", e.pinned ? "Pinned · " : "", KIND_LABELS[e.kind], size_text(history.entry_size(e^)), shown_text(strings.join(mimes[:], ", ", context.temp_allocator))))
			}
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		if p.view.has_tex {
			d := ui.frame_new(Image_Draw)
			d^ = {p.view.tex, {f32(p.view.size.x), f32(p.view.size.y)}}
			ui.next({width = ui.fill(), height = ui.fill()})
			ui.custom("image", image_draw, d)
			return
		}
		if ui.scroll_y("###text") {
			ui.next({width = ui.fill()})
			ui.paragraph(fmt.tprintf("%s###body%d", shown_text(p.view.text), e.id))
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
