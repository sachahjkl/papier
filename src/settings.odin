package papier

// The preferences: one registry (gt:config) for the daemon and the picker. The user's file is
// $XDG_CONFIG_HOME/papier/prefs (`papier set <name> <value>` writes it); `--pref name=value` overrides it for one run.
// The look, the text, the scrolling, the input, the delays, the rendering, the updates and the messages are the toolkit's
// standard settings (prefs_page.standard_register, gui_toolkit docs/settings.md); papier adds its own after them.

import "core:strings"
import config "gt:config"
import i18n "gt:i18n"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"

APP_NAME :: "papier"

// papier's identity in the standard settings: its theme and its name. The rest is the toolkit's, as in its other
// programs (prefs_page.STANDARD_DEFAULTS).
@(private = "file")
standard_defaults :: proc() -> prefs_page.Standard_Defaults {
	d := prefs_page.STANDARD_DEFAULTS
	d.theme, d.app_name = "Papier", APP_NAME
	return d
}

// The preferences of every system; each system adds its own (settings_linux.odin, settings_windows.odin). Their words
// are registered in English, before the language is known: the settings page translates them where it shows them
// (i18n.later marks them for the catalogue). The titles are the ones the names make, written out to be translated.
PREF_DEFS := [?]config.Def{
	{name = "paste.on_select", title = i18n.later("On select"), description = i18n.later("An entry chosen (Enter, a double click, Alt+1…9) is pasted into the program papier was called from: the window hides and papier presses the paste keys there."), kind = .Bool, default = {b = true}, tags = {"auto paste", "insert", "type"}},
	{name = "paste.keys", title = i18n.later("Keys"), description = i18n.later("The keys papier presses to paste: Ctrl+V in most programs, Ctrl+Shift+V in a terminal, Shift+Insert in both on many systems."), kind = .String, default = {s = "Ctrl+V"}, tags = {"ctrl+v", "terminal", "shortcut"}},
	{name = "window.close_on_copy", title = i18n.later("Close on copy"), description = i18n.later("Close the window when an entry is copied."), kind = .Bool, default = {b = true}, tags = {"hide", "dismiss"}},
	{name = "window.width", title = i18n.later("Width"), description = i18n.later("The window's width at its first start, in logical pixels."), kind = .Int, default = {i = 900}, min = 320, max = 4000, bounded = true, unit = "px", tags = {"size", "window"}},
	{name = "window.height", title = i18n.later("Height"), description = i18n.later("The window's height at its first start, in logical pixels."), kind = .Int, default = {i = 560}, min = 240, max = 4000, bounded = true, unit = "px", tags = {"size", "window"}},
}

// The values the program reads, copied out of the registry (prefs_read).
Settings :: struct {
	max_entries:    int,
	max_age_days:   int,
	persist:        bool,
	capture:        Capture_Options,
	primary:        bool,
	max_bytes:      int,
	keep:           bool,
	close_on_copy:  bool,
	paste_on_select: bool,
	paste_keys:     string,   // as platform.hotkey_parse reads it
	look:           prefs_page.Appearance,   // appearance.theme, mode, finish, glow, font_size
	size:           [2]int,
	shortcut:       string,   // Windows: window.shortcut
	follow:         platform.Active_Monitor,   // Windows: window.follow
	update_auto:    bool,
	system_title:   bool,     // window.system_title
	messages:       ui.Announce_Mode,   // general.messages: where "Copied", "Saved"... are said
}

prefs_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.Config, APP_NAME, context.temp_allocator), "/prefs"}, allocator)
}

// The user's own themes, beside the preferences (prefs_page.Themes_File).
themes_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.Config, APP_NAME, context.temp_allocator), "/themes.txt"}, allocator)
}

// Where the window's state is (state.odin): the user's state folder, "window".
state_path :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.State, APP_NAME, context.temp_allocator), "/window"}, allocator)
}

// The registry with the user's file and `args`' --pref read in. Returns the arguments that are not preferences.
// `descriptions`: where the toolkit's standard preferences make their descriptions, which the registry keeps and never
// frees (a registry read for one turn of a loop gives its temporary allocator).
prefs_open :: proc(p: ^config.Prefs, args: []string, descriptions := context.allocator) -> (rest: [dynamic]string, problems: [dynamic]string) {
	p^ = config.prefs_make()
	prefs_page.standard_register(p, prefs_page.STANDARD_ALL, standard_defaults(), descriptions)
	config.register(p, PREF_DEFS[:])
	config.register(p, PREF_DEFS_SYSTEM[:])
	_, file_problems := config.load_file(p, prefs_file(), .User)
	rest, problems = config.apply_args(p, args, context.temp_allocator)
	append(&problems, ..file_problems[:])
	return
}

prefs_read :: proc(p: ^config.Prefs, allocator := context.allocator) -> (s: Settings) {
	s.close_on_copy = config.bool_of(p, "window.close_on_copy")
	s.paste_on_select = config.bool_of(p, "paste.on_select")
	s.paste_keys = strings.clone(config.string_of(p, "paste.keys"), allocator)
	s.look = prefs_page.appearance_read(p, allocator)
	s.system_title = config.bool_of(p, prefs_page.SYSTEM_TITLE_PREF)
	s.size = {int(config.int_of(p, "window.width")), int(config.int_of(p, "window.height"))}
	s.update_auto = config.bool_of(p, prefs_page.UPDATE_AUTO_PREF)
	s.messages = prefs_page.announce_mode(p)
	prefs_read_system(p, &s, allocator)
	return
}

settings_free :: proc(s: ^Settings) {
	for m in s.capture.ignore_mimes { delete(m) }
	delete(s.capture.ignore_mimes)
	prefs_page.appearance_destroy(&s.look)
	delete(s.shortcut)
	delete(s.paste_keys)
	s^ = {}
}
