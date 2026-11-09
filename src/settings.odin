package papier

// The preferences: one registry (gt:config) for the daemon and the picker. The user's file is
// $XDG_CONFIG_HOME/papier/prefs (`papier set <name> <value>` writes it); `--pref name=value` overrides it for one run.

import "core:os"
import "core:strings"
import config "gt:config"
import "gt:platform"
import "gt:ui"

APP_NAME :: "papier"


PREF_DEFS := [?]config.Def{
	{name = "history.max_entries", description = "How many entries the history keeps, pinned ones aside. 0: no limit.", kind = .Int, default = {i = 1000}, min = 0, max = 1_000_000, bounded = true},
	{name = "history.max_age_days", description = "Entries older than this many days go, pinned ones aside. 0: no limit.", kind = .Int, default = {i = 0}, min = 0, max = 36500, bounded = true, unit = "days"},
	{name = "history.persist", description = "Keep the history on the disk across sessions. Off: it lives in $XDG_RUNTIME_DIR and goes at logout.", kind = .Bool, default = {b = true}, restart = true},
	{name = "capture.text", description = "Record text.", kind = .Bool, default = {b = true}},
	{name = "capture.html", description = "Record the HTML that comes with a copy from a browser or an editor.", kind = .Bool, default = {b = true}},
	{name = "capture.image", description = "Record images.", kind = .Bool, default = {b = true}},
	{name = "capture.files", description = "Record files copied in a file manager.", kind = .Bool, default = {b = true}},
	{name = "capture.primary", description = "Also record the primary selection (the text selected with the mouse).", kind = .Bool, default = {b = false}},
	{name = "capture.max_bytes", description = "A representation larger than this is not recorded.", kind = .Int, default = {i = 64 << 20}, min = 1024, max = 2 << 30, bounded = true, bytes = true, unit = "bytes"},
	{name = "capture.ignore_secrets", description = "Do not record what a password manager marks as secret (x-kde-passwordManagerHint).", kind = .Bool, default = {b = true}},
	{name = "capture.ignore_mimes", description = "MIME types, separated by commas: a copy that offers one of them is not recorded.", kind = .String, default = {s = ""}},
	{name = "clipboard.keep", description = "When the program that owned the clipboard quits and empties it, put the last entry back.", kind = .Bool, default = {b = true}},
	{name = "picker.close_on_copy", description = "Close the picker when an entry is copied.", kind = .Bool, default = {b = true}},
	{name = "picker.theme", description = "The window's colours: Papier, or a theme of the toolkit by its name (Midnight, Nord, Gruvbox, Tokyo Night, Catppuccin, Rosé Pine...).", kind = .String, default = {s = "Papier"}},
	{name = "picker.mode", description = "The theme's version: the system's (light or dark, followed as it changes), dark, or light.", kind = .String, default = {s = "system"}, choices = {"system", "dark", "light"}},
	{name = "picker.finish", description = "How surfaces are drawn. Machined: bevelled buttons, sunken fields, carved lines (flat in a light version). Flat: plain surfaces and thin lines.", kind = .String, default = {s = "machined"}, choices = {"machined", "flat", "gradient", "glass"}},
	{name = "picker.glow", description = "The halos of the machined finish: a focused field's ring of light.", kind = .Bool, default = {b = true}},
	{name = "picker.width", description = "The picker's width, in logical pixels.", kind = .Int, default = {i = 900}, min = 320, max = 4000, bounded = true},
	{name = "picker.height", description = "The picker's height, in logical pixels.", kind = .Int, default = {i = 560}, min = 240, max = 4000, bounded = true},
	{name = "picker.font_size", description = "The picker's text size, in logical pixels.", kind = .Float, default = {f = 14}, min = 8, max = 40, bounded = true},
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
	theme:          string,
	mode:           ui.Theme_Mode,
	finish:         ui.Finish,
	glow:           bool,
	size:           [2]int,
	font_size:      f32,
}

prefs_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.config_dir(context.temp_allocator), "/", APP_NAME, "/prefs"}, allocator)
}

// The registry with the user's file and `args`' --pref read in. Returns the arguments that are not preferences.
prefs_open :: proc(p: ^config.Prefs, args: []string) -> (rest: [dynamic]string, problems: [dynamic]string) {
	p^ = config.prefs_make()
	config.register(p, PREF_DEFS[:])
	_, file_problems := config.load_file(p, prefs_file(), .User)
	rest, problems = config.apply_args(p, args, context.temp_allocator)
	append(&problems, ..file_problems[:])
	return
}

prefs_read :: proc(p: ^config.Prefs, allocator := context.allocator) -> (s: Settings) {
	s.max_entries = int(config.int_of(p, "history.max_entries"))
	s.max_age_days = int(config.int_of(p, "history.max_age_days"))
	s.persist = config.bool_of(p, "history.persist")
	s.capture = {
		text = config.bool_of(p, "capture.text"), html = config.bool_of(p, "capture.html"),
		image = config.bool_of(p, "capture.image"), files = config.bool_of(p, "capture.files"),
		ignore_secrets = config.bool_of(p, "capture.ignore_secrets"),
	}
	ignore := make([dynamic]string, allocator)
	for m in strings.split(config.string_of(p, "capture.ignore_mimes"), ",", context.temp_allocator) {
		if t := strings.trim_space(m); t != "" { append(&ignore, strings.clone(t, allocator)) }
	}
	s.capture.ignore_mimes = ignore[:]
	s.primary = config.bool_of(p, "capture.primary")
	s.max_bytes = int(config.int_of(p, "capture.max_bytes"))
	s.keep = config.bool_of(p, "clipboard.keep")
	s.close_on_copy = config.bool_of(p, "picker.close_on_copy")
	s.theme = strings.clone(config.string_of(p, "picker.theme"), allocator)
	s.mode = ui.theme_mode_of(config.string_of(p, "picker.mode"))
	s.finish = ui.finish_of(config.string_of(p, "picker.finish"))
	s.glow = config.bool_of(p, "picker.glow")
	s.size = {int(config.int_of(p, "picker.width")), int(config.int_of(p, "picker.height"))}
	s.font_size = f32(config.float_of(p, "picker.font_size"))
	return
}

settings_free :: proc(s: ^Settings) {
	for m in s.capture.ignore_mimes { delete(m) }
	delete(s.capture.ignore_mimes)
	delete(s.theme)
	s^ = {}
}

// Where the history is: $XDG_DATA_HOME/papier (persist), else $XDG_RUNTIME_DIR/papier (gone at logout).
history_dir :: proc(persist: bool, allocator := context.temp_allocator) -> string {
	if !persist {
		if run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); run != "" {
			return strings.concatenate({run, "/", APP_NAME}, allocator)
		}
	}
	if data := os.get_env("XDG_DATA_HOME", context.temp_allocator); data != "" {
		return strings.concatenate({data, "/", APP_NAME}, allocator)
	}
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/share/", APP_NAME}, allocator)
}
