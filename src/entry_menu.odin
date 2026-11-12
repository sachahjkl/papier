package papier

// The menu of an entry: a right click on its row, or the Menu key / Shift+F10 on the selected one. What it does:
//
// Its items are the actions of actions.odin (their labels, keys and icons). With several entries marked, it offers what
// acts on all of them: copy their texts as one, pin, remove.
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
// An entry that is not a file is written to a file of its own to be opened (open_dir): a program needs a path. What
// reads the entry's bytes, writes a file or starts a program is a job of the reader (reader.odin); its message comes back
// to the status bar.

import "base:runtime"
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
	handlers: []desktop.Handler,   // "Open with": asked of the reader when the menu opened (its heap; nil until they come)
	close_due: bool,               // a new look at the history (app_show): the menu closes at the next build
}

// Opens the menu of entry `e` at `pos` (window pixels).
entry_menu_open :: proc(app: ^App, e: ^history.Entry, pos: ui.Vec2, from_keyboard := false) {
	m := &app.menu
	if m.key == 0 { m.key = ui.key_from_string(0, "papier_entry_menu") }
	entry_menu_free(m)
	m.id, m.close_due = e.id, false
	// (the system's lists of applications are files: the reader reads them, the submenu fills when they come)
	reader_job(&app.reader, {kind = .Handlers, id = e.id, path = entry_file_name(e)})
	ui.ctx_menu_open(m.key, pos, from_keyboard = from_keyboard)
}

// The applications for the entry the menu is open on, from the reader; let go when the menu moved on.
entry_menu_handlers :: proc(app: ^App, done: ^Job_Done) {
	m := &app.menu
	if done.id != m.id || m.handlers != nil { return }
	m.handlers, done.handlers = done.handlers, nil
}

entry_menu_free :: proc(m: ^Entry_Menu) {
	if m.handlers != nil { desktop.handlers_destroy(m.handlers, runtime.heap_allocator()) }
	m.handlers = nil
}

// The menu, when it is open (built at the end of the window's build).
entry_menu_build :: proc(app: ^App, em: f32) {
	m := &app.menu
	if m.key == 0 { return }
	if m.close_due { ui.ctx_menu_close(); m.close_due = false }
	if ui.ctx_menu(m.key, em * MENU_WIDTH_EM) {
		// (the menu is the selected entry's: it opens on it, and goes when the entry does)
		e := selected(app)
		if e == nil || e.id != m.id { ui.ctx_menu_close(); return }
		// (several marked: what acts on all of them; else the entry's own items)
		if n := ui.list_mark_count(&app.vl); n > 1 {
			item(app, .Copy, fmt.tprintf("Copy the %d texts as one", n))
			ui.menu_separator()
			if PINS { item(app, .Pin, fmt.tprintf("Pin or unpin the %d entries", n)) }
			item(app, .Remove, fmt.tprintf("Remove the %d entries", n))
			item(app, .Clear_Marks)
			return
		}
		item(app, .Copy)
		if action_enabled(app, .Copy_Plain) { item(app, .Copy_Plain) }
		item(app, .Edit)
		item(app, .Show_QR)
		// (an image: what it holds, when there is something to read; greyed while a reading runs)
		if action_enabled(app, .Copy_Qr_Content) { item(app, .Copy_Qr_Content) }
		if e.kind == .Image && ocr_offered(app) { item(app, .Copy_Image_Text) }
		ui.menu_separator()
		item(app, .Open)
		if ui.menu_submenu("Open with", enabled = len(m.handlers) > 0) {
			for h in m.handlers {
				label := h.default ? fmt.tprintf("%s (default)", h.name) : h.name
				if ui.menu_item(label).clicked { entry_open_with(app, e, h.id) }
			}
		}
		if e.kind == .Files {
			if ui.menu_item("Show in folder").clicked { reader_job(&app.reader, {kind = .Reveal, path = entry_file_name(e)}) }
		}
		item(app, .Save_As)
		ui.menu_separator()
		if PINS { item(app, .Pin, e.pinned ? "Unpin" : "Pin") }
		item(app, .Remove)
	}
}

// A line of the menu: an action, its keys and its icon from the table (actions.odin), greyed when it cannot act.
@(private = "file")
item :: proc(app: ^App, a: Action, label := "") {
	c := ACTIONS[a]
	if ui.menu_item(label != "" ? label : c.label, ui.command_shortcut(c), enabled = action_enabled(app, a), icon = c.icon).clicked { action_run(app, a) }
}

////////////////////////////////
// What the items do

// A text as a new entry at the top, on the clipboard (the watcher adds it): pasted and the window hidden as the
// settings say. `message` goes to the status bar.
copy_new_text :: proc(app: ^App, text: string, message: string) {
	paste := app.settings.paste_on_select
	watcher_send(&app.watcher, {verb = .Add_Text, text = text, paste = paste})
	if app.settings.close_on_copy || paste { app_hide(app) }
	say(app, "%s", message)
}

// Puts the entry back on the clipboard (the watcher serves it) and hides the window. `plain`: its text only.
entry_copy :: proc(app: ^App, id: u64, plain := false) {
	paste := app.settings.paste_on_select
	watcher_send(&app.watcher, {verb = plain ? .Copy_Plain : .Copy, id = id, paste = paste})
	// (a paste goes to the program papier was called from: the window goes first)
	if app.settings.close_on_copy || paste { app_hide(app) } else { say(app, "Copied") }
}

// An address in the browser, a copied file with its program, anything else as a file of its type with the system's
// program for it (the reader's job).
entry_open :: proc(app: ^App, e: ^history.Entry) {
	reader_job(&app.reader, {kind = .Open, id = e.id})
}

entry_open_with :: proc(app: ^App, e: ^history.Entry, handler: string) {
	reader_job(&app.reader, {kind = .Open_With, id = e.id, handler = handler})
}

// The system's dialog runs here (its own loop, as a drag's); the reader writes the file.
entry_save_as :: proc(app: ^App, e: ^history.Entry) {
	if entry_open_rep(e) < 0 { return }
	r := platform.save_file_dialog({owner = app.main.win, title = "Save the entry", suggested_name = entry_file_name(e), overwrite_prompt = true}, context.temp_allocator)
	if r.status != .Chosen || len(r.paths) == 0 { return }
	reader_job(&app.reader, {kind = .Save_As, id = e.id, path = r.paths[0]})
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
