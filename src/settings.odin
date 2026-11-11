package papier

// The preferences: one registry (gt:config) for the daemon and the picker. The user's file is
// $XDG_CONFIG_HOME/papier/prefs (`papier set <name> <value>` writes it); `--pref name=value` overrides it for one run.

import "core:strings"
import config "gt:config"
import "gt:platform"
import "gt:ui"

APP_NAME :: "papier"


// The preferences of every system; each system adds its own (settings_linux.odin, settings_windows.odin).
PREF_DEFS := [?]config.Def{
	{name = "paste.on_select", category = "paste", description = "An entry chosen (Enter, a double click, Alt+1…9) is pasted into the program papier was called from: the window hides and papier presses the paste keys there.", kind = .Bool, default = {b = true}, tags = {"auto paste", "insert", "type"}},
	{name = "paste.keys", category = "paste", description = "The keys papier presses to paste: Ctrl+V in most programs, Ctrl+Shift+V in a terminal, Shift+Insert in both on many systems.", kind = .String, default = {s = "Ctrl+V"}, tags = {"ctrl+v", "terminal", "shortcut"}},
	{name = "picker.close_on_copy", category = "window", description = "Close the picker when an entry is copied.", kind = .Bool, default = {b = true}, tags = {"hide", "dismiss"}},
	{name = "picker.theme", category = "appearance", description = "The window's colours: Papier, or a theme of the toolkit by its name (Midnight, Nord, Gruvbox, Tokyo Night, Catppuccin, Rosé Pine...).", kind = .String, default = {s = "Papier"}, tags = {"colours", "colors", "palette", "dark", "light", "look"}},
	{name = "picker.mode", category = "appearance", description = "The theme's version: the system's (light or dark, followed as it changes), dark, or light.", kind = .String, default = {s = "system"}, choices = {"system", "dark", "light"}, tags = {"dark", "light", "night", "day"}},
	{name = "picker.finish", category = "appearance", description = "How surfaces are drawn. Machined: bevelled buttons, sunken fields, carved lines (flat in a light version). Edged: the same reliefs drawn crisp, with square corners. Flat: plain surfaces and thin lines.", kind = .String, default = {s = "machined"}, choices = {"machined", "edged", "flat", "gradient", "glass"}, tags = {"style", "look", "bevel", "flat"}},
	{name = "picker.system_title", category = "window", description = "The window's title bar drawn by the system (its buttons, its snapping) in place of papier's own; the search and the filters go under it.", kind = .Bool, default = {b = false}, tags = {"decorations", "native", "frame", "title bar"}},
	{name = "picker.glow", category = "appearance", description = "The halos of the machined finish: a focused field's ring of light.", kind = .Bool, default = {b = true}, tags = {"halo", "light", "focus"}},
	{name = "picker.width", category = "window", description = "The picker's width, in logical pixels.", kind = .Int, default = {i = 900}, min = 320, max = 4000, bounded = true, tags = {"size", "window"}},
	{name = "picker.height", category = "window", description = "The picker's height, in logical pixels.", kind = .Int, default = {i = 560}, min = 240, max = 4000, bounded = true, tags = {"size", "window"}},
	{name = "update.auto", category = "updates", description = "The installed papier checks for a newer one once a day and installs it, then gives way to it when its window is hidden. A copy installed by a package manager (Nix) is updated by it.", kind = .Bool, default = {b = true}, tags = {"upgrade", "version", "automatic"}},
	{name = "picker.font_size", category = "appearance", description = "The picker's text size, in logical pixels.", kind = .Float, default = {f = 14}, min = 8, max = 40, bounded = true, tags = {"text size", "zoom", "bigger", "smaller"}},
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
	theme:          string,
	mode:           ui.Theme_Mode,
	finish:         ui.Finish,
	glow:           bool,
	size:           [2]int,
	font_size:      f32,
	shortcut:       string,   // Windows: picker.shortcut
	follow:         platform.Active_Monitor,   // Windows: picker.follow
	update_auto:    bool,
	system_title:   bool,     // picker.system_title
}

prefs_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.config_dir(context.temp_allocator), "/", APP_NAME, "/prefs"}, allocator)
}

// The registry with the user's file and `args`' --pref read in. Returns the arguments that are not preferences.
prefs_open :: proc(p: ^config.Prefs, args: []string) -> (rest: [dynamic]string, problems: [dynamic]string) {
	p^ = config.prefs_make()
	config.register(p, PREF_DEFS[:])
	config.register(p, PREF_DEFS_SYSTEM[:])
	_, file_problems := config.load_file(p, prefs_file(), .User)
	rest, problems = config.apply_args(p, args, context.temp_allocator)
	append(&problems, ..file_problems[:])
	return
}

prefs_read :: proc(p: ^config.Prefs, allocator := context.allocator) -> (s: Settings) {
	s.close_on_copy = config.bool_of(p, "picker.close_on_copy")
	s.paste_on_select = config.bool_of(p, "paste.on_select")
	s.paste_keys = strings.clone(config.string_of(p, "paste.keys"), allocator)
	s.theme = strings.clone(config.string_of(p, "picker.theme"), allocator)
	s.mode = ui.theme_mode_of(config.string_of(p, "picker.mode"))
	s.finish = ui.finish_of(config.string_of(p, "picker.finish"))
	s.glow = config.bool_of(p, "picker.glow")
	s.system_title = config.bool_of(p, "picker.system_title")
	s.size = {int(config.int_of(p, "picker.width")), int(config.int_of(p, "picker.height"))}
	s.font_size = f32(config.float_of(p, "picker.font_size"))
	s.update_auto = config.bool_of(p, "update.auto")
	prefs_read_system(p, &s, allocator)
	return
}

settings_free :: proc(s: ^Settings) {
	for m in s.capture.ignore_mimes { delete(m) }
	delete(s.capture.ignore_mimes)
	delete(s.theme)
	delete(s.shortcut)
	delete(s.paste_keys)
	s^ = {}
}
