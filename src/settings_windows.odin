#+build windows
package papier

// The preferences of Windows: the system keeps the history (its length, what it records: Settings > System >
// Clipboard); papier only shows it, at a shortcut of its own.

import "core:strings"
import config "gt:config"
import "gt:platform"

PREF_DEFS_SYSTEM := [?]config.Def{
	{name = "picker.shortcut", category = "window", description = "The keys that show the history from any program: Ctrl, Shift, Alt, Win and a key, joined by +. Win+V stays the system's.", kind = .String, default = {s = "Win+Shift+V"}},
}

prefs_read_system :: proc(p: ^config.Prefs, s: ^Settings, allocator := context.allocator) {
	s.shortcut = strings.clone(config.string_of(p, "picker.shortcut"), allocator)
}

// The system has one history, and papier no directory of its own for it.
history_dir :: proc(persist: bool, allocator := context.temp_allocator) -> string { return "" }

// Where the window's state is (state.odin): %APPDATA%\papier\window, beside the preferences.
state_path :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.config_dir(context.temp_allocator), "/", APP_NAME, "/window"}, allocator)
}
