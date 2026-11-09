package papier

// The menu of an entry: a right click on its row, or the Menu key / Shift+F10 on the selected one. What it does:
//
//   Copy                 Enter         the entry back on the clipboard
//   Copy as plain text                 its text only, without its rich text (rich text only)
//   Edit…                Ctrl+E        the edit view (text and rich text)
//   Open                 Ctrl+O        an address in the browser, a file with its program, the rest as a file of its type
//   Open with  ▸                       the applications the system knows for its type (gt:desktop's Open with)
//   Show in folder                     a copied file in the file manager
//   Save as…             Ctrl+S        its bytes into a file the user names
//   Pin / Unpin          Ctrl+P
//   Remove               Shift+Del
//
// An entry that is not a file is written to a file of its own to be opened (open_dir): a program needs a path.

import "core:fmt"
import "core:os"
import "core:strings"
import desktop "gt:desktop"
import "gt:fsx"
import "gt:platform"
import "gt:ui"
import "history"

// The menu's width, in ems.
MENU_WIDTH_EM :: 16

Entry_Menu :: struct {
	key:      ui.Key,
	id:       u64,                 // the entry it was opened on
	handlers: []desktop.Handler,   // "Open with", read when the menu opened (owned)
	close_due: bool,               // a new look at the history (app_show): the menu closes at the next build
}

// Opens the menu of entry `e` at `pos` (window pixels).
entry_menu_open :: proc(app: ^App, e: ^history.Entry, pos: ui.Vec2, from_keyboard := false) {
	m := &app.menu
	if m.key == 0 { m.key = ui.key_from_string(0, "papier_entry_menu") }
	entry_menu_free(m)
	m.id, m.close_due = e.id, false
	// (the type is in the name: the file need not be written for its applications to be found)
	m.handlers = desktop.handlers_for_file(entry_file_name(e))
	ui.ctx_menu_open(m.key, pos, from_keyboard = from_keyboard)
}

entry_menu_free :: proc(m: ^Entry_Menu) {
	if m.handlers != nil { desktop.handlers_destroy(m.handlers) }
	m.handlers = nil
}

// The menu, when it is open (built at the end of the window's build).
entry_menu_build :: proc(app: ^App, em: f32) {
	m := &app.menu
	if m.key == 0 { return }
	if m.close_due { ui.ctx_menu_close(); m.close_due = false }
	if ui.ctx_menu(m.key, em * MENU_WIDTH_EM) {
		at := history.find(&app.store, m.id)
		if at < 0 { ui.ctx_menu_close(); return }
		e := &app.store.entries[at]
		text_kind := e.kind == .Text || e.kind == .Html
		if ui.menu_item("Copy", "Enter").clicked { entry_copy(app, e.id) }
		if e.kind == .Html && history.rep_find(e^, TEXT_MIME) >= 0 {
			if ui.menu_item("Copy as plain text").clicked { entry_copy(app, e.id, plain = true) }
		}
		if ui.menu_item("Edit…", "Ctrl+E", enabled = text_kind).clicked { edit_begin(app, e) }
		ui.menu_separator()
		if ui.menu_item("Open", "Ctrl+O").clicked { entry_open(app, e) }
		if ui.menu_submenu("Open with", enabled = len(m.handlers) > 0) {
			for h in m.handlers {
				label := h.default ? fmt.tprintf("%s (default)", h.name) : h.name
				if ui.menu_item(label).clicked { entry_open_with(app, e, h.id) }
			}
		}
		if e.kind == .Files {
			if ui.menu_item("Show in folder").clicked {
				if !platform.reveal_in_folder(entry_file_name(e)) { say(app, "The file manager does not start") }
			}
		}
		if ui.menu_item("Save as…", "Ctrl+S", enabled = e.kind != .Files).clicked { entry_save_as(app, e) }
		ui.menu_separator()
		if PINS && ui.menu_item(e.pinned ? "Unpin" : "Pin", "Ctrl+P").clicked { toggle_pin(app, e) }
		if ui.menu_item("Remove", "Shift+Del").clicked { remove_entry(app, e.id) }
	}
}

////////////////////////////////
// What the items do

// Puts the entry back on the clipboard (the watcher serves it) and hides the window. `plain`: its text only.
entry_copy :: proc(app: ^App, id: u64, plain := false) {
	paste := app.settings.paste_on_select
	watcher_send(&app.watcher, {verb = plain ? .Copy_Plain : .Copy, id = id, paste = paste})
	// (a paste goes to the program papier was called from: the window goes first)
	if app.settings.close_on_copy || paste { app_hide(app) } else { say(app, "Copied") }
}

// An address in the browser, a copied file with its program, anything else as a file of its type with the system's
// program for it.
entry_open :: proc(app: ^App, e: ^history.Entry) {
	if e.kind == .Text {
		if url := strings.trim_space(e.preview); is_address(url) {
			if !platform.open_url(url) { say(app, "No program opens addresses") }
			return
		}
	}
	path, ok := entry_file(app, e)
	if !ok { say(app, "The entry cannot be written to a file"); return }
	if !platform.open_path(path) { say(app, "No program opens %s", file_name(path)) }
}

entry_open_with :: proc(app: ^App, e: ^history.Entry, handler: string) {
	path, ok := entry_file(app, e)
	if !ok { say(app, "The entry cannot be written to a file"); return }
	if !desktop.open_with(path, handler) { say(app, "The program does not start") }
}

entry_save_as :: proc(app: ^App, e: ^history.Entry) {
	at := entry_open_rep(e)
	if at < 0 { return }
	r := platform.save_file_dialog({owner = app.main.win, title = "Save the entry", suggested_name = entry_file_name(e), overwrite_prompt = true}, context.temp_allocator)
	if r.status != .Chosen || len(r.paths) == 0 { return }
	data := history.blob_read(&app.store, e.reps[at].hash, context.temp_allocator)
	if data == nil || !fsx.write_atomic(r.paths[0], data) { say(app, "%s cannot be written", file_name(r.paths[0])); return }
	say(app, "Saved %s", file_name(r.paths[0]))
}

////////////////////////////////
// The entry as a file

// The representation a program opens: the picture of an image, the markup of rich text, else the main one.
entry_open_rep :: proc(e: ^history.Entry) -> int {
	#partial switch e.kind {
	case .Image: if at := history.rep_find(e^, "image/"); at >= 0 { return at }
	case .Html:  if at := history.rep_find(e^, HTML_MIME); at >= 0 { return at }
	}
	for r, i in e.reps { if r.hash == e.key { return i } }
	return len(e.reps) > 0 ? 0 : -1
}

// The name of the entry as a file: a copied file's own path, else papier-<id>.<extension of its type>.
entry_file_name :: proc(e: ^history.Entry) -> string {
	if e.kind == .Files {
		first := e.preview
		if i := strings.index_byte(first, '\n'); i >= 0 { first = first[:i] }
		return first
	}
	at := entry_open_rep(e)
	return fmt.tprintf("papier-%d.%s", e.id, at >= 0 ? extension_of(e.reps[at].mime) : "bin")
}

// The file a program opens for the entry: a copied file itself, else its bytes written under open_dir (temp allocator).
entry_file :: proc(app: ^App, e: ^history.Entry) -> (path: string, ok: bool) {
	if e.kind == .Files { return entry_file_name(e), true }
	at := entry_open_rep(e)
	if at < 0 { return }
	data := history.blob_read(&app.store, e.reps[at].hash, context.temp_allocator)
	if data == nil { return }
	dir := open_dir()
	fsx.make_dirs(dir)
	path = fmt.tprintf("%s/%s", dir, entry_file_name(e))
	return path, fsx.write_atomic(path, data)
}

// Where the entries opened as files are written: the session's runtime directory (the user's alone, emptied at the
// end of the session), else the system's temporary folder.
open_dir :: proc() -> string {
	if run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); run != "" { return fmt.tprintf("%s/papier/open", run) }
	return fmt.tprintf("%s/papier-open", fsx.temp_dir(context.temp_allocator))
}

// The usual extension of a MIME type ("bin" when it has none here).
extension_of :: proc(mime: string) -> string {
	base := mime
	if i := strings.index_byte(base, ';'); i >= 0 { base = base[:i] }
	switch base {
	case "text/plain":    return "txt"
	case "text/html":     return "html"
	case "image/png":     return "png"
	case "image/jpeg":    return "jpg"
	case "image/gif":     return "gif"
	case "image/webp":    return "webp"
	case "image/bmp":     return "bmp"
	case "image/svg+xml": return "svg"
	}
	return "bin"
}

// One line that is an http(s) address.
is_address :: proc(s: string) -> bool {
	if strings.contains_any(s, " \t\n") { return false }
	return strings.has_prefix(s, "https://") || strings.has_prefix(s, "http://")
}

file_name :: proc(path: string) -> string {
	if i := strings.last_index_any(path, "/\\"); i >= 0 { return path[i + 1:] }
	return path
}
