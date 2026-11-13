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
//   Ctrl+E                  edit the entry (edit.odin)
//   Ctrl+O, Ctrl+S          open it, save it as a file (entry_menu.odin)
//   a right click, Menu, Shift+F10    the entry's menu (entry_menu.odin)
//   Escape                  clear the search, else hide

import "base:runtime"
import "core:fmt"
import "core:strings"
import diff "gt:diff"
import "gt:draw"
import "gt:markdown"
import "gt:host"
import i18n "gt:i18n"
import "gt:platform"
import "gt:render"
import syntax "gt:syntax"
import prefs_page "gt:prefs_page"
import crash_bar "gt:crash_bar"
import timefmt "gt:timefmt"
import "gt:ui"
import "history"
import lucide "gt:lucide"

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
FIELD_EM  :: 1.95   // the search and the filters
HALO_ROOM_PX :: 2   // logical pixels past the halo's reach before the bar's rule
FILTER_EM :: 23   // the filter's segmented control
ROW_EM    :: 2.05
MARK_EM   :: 2.6    // a row's mark: its kind's icon, or an image's thumbnail
STATUS_EM :: 1.9
// The grip between the search and the filters: its width in ems, its lines' share of the bar's height, their spacing in
// logical pixels and their opacity (of the weak text's colour).
GRIP_EM     :: 2.2
GRIP_HEIGHT :: 0.3
GRIP_GAP_PX :: 3
GRIP_ALPHA  :: 0.45

KIND_ICONS := [history.Kind]string{.Text = lucide.ALIGN_LEFT, .Html = lucide.CODE, .Image = lucide.IMAGE, .Files = lucide.FILES, .Other = lucide.FILE}
// (in English: i18n.tr where shown)
KIND_LABELS := [history.Kind]string{.Text = i18n.later("Text"), .Html = i18n.later("Rich text"), .Image = i18n.later("Image"), .Files = i18n.later("Files"), .Other = i18n.later("Data")}

// The selected entry, shown in full. Its states: nothing asked (asked = false); its content asked (of the reader, or of
// the decoder for a picture: loading); shown (app.loaded is the reader's answer for this id and key, or the texture
// came). Another entry selected, or the same with another key (an edit), asks again.
View :: struct {
	id:      u64,
	key:     u64,               // the entry's content when it was asked (an edit keeps the id, not the key)
	asked:   bool,
	text:    string,            // a picture that cannot be shown says why (owned)
	tex:     render.Texture,
	size:    [2]int,
	has_tex: bool,
	loading: bool,              // its picture is being decoded (decoder.odin)
	preview: ui.Preview,        // its picture's zoom and pan (fits again with each entry: view_clear)
	image:   int,               // the representation of the picture, in the entry's reps
	qr:      string,            // the text of a QR code in its picture ("" none; the decoder's heap)
	asked_at: f64,              // when its content was asked (ui clock, ms): "Loading…" only for a slow answer
	runs:    [dynamic]ui.Rich_Run,   // its code in the theme's colours, made once per answer (runs_for) and per theme
	runs_for: [2]u64,           // the id and key `runs` were made for ({}: none)
}

// How long an answer of the reader may take before the preview says "Loading…": a text comes in well under a frame,
// and a word shown for one frame at each move of the selection would flicker.
LOADING_SHOWN_AFTER_MS :: 150

////////////////////////////////
// The list and the search

// The entries that pass the filter and hold every word of the search: asked of the reader, which computes them on its
// thread (view_arrived applies them). `reset`: a new look, the first row selected and the list at its top when they come.
refilter :: proc(app: ^App, reset := false) {
	app.query_seq += 1
	reader_query(&app.reader, app.query_seq, app.query, app.filter, reset)
}

// A view the reader computed. Applied only when it answers the newest query sent, on the list the window holds or on
// the one that waits for it (which it then puts in place). True when the list or the rows changed.
view_arrived :: proc(app: ^App, v: ^History_View) -> bool {
	fits, next := view_fits(v^, app.query_seq, app.list.serial, app.list_next.serial, app.has_list_next)
	if !fits { return false }
	keep := selected_id(app)   // (on the list shown until now)
	if next {
		history_list_free(&app.list)
		app.list, app.list_next, app.has_list_next = app.list_next, {}, false
	}
	delete(app.shown)
	delete(app.ids)
	app.shown, app.ids = v.shown, v.ids
	v.shown, v.ids = nil, nil
	app.ids_version += 1
	count := len(app.shown)
	switch {
	case v.reset:
		app.vl.sel = count > 0 ? 0 : -1
		select_row(app, 0)
		ui.vlist_scroll_to(&app.vl, 0)
	case keep != 0 && v.keep_id == keep && v.keep_row >= 0:
		app.vl.sel = v.keep_row
	case:
		app.vl.sel = count > 0 ? clamp(app.vl.sel, 0, count - 1) : -1
	}
	return true
}

// Whether a view is applied: it answers the newest query sent, on the list shown or on the one that waits (on_next: that
// one then takes the shown one's place).
view_fits :: proc(v: History_View, query_seq, list_serial, next_serial: u64, has_next: bool) -> (fits, on_next: bool) {
	on_next = has_next && v.serial == next_serial
	fits = v.seq == query_seq && (on_next || v.serial == list_serial)
	return
}

selected :: proc(app: ^App) -> ^history.Entry {
	if app.vl.sel < 0 || app.vl.sel >= len(app.shown) { return nil }
	return &app.list.entries[app.shown[app.vl.sel]]
}

// The entry `id` of the list shown (nil: not there).
list_entry :: proc(app: ^App, id: u64) -> ^history.Entry {
	at, ok := app.list.at[id]
	return ok ? &app.list.entries[at] : nil
}

// Whether app.loaded is the reader's answer for `e` as it is now.
loaded_for :: proc(app: ^App, e: ^history.Entry) -> bool {
	return app.loaded.id != 0 && app.loaded.id == e.id && app.loaded.key == e.key
}

// The text of a QR code in the picture of `e`, once the decoder read it for the preview ("" none, or not yet).
image_qr :: proc(app: ^App, e: ^history.Entry) -> string {
	if e.kind != .Image || !app.view.has_tex || app.view.id != e.id || app.view.key != e.key { return "" }
	return app.view.qr
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

set_filter :: proc(app: ^App, f: Filter) {
	if app.filter == f { return }
	app.filter = f
	refilter(app, reset = true)
}

toggle_pin :: proc(app: ^App, e: ^history.Entry) {
	watcher_send(&app.watcher, {verb = e.pinned ? .Unpin : .Pin, id = e.id})
	// (shown at once, in the list that waits for its view too; the watcher's index says the same at the next reload)
	pinned := !e.pinned
	e.pinned = pinned
	app.list.pinned += pinned ? 1 : -1
	if app.has_list_next {
		if at, ok := app.list_next.at[e.id]; ok && app.list_next.entries[at].pinned != pinned {
			app.list_next.entries[at].pinned = pinned
			app.list_next.pinned += pinned ? 1 : -1
		}
	}
	reader_pin(&app.reader, e.id, pinned)
}

// The row goes at once; the reader takes the entry out of its list (a view that still holds it is not applied: the
// query's seq moves) and the watcher deletes it.
remove_entry :: proc(app: ^App, id: u64) {
	watcher_send(&app.watcher, {verb = .Delete, id = id})
	app.query_seq += 1
	reader_forget(&app.reader, id, app.query_seq)
	for row_id, row in app.ids {
		if row_id != id { continue }
		ordered_remove(&app.shown, row)
		ordered_remove(&app.ids, row)
		app.ids_version += 1
		break
	}
	app.vl.sel = len(app.shown) > 0 ? clamp(app.vl.sel, 0, len(app.shown) - 1) : -1
}

// The keys of the window, taken before the search field sees them.
@(private = "file")
view_keys :: proc(app: ^App) {
	if prefs_page.install_open_now(&app.install) || app.palette.open || app.sheet.open || app.qr.open { return }   // (a dialog has the keyboard)
	if app.settings_open { settings_keys(app); return }
	if app.edit.active { edit_keys(app); return }
	// (the moves of the selection: a move clears the marks, as the list's own keys do)
	moved := false
	if ui.key_press(.Down) || ui.key_press(.N, {.Ctrl}) { select_row(app, app.vl.sel + 1); moved = true }
	if ui.key_press(.Up) || ui.key_press(.P, {.Alt}) { select_row(app, app.vl.sel - 1); moved = true }
	if ui.key_press(.Page_Down) { select_row(app, app.vl.sel + PAGE_ROWS); moved = true }
	if ui.key_press(.Page_Up) { select_row(app, app.vl.sel - PAGE_ROWS); moved = true }
	if ui.key_press(.Home, {.Ctrl}) { select_row(app, 0); moved = true }
	if ui.key_press(.End, {.Ctrl}) { select_row(app, len(app.shown) - 1); moved = true }
	if moved { ui.list_marks_clear(&app.vl) }
	digits := [9]platform.Key{.N1, .N2, .N3, .N4, .N5, .N6, .N7, .N8, .N9}
	for k, i in digits {
		if ui.key_press(k, {.Alt}) && i < len(app.ids) { entry_copy(app, app.ids[i]) }
	}
	actions_keys(app)
	if ui.key_press(.Menu) || ui.key_press(.F10, {.Shift}) {
		if e := selected(app); e != nil { entry_menu_open(app, e, {app.sel_rect.min.x + 24, app.sel_rect.max.y}, from_keyboard = true) }
	}
	if ui.key_press(.Escape) {
		switch {
		case ui.list_mark_count(&app.vl) > 0: ui.list_marks_clear(&app.vl)
		case len(app.search.buf) > 0:         ui.line_edit_clear(&app.search)
		case:                                 app_hide(app)
		}
	}
}

////////////////////////////////
// The window

view_build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	em := ui.font_size()
	app.room = size.x / max(ui.scale(), 0.01)
	app_shortcut_follow(app)
	// (the user's themes file: a task looks at it now and then, and reads it when it changed; app_params shows it)
	if prefs_page.themes_file_poll(&app.themes_file, &app.main.state) { app.main.settle = max(app.main.settle, FRAMES_AFTER_INPUT) }
	// the keyboard is the search's, unless the edit view or the settings have it
	dialog := app.palette.open || app.sheet.open || app.qr.open || prefs_page.install_open_now(&app.install)
	if !app.edit.active && !app.settings_open && !dialog && app.search_key != 0 && ui.focus_key() != app.search_key { ui.set_focus(app.search_key) }
	view_keys(app)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if ui.parent(page) { build_page(app, em) }
	entry_menu_build(app, em)
	actions_build(app)
	qr_build(app, em)
	setup_build(app, em)
}

@(private = "file")
build_page :: proc(app: ^App, em: f32) {
	build_title(app, em)
	ui.hline(ui.fill())
	crash_bar.bar(&app.crash_bar, {name = "Papier", version = APP_VERSION, repository = "sachahjkl/papier"})
	ui.next({width = ui.fill(), height = ui.fill()})
	if app.settings_open {
		settings_build(app)
		return
	}
	if ui.row() { build_body(app, em) }
	ui.hline(ui.fill())
	build_status(app, em)
}

// An icon of Lucide, `size` ems wide.
glyph :: proc(app: ^App, g: string, width: f32, fg: Maybe(ui.Color) = nil) {
	ui.next({width = ui.px(width), height = ui.pct(1), font = app.icons, text_align = .Center, fg = fg})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###g%d", g, ui.parent_box().child_count))
}

// A small button with a Lucide icon; its tooltip says what it does.
icon_action :: proc(app: ^App, id, g, tip: string, em: f32) -> bool {
	ui.next({width = ui.px(em * 2.1), height = ui.px(em * 2.1), radius = em * 0.4})
	return ui.button(id, icon = g, o = {tip = tip, icon_font = app.icons}).clicked
}

@(private = "file")
build_title :: proc(app: ^App, em: f32) {
	// (as tall as its fields, and the halo of the focused one around them: the rule under the bar would cut it)
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * FIELD_EM) + 2 * (ui.MACHINED_OVERFLOW_PX + HALO_ROOM_PX) * ui.scale())})
	if ui.title_bar("###titlebar") {
		ui.spacer(ui.px(em * 0.5))
		glyph(app, lucide.CLIPBOARD, em * 1.8, ui.color("accent"))
		ui.spacer(ui.px(em * 0.3))
		if app.settings_open {
			// the page has its own search: the title says where one is, its empty part moves the window
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label("Papier###apptitle")
			if icon_action(app, "back", lucide.ARROW_LEFT, i18n.tr("Back to the history (Escape)"), em) { app.settings_open = false }
			ui.spacer(ui.px(em * 0.3))
			// (the system's title bar has its own close button)
		if !app.settings.system_title && icon_action(app, "close", lucide.X, i18n.tr("Hide (Escape)"), em) { app_hide(app) }
			ui.spacer(ui.px(em * 0.4))
			return
		}
		// the search: a field with its icon, as wide as the title leaves
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * FIELD_EM)), radius = em * 0.45})
		// one surface: the icon and the field, one focus ring around both (the field is bare: no box of its own)
		if ui.input_frame("###searchbox") {
			if ui.tags("weak") { glyph(app, lucide.SEARCH, em * 1.9) }
			ui.next({width = ui.fill(), height = ui.pct(1)})
			if ui.tags("bare") {
				res := ui.line_edit("###search", &app.search, {placeholder = i18n.tr("Search the history")})
				app.search_key = res.box.key
			}
		}
		if q := ui.line_edit_string(&app.search); q != app.query {
			delete(app.query)
			app.query = strings.clone(q)
			refilter(app, reset = true)
		}
		// a grip between the search and the filters: the window is moved from there (an empty part of the title bar)
		d := ui.frame_new(Grip_Draw)
		d^.scale = ui.scale()
		if ui.tags("weak") { d.color = ui.color("text") }
		ui.next({width = ui.px(em * GRIP_EM), height = ui.pct(1)})
		ui.custom("###grip", grip_draw, d)
		ui.next({width = ui.px(em * FILTER_EM), height = ui.px(ui.dense(em * FIELD_EM))})
		sel := int(app.filter)
		labels: [len(Filter)]string
		for l, i in filter_labels { labels[i] = i18n.tr(l) }
		if ui.segmented("###filter", labels[:FILTER_COUNT], &sel) { set_filter(app, Filter(sel)) }
		ui.spacer(ui.px(em * 0.3))
		if icon_action(app, "settings", lucide.SETTINGS, i18n.tr("Settings (Ctrl+,)"), em) { settings_toggle(app) }
		// (the system's title bar has its own close button)
		if !app.settings.system_title && icon_action(app, "close", lucide.X, i18n.tr("Hide (Escape)"), em) { app_hide(app) }
		ui.spacer(ui.px(em * 0.4))
	}
}

@(private = "file")
Grip_Draw :: struct { color: ui.Color, scale: f32 }

// Three short vertical lines in the middle of the grip, faint: they say "hold here" without drawing the eye. (Their
// colour is the weak text's: `ui.color("text")` under the tag "weak"; a name the theme lacks gives its missing colour.)
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
	// (flush: the list and the entry's pane meet at its rule, whose lines join theirs; it is grabbed wider than it is drawn)
	ui.splitter("###split", .X, &app.place.split, LIST_MIN_PX, max(room - VIEW_MIN_PX, LIST_MIN_PX),
		{default_size = room * LIST_SHARE, total = room, min_other = VIEW_MIN_PX, flush = true})
	ui.next({width = ui.fill(), height = ui.fill()})
	build_view(app, em)
}

@(private = "file")
build_list :: proc(app: ^App, em: f32) {
	drag_build_begin(app)
	rows, ok := ui.vlist("###list", &app.vl, app.ids[:], ids_version = app.ids_version)
	if !ok { return }
	now := now_ms()
	thumbs_begin(app)
	defer thumbs_end(app)
	for i in rows.first ..< rows.last {
		e := &app.list.entries[app.shown[i]]
		ui.next({height = ui.px(ui.dense(em * ROW_EM))})
		row := ui.list_row(&app.vl, i, "")
		if ui.parent(row.box) {
			ui.spacer(ui.px(em * 0.35))
			// (an image, a copied file: its thumbnail once made, its kind's mark until then)
			if !has_thumb(e) || !thumb_mark(app, e, em * MARK_EM) {
				if ui.tags("weak") { glyph(app, KIND_ICONS[e.kind], em * MARK_EM) }
			}
			// (the search's words lit in the line)
			line := ui.text_shown(one_line(e.preview, 200))
			ui.next({width = ui.fill()})
			ui.matched_label("###t", line, ui.word_ranges(line, app.query))
			if e.pinned { glyph(app, lucide.PIN, em * 1.6, ui.color("accent")) }
			if i < 9 && len(app.query) == 0 {
				if ui.tags("weak") {
					ui.next({width = ui.text_size(em * 0.3), height = ui.pct(1)})
					if ui.style({font_size = em * 0.8}) { ui.label(fmt.tprintf("Alt+%d###n", i + 1)) }
				}
			}
			if ui.tags("weak") {
				ui.next({width = ui.text_size(em * 0.5), height = ui.pct(1)})
				if ui.style({font_size = em * 0.85}) { ui.label(fmt.tprintf("%s###a", timefmt.age(f64(now - e.time_ms)))) }
			}
		}
		if i == app.vl.sel { app.sel_rect = row.box.rect }
		if row.double_clicked { entry_copy(app, e.id) }
		drag_watch(app, row, e)
		if row.right_clicked {
			select_row(app, i)
			entry_menu_open(app, e, ui.mouse_pos())
		}
	}
	if len(app.shown) == 0 {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 5)})
			if ui.style({text_align = .Center}) {
				ui.label(fmt.tprintf("%s###empty", len(app.list.entries) == 0 ? i18n.tr("Nothing copied yet: copy something, it shows here.") : i18n.tr("No entry matches.")))
			}
		}
	}
}

@(private = "file")
build_status :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * STATUS_EM))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.7))
		// (an update on offer, coming or in place: a button to act on it, where the eye goes)
		ui.next({height = ui.px(ui.dense(em * (STATUS_EM - 0.45)))})
		if prefs_page.update_badge(app.updater, proc(user: rawptr) { app_restart((^App)(user), hidden = false) }, app) { ui.spacer(ui.px(em * 0.6)) }
		if ui.style({font_size = em * 0.88}) {
			if ui.tags("weak") {
				ui.next({width = ui.fill()})
				msg := app.status
				if (msg == "" || ui.now_ms() > app.status_until) && app.ocr_reading != 0 {
					msg = i18n.tr("Reading the text of the image…")
				} else if msg == "" || ui.now_ms() > app.status_until {
					// (the English says "1 of 1 entries", "1 pinned" either way: its two forms are one)
					total := len(app.list.entries)
					msg = fmt.tprintf(i18n.tr(total, "%d of %d entries", "%d of %d entries"), len(app.shown), total)
					// (counted by the reader with the list, and kept by a pin: not counted here at each frame)
					if PINS { msg = fmt.tprintf(i18n.tr(app.list.pinned, "%s · %d pinned", "%s · %d pinned"), msg, app.list.pinned) }
				}
				ui.label(fmt.tprintf("%s###status", msg))
				hints := app.edit.active ? EDIT_HINTS[:] : LIST_HINTS[:]
			for hint in hints {
					ui.kbd(hint[0])
					ui.next({width = ui.text_size(em * 0.3)})
					ui.label(fmt.tprintf("%s###h%s", i18n.tr(hint[1]), hint[0]))
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
	delete(app.view.runs)
	delete(app.view.qr, runtime.heap_allocator())
	app.view = {}
}

// Asks for the selected entry's content, once per selection: its picture of the decoder, the rest of the reader.
@(private = "file")
view_load :: proc(app: ^App, e: ^history.Entry) {
	if app.view.asked && app.view.id == e.id && app.view.key == e.key { return }
	view_clear(app)
	app.view.id, app.view.key, app.view.asked = e.id, e.key, true
	app.view.asked_at = ui.now_ms()
	// (an edit waits for the entry it was asked on: another one selected ends the wait)
	if app.edit.pending != e.id { app.edit.pending = 0 }
	if e.kind == .Image {
		at := image_rep(e)
		if at < 0 { return }
		app.view.image, app.view.loading = at, true
		decoder_ask(&app.decoder, e.id, app.list.dir, e.reps[at].hash, e.reps[at].mime)
		return
	}
	// (an entry's content does not change with the same key: an answer kept from before is still right)
	if !loaded_for(app, e) { reader_load(&app.reader, e.id, e.key) }
}

// The reader's answer for the selected entry: kept when it is the one shown, then an edit that waited for it begins.
// True when it is.
view_loaded :: proc(app: ^App, l: ^Loaded_Entry) -> bool {
	if !app.view.asked || l.id != app.view.id || l.key != app.view.key { return false }
	loaded_free(&app.loaded)
	app.loaded = l^
	l^ = {}
	app.view.runs_for = {}   // (the runs pointed into the answer just freed)
	if e := selected(app); e != nil && e.id == app.edit.pending { edit_begin(app, e) }
	return true
}

// A picture the decoder made: the texture of the entry shown, or nothing when the selection moved on.
view_decoded :: proc(app: ^App) -> bool {
	changed := false
	// (the code's text comes after its picture, for the same entry: kept while that entry is shown)
	defer if q, ok := decoder_take_qr(&app.decoder); ok {
		if app.view.has_tex && q.id == app.view.id {
			delete(app.view.qr, runtime.heap_allocator())
			app.view.qr, q.text = q.text, ""
			changed = true
		}
		picture_qr_free(&q)
	}
	p, ok := decoder_take(&app.decoder)
	if !ok { return changed }
	defer decoded_free(&p)
	if !app.view.loading || p.id != app.view.id { return false }
	app.view.loading = false
	e := selected(app)
	if !p.ok {
		if e != nil && e.id == p.id && app.view.image < len(e.reps) {
			r := e.reps[app.view.image]
			app.view.text = fmt.aprintf(i18n.tr("%s, %s: no preview for this format"), r.mime, size_text(r.size))
		}
		return true
	}
	app.view.tex = render.create_texture_rgba(&app.shared.r, p.size.x, p.size.y)
	render.update_texture_rgba(&app.shared.r, app.view.tex, 0, 0, p.size.x, p.size.y, p.rgba)
	app.view.size, app.view.has_tex = p.size, true
	return true
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
	// the edit view is its entry's: another selection leaves it
	if app.edit.active && app.edit.id != e.id { edit_end(app) }
	if app.edit.active { edit_build(app, e, em); return }
	view_load(app, e)
	// the header: what it is, its size, its types, and what can be done with it
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.5))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.6))
		glyph(app, KIND_ICONS[e.kind], em * 1.6, ui.color("accent"))
		ui.next({width = ui.text_size(em * 0.3), height = ui.pct(1)})
		ui.label(fmt.tprintf("%s###kind", i18n.tr(KIND_LABELS[e.kind])))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			if ui.style({font_size = em * 0.88}) {
				lang := loaded_for(app, e) ? form_label(app.loaded) : ""
				if lang != "" { lang = fmt.tprintf("%s · ", lang) }
				age := timefmt.age(f64(now_ms() - e.time_ms))
				if age != "now" { age = fmt.tprintf(i18n.tr("%s ago"), age) }   // ("now": less than a minute)
				types := fmt.tprintf(i18n.tr(len(e.reps), "%d type", "%d types"), len(e.reps))
				ui.label(fmt.tprintf("%s%s · %s · %s###meta", lang, size_text(history.entry_size(e^)), types, age))
			}
		}
		if icon_action(app, "copy", lucide.COPY, action_tip(.Copy), em) { entry_copy(app, e.id) }
		if e.kind == .Text || e.kind == .Html {
			if icon_action(app, "edit", lucide.EDIT, action_tip(.Edit), em) { edit_begin(app, e) }
		}
		if qr_text(app, e) != "" && icon_action(app, "qr", lucide.QR_CODE, action_tip(.Show_QR), em) { qr_open(app, e) }
		// (Markdown: rendered or its source, the choice kept for the session)
		if loaded_for(app, e) && app.loaded.form == .Markdown {
			tip := app.markdown_source ? i18n.tr("Show it rendered") : i18n.tr("Show the source")
			if icon_action(app, "mdsource", app.markdown_source ? lucide.EYE : lucide.FILE_CODE, fmt.tprintf("%s (%s)", tip, ui.command_shortcut(ACTIONS[.Toggle_Markdown_Source])), em) {
				action_run(app, .Toggle_Markdown_Source)
			}
		}
		// (an image: the code it holds, its text; images have no "Show as a QR code", so the icon is free)
		if image_qr(app, e) != "" && icon_action(app, "qrcontent", lucide.QR_CODE, action_tip(.Copy_Qr_Content), em) { action_run(app, .Copy_Qr_Content) }
		if e.kind == .Image && ocr_offered(app) && icon_action(app, "ocr", lucide.FILE_TEXT, action_tip(.Copy_Image_Text), em) { action_run(app, .Copy_Image_Text) }
		if PINS && icon_action(app, "pin", e.pinned ? lucide.PIN_OFF : lucide.PIN, fmt.tprintf("%s (%s)", e.pinned ? i18n.tr("Unpin") : i18n.tr("Pin"), ui.command_shortcut(ACTIONS[.Pin])), em) { toggle_pin(app, e) }
		if icon_action(app, "delete", lucide.TRASH_2, action_tip(.Remove), em) { remove_entry(app, e.id); return }
		ui.spacer(ui.px(em * 0.4))
	}
	ui.hline(ui.fill())
	// (the text of this image being read: said where the user looks, the picture still shown and the window free)
	if app.ocr_reading == e.id {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2)), axis = .X, cross = .Center})
		if ui.row(.Center, {}, "###ocr_strip") {
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###ocr_label", i18n.tr("Reading the text of the image…")))
			}
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.fill(), height = ui.px(max(f32(3), f32(int(em * 0.3))))})
			ui.progress("###ocr_progress", 0, indeterminate = true)
			ui.spacer(ui.px(em * 0.8))
		}
		ui.hline(ui.fill())
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	if app.view.has_tex {
		// (gui_toolkit's preview: the wheel zooms, a drag moves it, a double click shows its pixels; its bar in the corner)
		ui.next({width = ui.fill(), height = ui.fill()})
		res := ui.preview_image("###image", &app.view.preview, app.view.tex, {f32(app.view.size.x), f32(app.view.size.y)}, {buttons = true, radius = 6})
		// (a right click on the picture: the entry's menu, where what can be done with an image is found: its text, a code's
		// content, saving it)
		if res.box != nil && ui.signal(res.box).right_clicked { entry_menu_open(app, e, ui.mouse_pos()) }
		return
	}
	// (a picture: decoded, or why it is not; anything else: the reader's answer)
	text := app.view.text
	code, has_code := syntax.Language{}, false
	if e.kind != .Image {
		if loaded_for(app, e) {
			l := &app.loaded
			text = l.view_text
			switch l.form {
			case .Plain:
			case .Code:
				code, has_code = l.code, l.has_code
			case .Markdown:
				if !app.markdown_source && l.markdown != nil { build_markdown(app, l, em); return }
			case .Diff:
				if l.diff != nil { build_diff(app, l, em); return }
			}
		} else {
			waited := ui.now_ms() - app.view.asked_at
			if waited < LOADING_SHOWN_AFTER_MS {
				ui.wake_within(&app.main.state, int(LOADING_SHOWN_AFTER_MS - waited) + 1)
			} else if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.px(em * 5)})
				if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("%s###loading", i18n.tr("Loading…"))) }
			}
			return
		}
	}
	if app.view.loading {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 5)})
			if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("%s###loading", i18n.tr("Loading the image…"))) }
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
				if has_code {
					// (coloured once per answer and per theme, not at each frame: runs point into app.loaded's text)
					if app.view.runs_for != {e.id, e.key} {
						clear(&app.view.runs)
						ui.code_runs(text, code, {}, &app.view.runs)
						app.view.runs_for = {e.id, e.key}
					}
					ui.rich_paragraph(fmt.tprintf("###code%d", e.id), app.view.runs[:])
				} else {
					ui.paragraph(fmt.tprintf("%s###body%d", text, e.id))
				}
			}
			ui.spacer(ui.px(em * 0.8))
		}
	}
}

// What the header calls the text's form: its language, "Markdown", "Diff" ("" plain).
@(private = "file")
form_label :: proc(l: Loaded_Entry) -> string {
	switch l.form {
	case .Plain:    return ""
	case .Code:     return l.has_code ? l.code.label : ""
	case .Markdown: return "Markdown"
	case .Diff:     return "Diff"
	}
	return ""
}

// Markdown, rendered: the doc the reader read with the answer (nothing is parsed here; the doc makes its runs once).
@(private = "file")
build_markdown :: proc(app: ^App, l: ^Loaded_Entry, em: f32) {
	if ui.scroll_y("###markdown") {
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill()})
		if ui.row() {
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.fill()})
			if ui.column() {
				// (this frame's room, from the window: the box's own width is the last frame's; the pane less its sides
				// and the scroll bar)
				u := ui.frame_new(Markdown_User)
				u^ = {app = app, loaded = l, width = (app.room - app.place.split) * ui.scale() - em * 2.6}
				u.cfg = markdown.View_Options{prose = app.shared.font, mono = app.mono, user = u, link = markdown_link}
				cfg := u.cfg
				cfg.code = markdown_code
				markdown.view(l.markdown, fmt.tprintf("md%d", l.id), l.source, cfg)
			}
			ui.spacer(ui.px(em * 0.8))
		}
		ui.spacer(ui.px(em * 0.5))
	}
}

// A link of the Markdown shown: a web or mail address goes to the browser through the reader (it starts a program);
// anything else is not handed to the system (a copied text's link is the text's author's).
@(private = "file")
markdown_link :: proc(user: rawptr, url: string) {
	app := (^Markdown_User)(user).app
	target := strings.trim_space(url)
	if !is_address(target) && !strings.has_prefix(target, "mailto:") {
		say(app, i18n.tr("Only web and mail addresses open: %s"), one_line(target, 60))
		return
	}
	reader_job(&app.reader, {kind = .Open_Url, text = target})
}

// A diff: its lines as the patch has them, in its files' colours when the reader found their language. Only the rows in
// view are built; the doc was read with the answer.
@(private = "file")
build_diff :: proc(app: ^App, l: ^Loaded_Entry, em: f32) {
	o := diff.View_Options{font = app.mono, size = em * 0.95, selectable = true}
	if l.has_code { o.language = l.code }
	ui.next({width = ui.fill(), height = ui.fill()})
	diff.view(fmt.tprintf("###diff%d", l.id), l.diff, .Stacked, o)
}

size_text :: proc(n: int, allocator := context.temp_allocator) -> string {
	switch {
	case n < 1024:        return fmt.aprintf(i18n.tr("%d B"), n, allocator = allocator)
	case n < 1024 * 1024: return fmt.aprintf(i18n.tr("%.1f KB"), f64(n) / 1024, allocator = allocator)
	}
	return fmt.aprintf(i18n.tr("%.1f MB"), f64(n) / (1024 * 1024), allocator = allocator)
}

// (their words in English, a key's name and what it does: i18n.tr where shown)
when PINS {
	@(private = "file") LIST_HINTS := [?][2]string{{"Enter", i18n.later("copy")}, {"Ctrl+E", i18n.later("edit")}, {"Menu", i18n.later("more")}, {"Ctrl+P", i18n.later("pin")}, {"Tab", i18n.later("filter")}, {"Esc", i18n.later("hide")}}
} else {
	@(private = "file") LIST_HINTS := [?][2]string{{"Enter", i18n.later("copy")}, {"Ctrl+E", i18n.later("edit")}, {"Menu", i18n.later("more")}, {"Tab", i18n.later("filter")}, {"Esc", i18n.later("hide")}}
}
@(private = "file") EDIT_HINTS := [?][2]string{{"Ctrl+Enter", i18n.later("copy")}, {"Ctrl+S", i18n.later("save")}, {"Esc", i18n.later("cancel")}}
@(private = "file") filter_labels := [len(Filter)]string{i18n.later("All"), i18n.later("Text"), i18n.later("Images"), i18n.later("Files"), i18n.later("Pinned")}
