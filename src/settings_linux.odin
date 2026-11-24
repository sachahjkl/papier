#+build !windows
package papier

// The preferences of Linux: papier keeps the history and records the copies itself.

import "core:strings"
import config "gt:config"
import i18n "gt:i18n"
import "gt:platform"

PREF_DEFS_SYSTEM := [?]config.Def{
	{name = "history.max_entries", title = i18n.later("Max entries"), description = i18n.later("How many entries the history keeps, pinned ones aside. 0: no limit."), kind = .Int, default = {i = 1000}, min = 0, max = 1_000_000, bounded = true, tags = {"limit", "count", "size"}},
	{name = "history.max_age_days", title = i18n.later("Max age"), description = i18n.later("Entries older than this many days go, pinned ones aside. 0: no limit."), kind = .Int, default = {i = 0}, min = 0, max = 36500, bounded = true, value_kind = .Duration, unit = .Day, tags = {"expire", "age", "old"}},
	{name = "history.persist", title = i18n.later("Persist"), description = i18n.later("Keep the history on the disk across sessions. Off: it lives in $XDG_RUNTIME_DIR and goes at logout."), kind = .Bool, default = {b = true}, restart = true, tags = {"disk", "save", "keep", "reboot"}},
	{name = "capture.text", title = i18n.later("Text"), description = i18n.later("Record text."), kind = .Bool, default = {b = true}},
	{name = "capture.html", title = i18n.later("HTML"), description = i18n.later("Record the HTML that comes with a copy from a browser or an editor."), kind = .Bool, default = {b = true}},
	{name = "capture.image", title = i18n.later("Image"), description = i18n.later("Record images."), kind = .Bool, default = {b = true}},
	{name = "capture.files", title = i18n.later("Files"), description = i18n.later("Record files copied in a file manager."), kind = .Bool, default = {b = true}},
	{name = "capture.primary", title = i18n.later("Primary"), description = i18n.later("Also record the primary selection (the text selected with the mouse)."), kind = .Bool, default = {b = false}, tags = {"selection", "middle click"}},
	{name = "capture.size_limit", title = i18n.later("Size limit"), description = i18n.later("A representation larger than this is not recorded."), kind = .Int, default = {i = 64 << 20}, min = 1024, max = 2 << 30, bounded = true, value_kind = .Size, unit = .Byte, tags = {"large", "limit", "bytes"}},
	{name = "capture.ignore_secrets", title = i18n.later("Ignore secrets"), description = i18n.later("Do not record what a password manager marks as secret (x-kde-passwordManagerHint)."), kind = .Bool, default = {b = true}, tags = {"password", "private", "keepass"}},
	{name = "capture.ignore_mimes", title = i18n.later("Ignore mimes"), description = i18n.later("MIME types, separated by commas: a copy that offers one of them is not recorded."), kind = .String, default = {s = ""}},
	{name = "window.overlay", title = i18n.later("Overlay"), description = i18n.later("Show the history in a panel above every window, like a launcher."), kind = .Bool, default = {b = false}, restart = true, tags = {"layer shell", "popup", "launcher", "rofi", "float"}},
	{name = "clipboard.keep", title = i18n.later("Keep"), description = i18n.later("When the program that owned the clipboard quits and empties it, put the last entry back."), kind = .Bool, default = {b = true}, tags = {"restore", "persist"}},
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
	s.overlay = config.bool_of(p, "window.overlay")
}

// Where the history is: the user's data folder (persist, the vendor's folder), else the session's runtime folder,
// $XDG_RUNTIME_DIR/papier (gone at logout; the runtime folder keeps the technical name). Without that variable the
// toolkit's runtime folder is the system's temporary one, shared by every user: the store makes its folder the user's
// alone (history.open).
history_dir :: proc(persist: bool, allocator := context.temp_allocator) -> string {
	if persist { return platform.user_dir(.Data, APP_FOLDER, allocator) }
	return platform.user_dir(.Runtime, APP_NAME, allocator)
}
