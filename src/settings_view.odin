package papier

// The settings: gui_toolkit's page of the preferences (gt:prefs_page), in place of the history. The gear of the title
// bar or Ctrl+, opens it; the arrow, Escape or Ctrl+, again goes back. Each change is applied at once: the toolkit's
// standard settings by prefs_page.standard_watch, papier's by settings_changed (the window reads its settings again and
// hands them to the watcher). The preferences' writer saves the file off this thread.

import i18n "gt:i18n"
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
	if prefs_page.escape_leaves(&app.settings_page) { app.settings_open = false }
}

// The General page shows where papier says what it did and its language: general.menu and general.autostart are papier's
// Setup's and `papier install`'s, which put the launcher and the start with the session in place.
@(private = "file", rodata) GENERAL_NAMES := [?]string{prefs_page.MESSAGES_PREF, prefs_page.LANGUAGE_PREF}

// The pages, their order and their icons: each a group of the registry (the first segment of a name). A page with no
// preference on this system is left out (history and capture on Windows).
@(private = "file")
settings_pages :: proc() -> []prefs_page.Page_Info {
	// (made once, at the first show of the settings: the language is in use by then)
	@(static) pages: [12]prefs_page.Page_Info
	if pages[0].category == "" {
		pages = {
			{category = "general",    title = i18n.tr("General"),          icon = lucide.SETTINGS, names = GENERAL_NAMES[:]},
			{category = "appearance", title = i18n.tr("Appearance"),       icon = lucide.PALETTE},
			{category = "window",     title = i18n.tr("Window"),           icon = lucide.APP_WINDOW},
			{category = "paste",      title = i18n.tr("Paste"),            icon = lucide.CLIPBOARD_PASTE},
			{category = "history",    title = i18n.tr("History"),          icon = lucide.HISTORY},
			{category = "capture",    title = i18n.tr("Capture"),          icon = lucide.CLIPBOARD},
			{category = "clipboard",  title = i18n.tr("Clipboard"),        icon = lucide.CLIPBOARD_CHECK},
			{category = "scrolling",  title = i18n.tr("Scrolling"),        icon = lucide.MOUSE},
			{category = "input",      title = i18n.tr("Input"),            icon = lucide.KEYBOARD},
			{category = "timing",     title = i18n.tr("Delays and menus"), icon = lucide.TIMER},
			{category = "update",     title = i18n.tr("Updates"),          icon = lucide.DOWNLOAD},
			{category = "rendering",  title = i18n.tr("Rendering"),        icon = lucide.MONITOR},
		}
	}
	return pages[:]
}

// The preferences that hold a key combination: recorded from the keys pressed.
@(private = "file", rodata)
HOTKEY_PREFS := [?]string{"window.shortcut"}

// What papier has to say under a line: the shortcut that does not work, and why; a title bar the desktop does not draw.
@(private = "file")
settings_problem :: proc(user: rawptr, name: string) -> string {
	app := (^App)(user)
	if name == prefs_page.SYSTEM_TITLE_PREF && app.settings.system_title && !platform.system_title_available(app.main.win) {
		return i18n.tr("This desktop draws no title bar for papier's window (GNOME): papier keeps its own.")
	}
	return name == "window.shortcut" ? app.shortcut_problem : ""
}

// The page, as large as the body.
settings_build :: proc(app: ^App) {
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.settings_page, &app.prefs, settings_options(app))
}

// What the page is given: its pages, papier's themes and the user's, the updater, the file; the palette lists its
// settings by them.
settings_options :: proc(app: ^App) -> prefs_page.Options {
	return {
		user = app, changed = settings_changed,
		hotkeys = HOTKEY_PREFS[:], problem = settings_problem,
		page_foot = settings_page_foot,
		updater = app.updater, restart = proc(user: rawptr) { app_restart((^App)(user), hidden = false) },
		pages = settings_pages(), icon_font = app.icons, search_icon = lucide.SEARCH, reset_icon = lucide.REFRESH_CW,
		file = app.prefs_path,
		version = "Papier " + APP_VERSION,
		themes = app.themes_file.all[:], themes_light = app.theme_shown.light, themes_file = &app.themes_file,
	}
}

// A setting chosen in the palette: the settings, on it alone.
settings_show :: proc(app: ^App, name: string) {
	app.settings_open = true
	prefs_page.show(&app.settings_page, &app.prefs, settings_options(app), name)
}

// Under the General page's preferences: the licence.
@(private = "file")
settings_page_foot :: proc(user: rawptr, category: string, em: f32) {
	if category == "general" { licence_section((^App)(user), em) }
}

// A preference was set or reset: papier's settings read again, handed to the watcher; the standard ones are applied by
// standard_watch already. The preferences' writer saves the file at the next turn of the loop (app_run), off this thread.
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
