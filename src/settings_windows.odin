#+build windows
package papier

// The preferences of Windows: the system keeps the history (its length, what it records: Settings > System >
// Clipboard); papier only shows it, at a shortcut of its own.

import "core:strings"
import config "gt:config"
import "gt:platform"

PREF_DEFS_SYSTEM := [?]config.Def{
	{name = "picker.shortcut", category = "window", description = "The keys that show the history from any program. In the settings, click the field and press them; as text, Ctrl, Shift, Alt, Win and a key joined by + (Ctrl+Shift+ù). Win+V stays the system's.", kind = .String, default = {s = "Ctrl+Shift+ù"}, tags = {"hotkey", "keybinding", "keys", "open"}},
	{name = "picker.follow", category = "window", description = "The screen the window shows on: the one under the mouse pointer, or the one of the window in front.", kind = .String, default = {s = "pointer"}, choices = {"pointer", "focus"}, tags = {"monitor", "screen", "display", "mouse"}},
}

prefs_read_system :: proc(p: ^config.Prefs, s: ^Settings, allocator := context.allocator) {
	s.shortcut = strings.clone(config.string_of(p, "picker.shortcut"), allocator)
	s.follow, _ = platform.active_monitor_parse(config.string_of(p, "picker.follow"))
}

// The system has one history, and papier no directory of its own for it.
history_dir :: proc(persist: bool, allocator := context.temp_allocator) -> string { return "" }

// Where the window's state is (state.odin): %APPDATA%\papier\window, beside the preferences.
state_path :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.Config, APP_NAME, context.temp_allocator), "/window"}, allocator)
}

// A path as the user reads it: Windows' separators (temp allocator).
path_shown :: proc(path: string) -> string {
	out, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	return out
}
