package papier

// What the user can do in the window, named once: each action's label, group, keys and icon (gui_toolkit's commands). The
// same table gives the keys, the entry menu's shortcuts, the tooltips, the command palette (Ctrl+K) and the sheet of the
// keys (F1). The moves of the selection (the arrows, Page Up/Down, Ctrl+Home/End, Alt+1…9) and Escape stay in view_keys:
// they are the list's, not commands.
//
// An action on entries acts on the marked rows (a Ctrl or Shift click, Ctrl+Shift+A), or on the selected one when none is
// marked.

import "core:mem/virtual"
import "core:slice"
import prefs_page "gt:prefs_page"
import i18n "gt:i18n"
import "gt:ui"
import lucide "gt:lucide"
import "history"

Action :: enum u8 {
	Copy, Copy_Plain, Edit, Open, Save_As, Pin, Remove, Show_QR, Copy_Qr_Content, Copy_Image_Text, Toggle_Markdown_Source,
	Mark_All, Clear_Marks,
	Filter_All, Filter_Text, Filter_Images, Filter_Files, Filter_Pinned, Filter_Next, Filter_Previous,
	Clear_History, Settings, Check_Updates, Palette, Shortcuts, Hide, Restart, Quit,
}

ACTIONS := [Action]ui.Command{
	.Copy            = {label = i18n.later("Copy"), group = i18n.later("Entry"), keys = {{.Return, {}}}, icon = lucide.COPY, tags = {"paste", "clipboard"}},
	.Copy_Plain      = {label = i18n.later("Copy as plain text"), group = i18n.later("Entry"), icon = lucide.TYPE, tags = {"text", "unformatted"}},
	.Edit            = {label = i18n.later("Edit…"), group = i18n.later("Entry"), keys = {{.E, {.Ctrl}}}, icon = lucide.EDIT, tags = {"change", "modify"}},
	.Open            = {label = i18n.later("Open"), group = i18n.later("Entry"), keys = {{.O, {.Ctrl}}}, icon = lucide.EXTERNAL_LINK, tags = {"launch", "browser"}},
	.Save_As         = {label = i18n.later("Save as…"), group = i18n.later("Entry"), keys = {{.S, {.Ctrl}}}, icon = lucide.SAVE, tags = {"export", "file", "write"}},
	.Pin             = {label = i18n.later("Pin or unpin"), group = i18n.later("Entry"), keys = {{.P, {.Ctrl}}}, icon = lucide.PIN, tags = {"favourite", "keep", "star"}},
	.Remove          = {label = i18n.later("Remove"), group = i18n.later("Entry"), keys = {{.Delete, {.Shift}}}, icon = lucide.TRASH_2, tags = {"delete", "erase", "forget"}},
	.Show_QR         = {label = i18n.later("Show as a QR code"), group = i18n.later("Entry"), keys = {{.Q, {.Ctrl, .Shift}}}, icon = lucide.QR_CODE, tags = {"phone", "scan", "share"}},
	.Copy_Qr_Content = {label = i18n.later("Copy the QR code's content"), group = i18n.later("Entry"), icon = lucide.QR_CODE, tags = {"scan", "read", "link"}},
	.Toggle_Markdown_Source = {label = i18n.later("Show the Markdown source or rendered"), group = i18n.later("Entry"), keys = {{.M, {.Ctrl, .Shift}}}, icon = lucide.FILE_CODE, tags = {"markdown", "source", "raw", "render"}},
	.Copy_Image_Text = {label = i18n.later("Copy the text of the image"), group = i18n.later("Entry"), keys = {{.T, {.Ctrl, .Shift}}}, icon = lucide.FILE_TEXT, tags = {"ocr", "recognize", "read", "screenshot", "scan"}},
	.Mark_All        = {label = i18n.later("Mark every entry shown"), group = i18n.later("Selection"), keys = {{.A, {.Ctrl, .Shift}}}, icon = lucide.LIST_CHECKS, tags = {"select all", "selection"}},
	.Clear_Marks     = {label = i18n.later("Clear the marks"), group = i18n.later("Selection"), icon = lucide.X},
	.Filter_All      = {label = i18n.later("Show every entry"), group = i18n.later("Filter"), icon = lucide.LIST},
	.Filter_Text     = {label = i18n.later("Show text"), group = i18n.later("Filter"), icon = lucide.ALIGN_LEFT},
	.Filter_Images   = {label = i18n.later("Show images"), group = i18n.later("Filter"), icon = lucide.IMAGE},
	.Filter_Files    = {label = i18n.later("Show files"), group = i18n.later("Filter"), icon = lucide.FILES},
	.Filter_Pinned   = {label = i18n.later("Show pinned entries"), group = i18n.later("Filter"), icon = lucide.PIN},
	.Filter_Next     = {label = i18n.later("Next filter"), group = i18n.later("Filter"), keys = {{.Tab, {}}}, icon = lucide.FILTER},
	.Filter_Previous = {label = i18n.later("Previous filter"), group = i18n.later("Filter"), keys = {{.Tab, {.Shift}}}, icon = lucide.FILTER},
	.Clear_History   = {label = i18n.later("Clear the history (pinned entries stay)"), group = i18n.later("Papier"), icon = lucide.TRASH_2, tags = {"wipe", "erase", "empty"}},
	.Settings        = {label = i18n.later("Settings"), group = i18n.later("Papier"), keys = {{.Comma, {.Ctrl}}}, icon = lucide.SETTINGS, tags = {"preferences", "options", "configure"}},
	.Check_Updates   = {label = i18n.later("Check for updates"), group = i18n.later("Papier"), icon = lucide.REFRESH_CW, tags = {"upgrade", "version", "new"}},
	.Palette         = {label = i18n.later("Command palette"), group = i18n.later("Papier"), keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}, icon = lucide.COMMAND},
	.Shortcuts       = {label = i18n.later("Keyboard shortcuts"), group = i18n.later("Papier"), keys = {{.F1, {}}}, icon = lucide.KEYBOARD, tags = {"help", "keys", "hotkeys"}},
	.Hide            = {label = i18n.later("Hide the window"), group = i18n.later("Papier"), icon = lucide.X, tags = {"close", "dismiss"}},
	.Restart         = {label = i18n.later("Restart Papier"), group = i18n.later("Papier"), icon = lucide.ROTATE_CCW, tags = {"reload", "relaunch"}},
	.Quit            = {label = i18n.later("Quit Papier"), group = i18n.later("Papier"), keys = {{.Q, {.Ctrl}}}, icon = lucide.POWER, tags = {"exit", "close", "stop"}},
}

// The entries an action acts on: the marked ones in the list's order, else the selected one (temp memory). Run when an
// action runs, not at each build: it goes over the marks.
acted_on :: proc(app: ^App) -> []^history.Entry {
	out := make([dynamic]^history.Entry, context.temp_allocator)
	if ui.list_mark_count(&app.vl) > 0 {
		at := make([dynamic]int, context.temp_allocator)
		for id in app.vl.marks { if i, ok := app.list.at[id]; ok { append(&at, i) } }
		slice.sort(at[:])   // (the list's order is its entries' order)
		for i in at { append(&out, &app.list.entries[i]) }
	} else if e := selected(app); e != nil {
		append(&out, e)
	}
	return out[:]
}

// How many entries an action acts on, and the one when it is one: what action_enabled needs, at each build, without a
// pass over the marks.
@(private = "file")
acted_count :: proc(app: ^App) -> (n: int, one: ^history.Entry) {
	switch ui.list_mark_count(&app.vl) {
	case 0:
		one = selected(app)
		return one != nil ? 1 : 0, one
	case 1:
		for id in app.vl.marks { one = list_entry(app, id) }
		return one != nil ? 1 : 0, one
	}
	return ui.list_mark_count(&app.vl), nil
}

// Whether `a` can act now.
action_enabled :: proc(app: ^App, a: Action) -> bool {
	n, one := acted_count(app)
	switch a {
	// (several: their texts joined by the reader; none of them a text says so then)
	case .Copy:          return n >= 1
	case .Copy_Plain:    return one != nil && one.kind == .Html && history.rep_find(one^, TEXT_MIME) >= 0
	case .Edit:          return one != nil && (one.kind == .Text || one.kind == .Html)
	case .Open:          return one != nil
	case .Save_As:       return one != nil && one.kind != .Files
	case .Pin:           return PINS && n > 0
	case .Remove:        return n > 0
	case .Show_QR:       return one != nil && qr_text(app, one) != ""
	case .Copy_Qr_Content: return one != nil && image_qr(app, one) != ""
	case .Toggle_Markdown_Source: return one != nil && loaded_for(app, one) && app.loaded.form == .Markdown
	// (one reading at a time: a second ask while one runs is not taken)
	case .Copy_Image_Text: return one != nil && one.kind == .Image && image_rep(one) >= 0 && ocr_offered(app) && app.ocr_reading == 0
	case .Mark_All:      return len(app.shown) > 0
	case .Clear_Marks:   return ui.list_mark_count(&app.vl) > 0
	case .Filter_Pinned: return PINS
	case .Clear_History: return len(app.list.entries) > 0
	case .Filter_All, .Filter_Text, .Filter_Images, .Filter_Files, .Filter_Next, .Filter_Previous,
	     .Settings, .Check_Updates, .Palette, .Shortcuts, .Hide, .Restart, .Quit:
		return true
	}
	return false
}

action_run :: proc(app: ^App, a: Action) {
	if !action_enabled(app, a) { return }
	on := acted_on(app)
	switch a {
	case .Copy:
		if len(on) == 1 { entry_copy(app, on[0].id); break }
		if len(on) == 0 { break }
		// (several: their texts as one new entry, a line between two; the reader reads them, app_job_done copies them)
		ids := make([]u64, len(on), context.temp_allocator)
		for e, i in on { ids[i] = e.id }
		reader_job(&app.reader, {kind = .Join, ids = ids})
		ui.list_marks_clear(&app.vl)
	case .Copy_Plain: entry_copy(app, on[0].id, plain = true)
	case .Edit:       edit_begin(app, on[0])
	case .Open:       entry_open(app, on[0])
	case .Save_As:    entry_save_as(app, on[0])
	case .Pin:
		// (one pin for all: pinned if one of them is not)
		pin := false
		for e in on { if !e.pinned { pin = true } }
		for e in on { if e.pinned != pin { toggle_pin(app, e) } }
	case .Remove:
		ids := make([]u64, len(on), context.temp_allocator)
		for e, i in on { ids[i] = e.id }
		for id in ids { remove_entry(app, id) }
		ui.list_marks_clear(&app.vl)
		if len(ids) > 1 { announce(app, i18n.tr(len(ids), "Removed %d entry", "Removed %d entries"), len(ids)) }
	case .Show_QR:       qr_open(app, on[0])
	case .Toggle_Markdown_Source: app.markdown_source = !app.markdown_source
	case .Copy_Qr_Content: copy_new_text(app, image_qr(app, on[0]), i18n.tr("Copied the QR code's content"), chosen = false)
	case .Copy_Image_Text:
		e := on[0]
		at := image_rep(e)
		slow_ocr(&app.slow, e.id, app.list.dir, e.reps[at].hash, e.reps[at].mime)
		app.ocr_reading = e.id   // (app_ocr_follow ends it)
	case .Mark_All:      ui.list_mark_all(&app.vl)
	case .Clear_Marks:   ui.list_marks_clear(&app.vl)
	case .Filter_All:    set_filter(app, .All)
	case .Filter_Text:   set_filter(app, .Text)
	case .Filter_Images: set_filter(app, .Images)
	case .Filter_Files:  set_filter(app, .Files)
	case .Filter_Pinned: set_filter(app, .Pinned)
	case .Filter_Next:     set_filter(app, Filter((int(app.filter) + 1) % FILTER_COUNT))
	case .Filter_Previous: set_filter(app, Filter((int(app.filter) + FILTER_COUNT - 1) % FILTER_COUNT))
	case .Clear_History: watcher_send(&app.watcher, {verb = .Clear})
	case .Settings:      settings_toggle(app)
	case .Check_Updates: update_check_asked(app)
	case .Palette:       ui.palette_open(&app.palette)
	case .Shortcuts:     app.sheet.open = true
	case .Hide:          app_hide(app)
	case .Restart:       app_restart(app, hidden = false)
	case .Quit:          app.quit = true
	}
}

// The keys of the actions, when nothing else has the keyboard.
actions_keys :: proc(app: ^App) {
	for a in Action {
		if ui.command_pressed(ACTIONS[a], !action_enabled(app, a)) { action_run(app, a); return }
	}
}

// The palette's table: the actions, then every setting (one chosen opens the settings on it alone). Made when the
// preferences or the language change, not at each frame: the settings' titles are translated when it is made.
Palette_Table :: struct {
	arena:    virtual.Arena,
	commands: []ui.Command,
	names:    []string,      // the setting each command after the actions names
	prefs:    u64,           // the preferences' version it was made for (0: not made)
	language: u32,           // i18n.version() it was made in: a change of language makes it again
	version:  u64,           // bumped at each making (Palette_Options.version)
}

palette_table_destroy :: proc(t: ^Palette_Table) {
	virtual.arena_destroy(&t.arena)
	t^ = {}
}

@(private = "file")
palette_table_keep :: proc(app: ^App) {
	t := &app.palette_table
	if t.prefs == app.prefs.version + 1 && t.language == i18n.version() { return }
	virtual.arena_free_all(&t.arena)
	a := virtual.arena_allocator(&t.arena)
	settings, names := prefs_page.palette_commands(&app.prefs, settings_options(app), a)
	t.commands = slice.concatenate([][]ui.Command{slice.enumerated_array(&ACTIONS), settings}, a)
	t.names = names
	t.prefs, t.language = app.prefs.version + 1, i18n.version()
	t.version += 1
}

// The palette and the sheet of the keys, when they are open (at the end of the window's build).
actions_build :: proc(app: ^App) {
	if app.palette.open {
		palette_table_keep(app)
		t := &app.palette_table
		disabled := make([]bool, len(t.commands), context.temp_allocator)
		for a in Action { disabled[int(a)] = !action_enabled(app, a) }
		if i, _ := ui.palette(&app.palette, t.commands, disabled, {version = t.version}); i >= 0 {
			if i < len(Action) { action_run(app, Action(i)) } else { settings_show(app, t.names[i - len(Action)]) }
		}
	}
	ui.shortcuts_sheet(&app.sheet, "keys", slice.enumerated_array(&ACTIONS), i18n.tr("Papier's keys"))
}

// A tooltip: the action's label and its key.
action_tip :: proc(a: Action) -> string { return ui.command_tip(ACTIONS[a]) }

