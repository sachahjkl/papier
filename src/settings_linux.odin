#+build !windows
package papier

// The preferences of Linux: papier keeps the history and records the copies itself.

import "core:os"
import "core:strings"
import config "gt:config"

PREF_DEFS_SYSTEM := [?]config.Def{
	{name = "history.max_entries", category = "history", description = "How many entries the history keeps, pinned ones aside. 0: no limit.", kind = .Int, default = {i = 1000}, min = 0, max = 1_000_000, bounded = true, tags = {"limit", "count", "size"}},
	{name = "history.max_age_days", category = "history", description = "Entries older than this many days go, pinned ones aside. 0: no limit.", kind = .Int, default = {i = 0}, min = 0, max = 36500, bounded = true, unit = "days", tags = {"expire", "age", "old"}},
	{name = "history.persist", category = "history", description = "Keep the history on the disk across sessions. Off: it lives in $XDG_RUNTIME_DIR and goes at logout.", kind = .Bool, default = {b = true}, restart = true, tags = {"disk", "save", "keep", "reboot"}},
	{name = "capture.text", category = "capture", description = "Record text.", kind = .Bool, default = {b = true}},
	{name = "capture.html", category = "capture", description = "Record the HTML that comes with a copy from a browser or an editor.", kind = .Bool, default = {b = true}},
	{name = "capture.image", category = "capture", description = "Record images.", kind = .Bool, default = {b = true}},
	{name = "capture.files", category = "capture", description = "Record files copied in a file manager.", kind = .Bool, default = {b = true}},
	{name = "capture.primary", category = "capture", description = "Also record the primary selection (the text selected with the mouse).", kind = .Bool, default = {b = false}, tags = {"selection", "middle click"}},
	{name = "capture.size_limit", category = "capture", description = "A representation larger than this is not recorded.", kind = .Int, default = {i = 64 << 20}, min = 1024, max = 2 << 30, bounded = true, bytes = true, unit = "bytes", tags = {"large", "limit", "bytes"}},
	{name = "capture.ignore_secrets", category = "capture", description = "Do not record what a password manager marks as secret (x-kde-passwordManagerHint).", kind = .Bool, default = {b = true}, tags = {"password", "private", "keepass"}},
	{name = "capture.ignore_mimes", category = "capture", description = "MIME types, separated by commas: a copy that offers one of them is not recorded.", kind = .String, default = {s = ""}},
	{name = "clipboard.keep", category = "capture", description = "When the program that owned the clipboard quits and empties it, put the last entry back.", kind = .Bool, default = {b = true}, tags = {"restore", "persist"}},
}

prefs_read_system :: proc(p: ^config.Prefs, s: ^Settings, allocator := context.allocator) {
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
	s.max_bytes = int(config.int_of(p, "capture.size_limit"))
	s.keep = config.bool_of(p, "clipboard.keep")
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

// Where the window's state is (state.odin): $XDG_STATE_HOME/papier/window.
state_path :: proc(allocator := context.temp_allocator) -> string {
	if s := os.get_env("XDG_STATE_HOME", context.temp_allocator); s != "" {
		return strings.concatenate({s, "/", APP_NAME, "/window"}, allocator)
	}
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/state/", APP_NAME, "/window"}, allocator)
}
