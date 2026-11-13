package papier

// The edit view: the text of an entry in an editor, in place of its preview. What was edited goes back as a copy (a new
// entry at the top, on the clipboard) or in place of the entry (its id, place and pin kept).
//
//   Ctrl+Enter   copy the text (a new entry, on the clipboard)
//   Ctrl+S       save it in place of the entry
//   Escape       leave, nothing kept
//
// Rich text is edited as its text: what is saved is text.

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import i18n "gt:i18n"
import "gt:ui"
import "history"
import lucide "gt:lucide"

// The edit view's states: closed (not active, no pending), waiting for the entry's text from the reader (pending: the
// entry's id), open (active). A wait ends open when the text comes, closed when the selection moves on (view_load).
Edit :: struct {
	active:  bool,
	id:      u64,          // the entry edited
	pending: u64,          // the entry whose edit waits for its text (0: none)
	area:    ui.Text_Edit,
	fresh:   bool,         // the editor takes the keyboard at the next build
}

// Opens the edit view on the text of `e` (text and rich text), the selected entry: at once when the reader has loaded
// it, else when its text comes (app_follow_reader).
edit_begin :: proc(app: ^App, e: ^history.Entry) {
	if e.kind != .Text && e.kind != .Html { return }
	if !loaded_for(app, e) { app.edit.pending = e.id; return }
	app.edit.pending = 0
	ui.text_edit_set(&app.edit.area, app.loaded.text)
	ui.text_edit_clear_history(&app.edit.area)
	app.edit.active, app.edit.id, app.edit.fresh = true, e.id, true
}

edit_end :: proc(app: ^App) {
	app.edit.pending = 0
	if !app.edit.active { return }
	app.edit.active = false
	ui.text_edit_set(&app.edit.area, "")
	ui.text_edit_clear_history(&app.edit.area)
}

edit_copy :: proc(app: ^App) {
	text := ui.text_edit_string(&app.edit.area)
	if strings.trim_space(text) == "" { say(app, i18n.tr("Nothing to copy")); return }
	paste := app.settings.paste_on_select
	watcher_send(&app.watcher, {verb = .Add_Text, text = text, paste = paste})
	edit_end(app)
	if app.settings.close_on_copy || paste { app_hide(app) } else { announce(app, i18n.tr("Copied")) }
}

edit_save :: proc(app: ^App) {
	text := ui.text_edit_string(&app.edit.area)
	if strings.trim_space(text) == "" { say(app, i18n.tr("An empty entry is not saved: remove it instead")); return }
	watcher_send(&app.watcher, {verb = .Replace_Text, id = app.edit.id, text = text})
	edit_end(app)
	announce(app, i18n.tr("Saved"))
}

// The keys of the edit view, taken before the editor sees them.
edit_keys :: proc(app: ^App) {
	if ui.key_press(.Return, {.Ctrl}) { edit_copy(app); return }
	if ui.key_press(.S, {.Ctrl}) { edit_save(app); return }
}

// The edit view, in the preview's place.
edit_build :: proc(app: ^App, e: ^history.Entry, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.5))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.6))
		glyph(app, lucide.EDIT, em * 1.6, ui.color("accent"))
		ui.next({width = ui.text_size(em * 0.3), height = ui.pct(1)})
		ui.label(fmt.tprintf("%s###editing", i18n.tr("Editing")))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			if ui.style({font_size = em * 0.88}) {
				text := ui.text_edit_string(&app.edit.area)
				chars, lines := utf8.rune_count_in_string(text), ui.text_edit_line_count(&app.edit.area)
				// (the English says "1 characters", "1 lines": its two forms are one; a language with its own forms has them)
				ui.label(fmt.tprintf("%s · %s%s###editmeta",
					fmt.tprintf(i18n.tr(chars, "%d characters", "%d characters"), chars),
					fmt.tprintf(i18n.tr(lines, "%d lines", "%d lines"), lines),
					e.kind == .Html ? i18n.tr(" · saved as text") : ""))
			}
		}
		if icon_action(app, "editcopy", lucide.COPY, key_tip(i18n.tr("Copy"), {.Return, {.Ctrl}}), em) { edit_copy(app); return }
		if icon_action(app, "editsave", lucide.SAVE, key_tip(i18n.tr("Save in place"), {.S, {.Ctrl}}), em) { edit_save(app); return }
		if icon_action(app, "editcancel", lucide.X, key_tip(i18n.tr("Cancel"), {.Escape, {}}), em) { edit_end(app); return }
		ui.spacer(ui.px(em * 0.4))
	}
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row() {
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.fill(), font = app.mono, font_size = em * 0.95})
		// (code keeps its language's colours while it is edited; Markdown, a diff and prose are not code: plain)
		hl: ^ui.Text_Highlight
		if loaded_for(app, e) && app.loaded.form == .Code && app.loaded.has_code { hl = ui.code_highlight(app.loaded.code) }
		res := ui.text_edit("###editor", &app.edit.area, {placeholder = i18n.tr("The entry's text"), wrap = true, highlight = hl})
		if app.edit.fresh { ui.set_focus(res.box.key); app.edit.fresh = false }
		if res.cancelled { edit_end(app) }
		ui.spacer(ui.px(em * 0.5))
	}
	ui.spacer(ui.px(em * 0.5))
}
