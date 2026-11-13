#+build windows
package papier

// The preferences of Windows: the system keeps the history (its length, what it records: Settings > System >
// Clipboard); papier only shows it, at a shortcut of its own.

import "core:strings"
import config "gt:config"
import "gt:platform"

PREF_DEFS_SYSTEM := [?]config.Def{
	{name = "window.shortcut", description = "The keys that show the history from any program. In the settings, click the field and press them; as text, Ctrl, Shift, Alt, Win and a key joined by + (Ctrl+Shift+ù). Win+V stays the system's.", kind = .String, default = {s = "Ctrl+Shift+ù"}, tags = {"hotkey", "keybinding", "keys", "open"}},
	{name = "window.follow", description = "The screen the window shows on: the one under the mouse pointer, or the one of the window in front.", kind = .String, default = {s = "pointer"}, choices = {"pointer", "focus"}, tags = {"monitor", "screen", "display", "mouse"}},
}

prefs_read_system :: proc(p: ^config.Prefs, s: ^Settings, allocator := context.allocator) {
	s.shortcut = strings.clone(config.string_of(p, "window.shortcut"), allocator)
	s.follow, _ = platform.active_monitor_parse(config.string_of(p, "window.follow"))
}

// The system has one history, and papier no directory of its own for it.
history_dir :: proc(persist: bool, allocator := context.temp_allocator) -> string { return "" }
