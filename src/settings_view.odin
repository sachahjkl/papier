package papier

// The settings: gui_toolkit's page of the preferences (gt:prefs_page), in place of the history. The gear of the title
// bar or Ctrl+, opens it; the arrow, Escape or Ctrl+, again goes back. Each change is applied at once (the window reads
// its settings again), handed to the watcher, and saved to the preferences file by config's writer.

import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"

settings_toggle :: proc(app: ^App) {
	app.settings_open = !app.settings_open
	if app.settings_open { prefs_page.focus_search(&app.settings_page) }
}

// The keys of the settings: Escape goes back, unless an editor of a preference has the keyboard (Escape gives it back to
// the list first).
settings_keys :: proc(app: ^App) {
	if ui.command_pressed(ACTIONS[.Settings]) { settings_toggle(app); return }
	if ui.key_press(.Escape) && !prefs_page.editing(&app.settings_page) { app.settings_open = false }
}

// The pages, their order and their icons. A preference's group is now the first segment of its name (picker.theme is in
// "picker"), which mixes the look and the window: each page lists its preferences by name, so the pages stay papier's.
// A name not registered on this system (picker.shortcut on Linux) is left out by the page.
@(private = "file", rodata) APPEARANCE_NAMES := [?]string{"picker.theme", "picker.mode", "picker.finish", "picker.glow", "picker.font_size"}
@(private = "file", rodata) WINDOW_NAMES := [?]string{"picker.close_on_copy", "picker.system_title", "picker.width", "picker.height", "picker.shortcut", "picker.follow", prefs_page.MESSAGES_PREF}
@(private = "file", rodata) PASTE_NAMES := [?]string{"paste.on_select", "paste.keys"}
@(private = "file", rodata) HISTORY_NAMES := [?]string{"history.max_entries", "history.max_age_days", "history.persist"}
@(private = "file", rodata) CAPTURE_NAMES := [?]string{"capture.text", "capture.html", "capture.image", "capture.files", "capture.primary", "capture.size_limit", "capture.ignore_secrets", "capture.ignore_mimes", "clipboard.keep"}
@(private = "file", rodata) UPDATE_NAMES := [?]string{"update.auto"}

// (made at the first call: a page holds slices of the name lists above)
@(private = "file")
settings_pages :: proc() -> []prefs_page.Page_Info {
	@(static) pages: [6]prefs_page.Page_Info
	if pages[0].category == "" {
		pages = {
			{category = "appearance", title = "Appearance", icon = lucide.PALETTE,    names = APPEARANCE_NAMES[:]},
			{category = "window",     title = "Window",     icon = lucide.APP_WINDOW, names = WINDOW_NAMES[:]},
			{category = "paste",      title = "Paste",      icon = lucide.CLIPBOARD,  names = PASTE_NAMES[:]},
			{category = "history",    title = "History",    icon = lucide.HISTORY,    names = HISTORY_NAMES[:]},
			{category = "capture",    title = "Capture",    icon = lucide.CLIPBOARD,  names = CAPTURE_NAMES[:]},
			{category = "updates",    title = "Updates",    icon = lucide.DOWNLOAD,   names = UPDATE_NAMES[:]},
		}
	}
	return pages[:]
}

@(private = "file", rodata)
CUSTOM := [?]string{"picker.theme"}

// The preferences that hold a key combination: recorded from the keys pressed.
@(private = "file", rodata)
HOTKEY_PREFS := [?]string{"picker.shortcut"}

// What papier has to say under a line: the shortcut that does not work, and why.
@(private = "file")
settings_problem :: proc(user: rawptr, name: string) -> string {
	app := (^App)(user)
	if name == "picker.system_title" && app.settings.system_title && !platform.system_title_available(app.main.win) {
		return "This desktop draws no title bar for papier's window (GNOME): papier keeps its own."
	}
	return name == "picker.shortcut" ? app.shortcut_problem : ""
}

// The page, as large as the body.
settings_build :: proc(app: ^App) {
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.settings_page, &app.prefs, settings_options(app))
}

// What the page is given: its pages, its controls of papier's own, the updater; the palette lists its settings by them.
settings_options :: proc(app: ^App) -> prefs_page.Options {
	return {
		user = app, changed = settings_changed, choices = settings_choices,
		custom_names = CUSTOM[:], custom = settings_custom,
		hotkeys = HOTKEY_PREFS[:], problem = settings_problem,
		updater = app.updater, update_pref = "update.auto", restart = proc(user: rawptr) { app_restart((^App)(user), hidden = false) },
		pages = settings_pages(), icon_font = app.icons, search_icon = lucide.SEARCH, reset_icon = lucide.REFRESH_CW,
		foot = app.prefs_shown,
		version = "Papier " + APP_VERSION,
	}
}

// A setting chosen in the palette: the settings, on it alone.
settings_show :: proc(app: ^App, name: string) {
	app.settings_open = true
	prefs_page.show(&app.settings_page, &app.prefs, settings_options(app), name)
}

// The themes as cards, each in its own colours.
@(private = "file")
settings_custom :: proc(user: rawptr, name: string, em: f32) {
	app := (^App)(user)
	list := themes()
	if at := prefs_page.theme_cards(list, app.settings.theme, app.theme_shown.light, em); at >= 0 {
		if config.set_from_string(&app.prefs, "picker.theme", list[at].name, .User) == .None { settings_changed(app, "picker.theme") }
	}
}

// A preference was set or reset: applied by the window at once, handed to the watcher, and saved by the preferences'
// writer at the next turn of the loop (app_run), off this thread.
@(private = "file")
settings_changed :: proc(user: rawptr, name: string) {
	app := (^App)(user)
	settings_free(&app.settings)
	app.settings = prefs_read(&app.prefs)
	watcher_settings(&app.watcher, &app.prefs)
	app.announcer.mode = app.settings.messages
	app_updates_auto(app)
	app_title_follow(app)
}

// The choices of a preference known at run time: the themes.
@(private = "file")
settings_choices :: proc(user: rawptr, name: string) -> (labels, values: []string) {
	if name != "picker.theme" { return }
	list := themes()
	out := make([]string, len(list), context.temp_allocator)
	for t, i in list { out[i] = t.name }
	return out, out
}
