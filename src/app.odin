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
import setup "gt:setup"
import "gt:ui"
import update "gt:update"
import "history"
import lucide "gt:lucide"

Filter :: enum u8 { All, Text, Images, Files, Pinned }   // (Pinned last: a system with no pins shows the others)

// Whether entries can be pinned: Windows's history has pins of its own, which it does not let a program read or set.
PINS :: ODIN_OS != .Windows
// The filters shown.
when PINS { FILTER_COUNT :: int(Filter.Pinned) + 1 } else { FILTER_COUNT :: int(Filter.Pinned) }


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
	setup:      setup.Dialog,       // the Setup (setup_view.odin)
	logo:       render.Texture,     // its logo (made at its first show)
	logo_made:  bool,
	launch_after: string,           // the installed copy, started once this one has ended (owned; "": none)
	launch_hidden: bool,            // and in the notification area (an update: updates.odin)
	updater:    ^update.Updater,    // updates.odin
	update_serial: int,             // the updater's state last said
	installed_copy: bool,           // this program is the installed copy: it updates itself (update.auto)
	hotkey_held: bool,              // Windows: picker.shortcut is registered
	shortcut_problem: string,       // why it is not (owned; "": it is)
	status:     string,             // a message for the status bar (owned), until status_until (ui clock, ms)
	status_until: f64,
}

app_run :: proc(prefs: ^config.Prefs, hidden: bool, owner: instance.Owner, setup_asked := false) -> int {
	app := new(App)
	defer free(app)
	app.prefs = prefs^
	prefs^ = {}
	app.settings = prefs_read(&app.prefs)
	app.place = state_load()

	platform.set_app_id(APP_NAME)
	size := app.place.size != {} ? app.place.size : app.settings.size
	if !host.host_open(&app.main, &app.shared, {title = "Papier", size = size, integrated_title = true}, view_build, app) {
		errln("papier: no window")
		return 1
	}
	h := &app.main
	win := h.win
	app.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
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
		errf("papier: the history cannot be opened: %s", why)
		return 1
	}
	refilter(app)
	if !watcher_start(&app.watcher, owner, win, &app.prefs) {
		errln("papier: the clipboard watcher cannot start")
		return 1
	}
	decoder_start(&app.decoder, win)
	app_shortcut(app)
	app_updates_start(app)
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
	if setup_asked { setup_open(app) } else if !hidden { setup_offer(app) }
	for !app.quit {
		if app.visible {
			host.hosts_wait({h})
		} else {
			platform.wait_event(win, 0)
			// (what came while hidden is nothing for the interface, but the shortcut)
			for e in platform.poll_events(win, false) { if e.kind == .Hotkey { app_toggle(app) } }
		}
		app_requests(app)
		app_tray(app)
		app_updates_follow(app)
		if view_decoded(app) { app.main.settle = max(app.main.settle, FRAMES_AFTER_INPUT) }
		if app.visible && !app.hide_due && !app.quit && !platform.is_closed(win) { host.host_frame(h) }
		if app.hide_due { app_hide_now(app) }
	}

	app_remember(app)
	update.updater_stop(app.updater)
	watcher_stop(&app.watcher)   // (the instance is let go: the installed copy, started below, is the running papier)
	decoder_stop(&app.decoder)
	devtools.stop(app.devtools)
	view_clear(app)
	if app.logo_made { render.destroy_texture(&app.shared.r, app.logo) }
	host.host_close(h)
	setup.finish(&app.setup, setup_config())
	launch, launch_hidden := app.launch_after, app.launch_hidden
	app.launch_after = ""
	app_free(app)
	if launch != "" {
		if !setup.launch(launch, launch_hidden ? []string{"--hidden"} : nil) { errf("papier: %s does not start", launch) }
		delete(launch)
	}
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
	setup.destroy(&app.setup)
	delete(app.launch_after)
	delete(app.shortcut_problem)
	delete(app.place.setup)
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
		if e.kind == .Hotkey { app_toggle(app); continue }
		append(&out, e)
	}
	return out[:]
}

// Shows the window as a new look at the history: the newest first, the search empty, the keyboard in it.
app_show :: proc(app: ^App) {
	// (Windows: the system's history is read again, now that papier is in the foreground; it comes as a reload)
	watcher_send(&app.watcher, {verb = .Refresh})
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
	// (Windows: on the screen the user works on, not the one it was last shown on: picker.follow)
	platform.move_to_active_monitor(app.main.win, app.settings.follow)
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

// The entry is on the clipboard: the window goes (if it has not), and papier presses the paste keys for the program that
// has the keyboard again, the one papier was called from. The hide goes to the compositor before the keys, on the same
// connection: the keys reach that program, not papier.
@(private = "file")
app_paste :: proc(app: ^App) {
	if app.visible { app_hide_now(app) }
	hk, ok := platform.hotkey_parse(app.settings.paste_keys)
	if !ok { errf("papier: paste.keys: %q is not a key combination (Ctrl+V, Ctrl+Shift+V, Shift+Insert...)", app.settings.paste_keys); return }
	if !platform.send_hotkey(app.main.win, hk) {
		errln("papier: the entry is on the clipboard, but this desktop lets no program press keys for another (Wayland: zwp_virtual_keyboard_v1): paste it yourself")
	}
}

app_toggle :: proc(app: ^App) {
	if app.visible && !app.hide_due { app_hide(app) } else { app_show(app) }
}

// The id of papier's hotkey (platform.hotkey_register).
HOTKEY_ID :: 1

// The shortcut that shows the history from any program (picker.shortcut), registered again when it changes. Linux has
// none of papier's own: the compositor binds `papier toggle` (docs/usage.md).
@(private = "file")
// What went wrong is kept for the settings (under the shortcut's line) and said in the status bar: a program of the
// windows subsystem has no console where an error would be read.
app_shortcut :: proc(app: ^App) {
	when ODIN_OS == .Windows {
		win := app.main.win
		platform.hotkey_unregister(win, HOTKEY_ID)
		app.hotkey_held = false
		delete(app.shortcut_problem)
		app.shortcut_problem = ""
		hk, ok := platform.hotkey_parse(app.settings.shortcut)
		switch {
		case !ok:
			app.shortcut_problem = fmt.aprintf("%q is not a shortcut: click the field and press the keys.", app.settings.shortcut)
		case !platform.hotkey_register(win, HOTKEY_ID, hk):
			app.shortcut_problem = fmt.aprintf("%s cannot be used: Windows or another program holds it, or this keyboard has no such key. Choose other keys.", platform.hotkey_text(hk))
		case:
			app.hotkey_held = true
		}
		if app.shortcut_problem != "" {
			errf("papier: picker.shortcut: %s", app.shortcut_problem)
			say(app, "The shortcut does not work: %s", app.shortcut_problem)
		}
	}
}

// While a field of the settings records keys, papier lets its shortcut go (Windows would take the very keys being
// recorded), and holds it again after. Called at each build.
app_shortcut_follow :: proc(app: ^App) {
	when ODIN_OS == .Windows {
		recording := ui.hotkey_recording()
		if recording && app.hotkey_held {
			platform.hotkey_unregister(app.main.win, HOTKEY_ID)
			app.hotkey_held = false
		} else if !recording && !app.hotkey_held && app.shortcut_problem == "" {
			app_shortcut(app)
		}
	}
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
	// (Wayland places windows itself; X11 and Windows let the program)
	if ODIN_OS == .Windows || platform.native_surface_handles(win).backend == .X11 {
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
			app_shortcut(app)
			app_updates_auto(app)
		case .Toggle: app_toggle(app)
		case .Show:   app_show(app)
		case .Hide:   app_hide(app)
		case .Setup:  app_show(app); setup_open(app)
		case .Paste:  app_paste(app)
		}
	}
	app_reload(app)
}

@(private = "file")
app_tray :: proc(app: ^App) {
	if app.tray == nil { return }
	for e in platform.tray_poll(app.tray) {
		#partial switch e.kind {
		case .Click: app_toggle(app)
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
