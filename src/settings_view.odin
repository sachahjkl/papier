package papier

// The settings: gui_toolkit's page of the preferences (gt:prefs_page), in place of the history. The gear of the title
// bar or Ctrl+, opens it; the arrow, Escape or Ctrl+, again goes back. Each change is saved to the preferences file and
// applied at once: the window reads its settings again, and the watcher reads the file again (a Reload).

import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:ui"
import lucide "gt:lucide"

settings_toggle :: proc(app: ^App) {
	app.settings_open = !app.settings_open
	if app.settings_open { prefs_page.focus_search(&app.settings_page) }
}

// The keys of the settings: Escape goes back, unless an editor of a preference has the keyboard (Escape gives it back to
// the list first).
settings_keys :: proc(app: ^App) {
	if ui.key_press(.Comma, {.Ctrl}) { settings_toggle(app); return }
	if ui.key_press(.Escape) && !prefs_page.editing(&app.settings_page) { app.settings_open = false }
}

// The pages: the categories of the preferences (settings.odin), their order and their icons.
@(private = "file", rodata)
SETTINGS_PAGES := [?]prefs_page.Page_Info{
	{category = "appearance", title = "Appearance", icon = lucide.PALETTE},
	{category = "window",     title = "Window",     icon = lucide.APP_WINDOW},
	{category = "paste",      title = "Paste",      icon = lucide.CLIPBOARD},
	{category = "history",    title = "History",    icon = lucide.HISTORY},
	{category = "capture",    title = "Capture",    icon = lucide.CLIPBOARD},
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
	return name == "picker.shortcut" ? app.shortcut_problem : ""
}

// The page, as large as the body.
settings_build :: proc(app: ^App) {
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.settings_page, &app.prefs, {
		user = app, changed = settings_changed, choices = settings_choices,
		custom_names = CUSTOM[:], custom = settings_custom,
		hotkeys = HOTKEY_PREFS[:], problem = settings_problem,
		pages = SETTINGS_PAGES[:], icon_font = app.icons, search_icon = lucide.SEARCH, reset_icon = lucide.REFRESH_CW,
		foot = "prefs: ~/.config/papier/prefs",
	})
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

// A preference was set or reset: saved, and applied by the window and the watcher.
@(private = "file")
settings_changed :: proc(user: rawptr, name: string) {
	app := (^App)(user)
	if !config.save_user(&app.prefs, prefs_file()) { say(app, "The preferences cannot be written"); return }
	settings_free(&app.settings)
	app.settings = prefs_read(&app.prefs)
	watcher_send(&app.watcher, {verb = .Reload})
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
