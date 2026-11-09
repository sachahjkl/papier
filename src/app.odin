package papier

// The running papier: one process for the session. Its watcher thread keeps the history (watcher.odin); its window lists
// it (view.odin) and is hidden rather than closed, so that it comes back in a few milliseconds: no new process, device,
// fonts or history to read. A second `papier` hands "show" to this one over the instance socket and ends.
//
// The window's loop: visible, the host's frames; hidden, a wait on the window (a wake of the watcher, the tray) with no
// frame (a hidden window's frame would wait for a screen it is not on).

import "core:fmt"
import config "gt:config"
import "gt:devtools"
import "gt:font"
import "gt:host"
import instance "gt:instance"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:render"
import "gt:ui"
import "history"

Filter :: enum u8 { All, Text, Images, Files, Pinned }


// The tray menu's items.
Tray_Item :: enum { None, Show, Clear, Quit }

// Frames owed after an event, at a show (what it set off settles: the layout, the reveal of the selected row).
FRAMES_AFTER_INPUT :: 3
FRAMES_AT_SHOW     :: 4

App :: struct {
	shared:     host.Shared,
	main:       host.Host,
	icons:      font.Font_Id,   // Lucide (icons.odin)
	mono:       font.Font_Id,   // what a text entry is shown in
	prefs:      config.Prefs,
	settings:   Settings,
	watcher:    Watcher,
	decoder:    Decoder,            // the pictures of the preview (decoder.odin)
	tray:       ^platform.Tray,
	devtools:   ^devtools.Server,   // TOOLKIT_DEVTOOLS=<port>: driven and captured over the Chrome DevTools Protocol
	theme_shown: ui.Theme_Shown,    // the theme, mode and finish shown (ui.theme_show)
	visible:    bool,
	hide_due:   bool,               // app_hide was asked: the window goes after this frame
	quit:       bool,
	place:      Window_State,

	// the history, as the window reads it (the watcher writes it)
	store:      history.Store,
	seen:       u64,                // the watcher's version `store` was read at
	lowered:    [dynamic]string,    // each entry's preview in lower case (the search reads them)

	// the interface
	search:     ui.Text_Field,
	search_key: ui.Key,
	query:      string,             // what `shown` was filtered with (owned)
	filter:     Filter,
	vl:         ui.Virtual_List,
	shown:      [dynamic]int,       // the entries the search and the filter keep: indices in store.entries
	ids:        [dynamic]u64,       // their ids (the list's row identities)
	view:       View,
	menu:       Entry_Menu,         // the entry's menu (entry_menu.odin)
	edit:       Edit,               // the edit view (edit.odin)
	settings_open: bool,            // the settings in place of the history (settings_view.odin)
	settings_page: prefs_page.Page,
	sel_rect:   ui.Rect,            // the selected row, as last built (where the Menu key opens the menu)
	room:       f32,                // the window's width at this build, logical pixels
	status:     string,             // a message for the status bar (owned), until status_until (ui clock, ms)
	status_until: f64,
}

app_run :: proc(prefs: ^config.Prefs, hidden: bool, owner: instance.Owner) -> int {
	app := new(App)
	defer free(app)
	app.prefs = prefs^
	prefs^ = {}
	app.settings = prefs_read(&app.prefs)
	app.place = state_load()

	platform.set_app_id(APP_NAME)
	size := app.place.size != {} ? app.place.size : app.settings.size
	if !host.host_open(&app.main, &app.shared, {title = "Papier", size = size, integrated_title = true}, view_build, app) {
		fmt.eprintln("papier: no window")
		return 1
	}
	h := &app.main
	win := h.win
	app.icons, _ = font.load_embedded(&app.shared.fonts, LUCIDE_TTF)
	app.mono, _ = font.load_embedded(&app.shared.fonts, font.FALLBACK_MONO_DATA)
	h.state.icon_font, _ = font.load_embedded(&app.shared.fonts, ui.ICON_FONT_DATA)
	h.after_input = FRAMES_AFTER_INPUT
	h.params = app_params
	h.input = app_input
	app.devtools = devtools.start_from_env(win, "papier")
	h.before_input = proc(h: ^host.Host) { app := (^App)(h.user); devtools.service(app.devtools, &h.state, &app.shared.r) }
	if app.place.placed {
		p := platform.get_placement(win)
		p.rect[0], p.rect[1] = app.place.place.x, app.place.place.y
		platform.set_placement(win, p)
	}

	if ok, why := history.open(&app.store, history_dir(app.settings.persist)); !ok {
		fmt.eprintfln("papier: the history cannot be opened: %s", why)
		return 1
	}
	refilter(app)
	if !watcher_start(&app.watcher, owner, win, &app.prefs) {
		fmt.eprintln("papier: the clipboard watcher cannot start")
		return 1
	}
	decoder_start(&app.decoder, win)
	app.tray = platform.tray_create(win, LOGO_PNG, "Papier")
	if app.tray != nil {
		platform.tray_set_menu(app.tray, {
			{id = int(Tray_Item.Show), text = "Show the history", default = true},
			{kind = .Separator},
			{id = int(Tray_Item.Clear), text = "Clear the history (pinned entries stay)"},
			{id = int(Tray_Item.Quit), text = "Quit Papier"},
		})
	}

	// (hidden at start: the window is made and never shown, it has had no frame: nothing to take off the screen)
	if !hidden { app_show(app) }
	for !app.quit {
		if app.visible {
			host.hosts_wait({h})
		} else {
			platform.wait_event(win, 0)
			_ = platform.poll_events(win, false)   // (what came while hidden: nothing for the interface)
		}
		app_requests(app)
		app_tray(app)
		if view_decoded(app) { app.main.settle = max(app.main.settle, FRAMES_AFTER_INPUT) }
		if app.visible && !app.hide_due && !app.quit && !platform.is_closed(win) { host.host_frame(h) }
		if app.hide_due { app_hide_now(app) }
	}

	app_remember(app)
	watcher_stop(&app.watcher)
	decoder_stop(&app.decoder)
	devtools.stop(app.devtools)
	view_clear(app)
	host.host_close(h)
	app_free(app)
	return 0
}

@(private = "file")
app_free :: proc(app: ^App) {
	for s in app.lowered { delete(s) }
	delete(app.lowered)
	delete(app.shown)
	delete(app.ids)
	delete(app.query)
	delete(app.status)
	ui.field_destroy(&app.search)
	ui.vlist_destroy(&app.vl)
	entry_menu_free(&app.menu)
	ui.area_destroy(&app.edit.area)
	prefs_page.destroy(&app.settings_page)
	history.close(&app.store)
	settings_free(&app.settings)
	config.prefs_destroy(&app.prefs)
}

// What each build is given: the palette and the base style of the preferences.
@(private = "file")
app_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	app := (^App)(h.user)
	// (applied only when it changes, or the system goes light or dark: a palette applied starts a cross-fade)
	choice := ui.Theme_Choice{name = app.settings.theme, mode = app.settings.mode, finish = app.settings.finish, glow = app.settings.glow ? 1 : 0}
	if ui.theme_show(&app.shared.theme, themes(), choice, &app.theme_shown, render.blend_space(&app.shared.r)) { platform.set_dark_title(h.win, !app.theme_shown.light) }
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(28)}, font = app.shared.font, font_size = app.settings.font_size, text_pad = 6, cursor = .Arrow}
}

// The window's input before the interface: a close (the compositor's, the title bar's) hides the window.
@(private = "file")
app_input :: proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
	app := (^App)(h.user)
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for e in events {
		if e.kind == .Close {
			platform.cancel_close(h.win)
			app_hide(app)
			continue
		}
		append(&out, e)
	}
	return out[:]
}

// Shows the window as a new look at the history: the newest first, the search empty, the keyboard in it.
app_show :: proc(app: ^App) {
	app_reload(app)
	// a new look, unless the window is shown and stays so (a hide asked in this step, then a show: a new look, in place)
	if !app.visible || app.hide_due {
		edit_end(app)
		app.menu.close_due = true   // (closed at the next build: the interface is only touched from inside one)
		ui.field_clear(&app.search)
		app.filter = .All
		refilter(app)
		select_row(app, 0)
		ui.vlist_scroll_to(&app.vl, 0)
	}
	app.hide_due = false
	if app.visible {
		platform.raise_window(app.main.win)
		app.main.settle = max(app.main.settle, FRAMES_AT_SHOW)
		return
	}
	host.host_show(&app.main)
	// the keyboard: a compositor may not focus a new window by itself (ShojiWM's Windows 7 configuration)
	platform.raise_window(app.main.win)
	app.visible = true
	app.main.settle = max(app.main.settle, FRAMES_AT_SHOW)
}

// The window goes at the end of this step of the loop: a build asks it (a key, a button), and the frame that asked ends
// first.
app_hide :: proc(app: ^App) {
	if app.visible { app.hide_due = true }
}

@(private = "file")
app_hide_now :: proc(app: ^App) {
	app.hide_due = false
	if !app.visible { return }
	app_remember(app)
	host.host_hide(&app.main)
	app.visible = false
	view_clear(app)   // (its texture is the GPU's memory, for an entry that may be gone at the next show)
}

// What the window remembers (state.odin): its size, its place on X11, the list's width.
@(private = "file")
app_remember :: proc(app: ^App) {
	win := app.main.win
	if win == nil || !platform.is_window_visible(win) { return }
	s := win.dpi_scale > 0 ? win.dpi_scale : 1
	app.place.size = {int(f32(win.size.x) / s + 0.5), int(f32(win.size.y) / s + 0.5)}
	if platform.native_surface_handles(win).backend == .X11 {
		p := platform.get_placement(win)
		app.place.place, app.place.placed = {p.rect[0], p.rect[1]}, true
	}
	state_save(app.place)
}

// The history again when the watcher wrote it.
@(private = "file")
app_reload :: proc(app: ^App) {
	v := watcher_version(&app.watcher)
	if v == app.seen { return }
	app.seen = v
	keep := selected_id(app)
	history.reload(&app.store)
	// (the order may have changed with the count the same: an entry copied again moves to the top)
	for s in app.lowered { delete(s) }
	clear(&app.lowered)
	refilter(app)
	if keep != 0 { for id, i in app.ids { if id == keep { app.vl.sel = i; break } } }
	app.main.settle = max(app.main.settle, FRAMES_AFTER_INPUT)
}

// What the watcher asked for.
@(private = "file")
app_requests :: proc(app: ^App) {
	// (in the order they came: a hide then a show ends shown, whatever came between two steps of the loop)
	for r in watcher_take_requests(&app.watcher) {
		switch r {
		case .Quit: app.quit = true; return
		case .Reload:
			config.prefs_destroy(&app.prefs)
			prefs_open(&app.prefs, nil)
			settings_free(&app.settings)
			app.settings = prefs_read(&app.prefs)
		case .Toggle: if app.visible && !app.hide_due { app_hide(app) } else { app_show(app) }
		case .Show:   app_show(app)
		case .Hide:   app_hide(app)
		}
	}
	app_reload(app)
}

@(private = "file")
app_tray :: proc(app: ^App) {
	if app.tray == nil { return }
	for e in platform.tray_poll(app.tray) {
		#partial switch e.kind {
		case .Click: if app.visible && !app.hide_due { app_hide(app) } else { app_show(app) }
		case .Menu_Item:
			switch Tray_Item(e.item) {
			case .Show:  app_show(app)
			case .Clear: watcher_send(&app.watcher, {verb = .Clear})
			case .Quit:  app.quit = true
			case .None:
			}
		}
	}
}

// Shows a message in the status bar for a few seconds.
say :: proc(app: ^App, format: string, args: ..any) {
	delete(app.status)
	app.status = fmt.aprintf(format, ..args)
	app.status_until = ui.now_ms() + STATUS_SHOWN_MS
	ui.wake_within(&app.main.state, STATUS_SHOWN_MS + 1)
}

STATUS_SHOWN_MS :: 3000

// papier's own theme, first of the list: ink and paper, a soft sand accent (the colours of the logo).
THEME_PAPIER :: ui.Theme_Def{"Papier",
	{{0x0e0e10ff, 0x131315ff, 0x1a1a1dff, 0x1a1a1dff, 0x232327ff, 0x2a2a30ff}, {0x5c5954ff, 0x8e8a84ff, 0xece8e1ff, 0xfffaf2ff},
		{0xcbbca3ff, 0x8fa9c9ff, 0xa99bc4ff, 0x46a758ff, 0xf5a524ff, 0xe5484dff, 0x95c3c8ff, 0xc9a0b4ff}},
	{{0xebe7dfff, 0xf6f3edff, 0xffffffff, 0xffffffff, 0xeeeae2ff, 0xe0dbd1ff}, {0xa39e95ff, 0x6f6a63ff, 0x1b1b1fff, 0x000000ff},
		{0x8a7a62ff, 0x3d6a9eff, 0x6b56a3ff, 0x2f8f46ff, 0xc98a10ff, 0xd93d42ff, 0x2f7c86ff, 0xa64a72ff}},
	.Both, nil, false, 0}

// The themes the window can show: papier's, then the toolkit's (gui_toolkit docs/themes.md).
themes :: proc() -> []ui.Theme_Def {
	@(static) list: [len(ui.THEMES) + 1]ui.Theme_Def
	if list[0].name == "" {
		list[0] = THEME_PAPIER
		copy(list[1:], ui.THEMES[:])
	}
	return list[:]
}
