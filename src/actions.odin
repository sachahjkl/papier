package papier

// What the user can do in the window, named once: each action's label, group, keys and icon (gui_toolkit's commands). The
// same table gives the keys, the entry menu's shortcuts, the tooltips, the command palette (Ctrl+K) and the sheet of the
// keys (F1). The moves of the selection (the arrows, Page Up/Down, Ctrl+Home/End, Alt+1…9) and Escape stay in view_keys:
// they are the list's, not commands.
//
// An action on entries acts on the marked rows (a Ctrl or Shift click, Ctrl+Shift+A), or on the selected one when none is
// marked.

import "core:slice"
import "core:strings"
import prefs_page "gt:prefs_page"
import "gt:ui"
import lucide "gt:lucide"
import "history"

Action :: enum u8 {
	Copy, Copy_Plain, Edit, Open, Save_As, Pin, Remove, Show_QR,
	Mark_All, Clear_Marks,
	Filter_All, Filter_Text, Filter_Images, Filter_Files, Filter_Pinned, Filter_Next, Filter_Previous,
	Clear_History, Settings, Check_Updates, Setup, Palette, Shortcuts, Hide, Restart, Quit,
}

ACTIONS := [Action]ui.Command{
	.Copy            = {label = "Copy", group = "Entry", keys = {{.Return, {}}, {}}, icon = lucide.COPY, tags = {"paste", "clipboard"}},
	.Copy_Plain      = {label = "Copy as plain text", group = "Entry", icon = lucide.TYPE, tags = {"text", "unformatted"}},
	.Edit            = {label = "Edit…", group = "Entry", keys = {{.E, {.Ctrl}}, {}}, icon = lucide.EDIT, tags = {"change", "modify"}},
	.Open            = {label = "Open", group = "Entry", keys = {{.O, {.Ctrl}}, {}}, icon = lucide.EXTERNAL_LINK, tags = {"launch", "browser"}},
	.Save_As         = {label = "Save as…", group = "Entry", keys = {{.S, {.Ctrl}}, {}}, icon = lucide.SAVE, tags = {"export", "file", "write"}},
	.Pin             = {label = "Pin or unpin", group = "Entry", keys = {{.P, {.Ctrl}}, {}}, icon = lucide.PIN, tags = {"favourite", "keep", "star"}},
	.Remove          = {label = "Remove", group = "Entry", keys = {{.Delete, {.Shift}}, {}}, icon = lucide.TRASH_2, tags = {"delete", "erase", "forget"}},
	.Show_QR         = {label = "Show as a QR code", group = "Entry", keys = {{.Q, {.Ctrl, .Shift}}, {}}, icon = lucide.QR_CODE, tags = {"phone", "scan", "share"}},
	.Mark_All        = {label = "Mark every entry shown", group = "Selection", keys = {{.A, {.Ctrl, .Shift}}, {}}, icon = lucide.LIST_CHECKS, tags = {"select all", "selection"}},
	.Clear_Marks     = {label = "Clear the marks", group = "Selection", icon = lucide.X},
	.Filter_All      = {label = "Show every entry", group = "Filter", icon = lucide.LIST},
	.Filter_Text     = {label = "Show text", group = "Filter", icon = lucide.ALIGN_LEFT},
	.Filter_Images   = {label = "Show images", group = "Filter", icon = lucide.IMAGE},
	.Filter_Files    = {label = "Show files", group = "Filter", icon = lucide.FILES},
	.Filter_Pinned   = {label = "Show pinned entries", group = "Filter", icon = lucide.PIN},
	.Filter_Next     = {label = "Next filter", group = "Filter", keys = {{.Tab, {}}, {}}, icon = lucide.FILTER},
	.Filter_Previous = {label = "Previous filter", group = "Filter", keys = {{.Tab, {.Shift}}, {}}, icon = lucide.FILTER},
	.Clear_History   = {label = "Clear the history (pinned entries stay)", group = "Papier", icon = lucide.TRASH_2, tags = {"wipe", "erase", "empty"}},
	.Settings        = {label = "Settings", group = "Papier", keys = {{.Comma, {.Ctrl}}, {}}, icon = lucide.SETTINGS, tags = {"preferences", "options", "configure"}},
	.Check_Updates   = {label = "Check for updates", group = "Papier", icon = lucide.REFRESH_CW, tags = {"upgrade", "version", "new"}},
	.Setup           = {label = "Setup…", group = "Papier", icon = lucide.PACKAGE, tags = {"install", "uninstall", "start menu"}},
	.Palette         = {label = "Command palette", group = "Papier", keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}, icon = lucide.COMMAND},
	.Shortcuts       = {label = "Keyboard shortcuts", group = "Papier", keys = {{.F1, {}}, {}}, icon = lucide.KEYBOARD, tags = {"help", "keys", "hotkeys"}},
	.Hide            = {label = "Hide the window", group = "Papier", icon = lucide.X, tags = {"close", "dismiss"}},
	.Restart         = {label = "Restart Papier", group = "Papier", icon = lucide.ROTATE_CCW, tags = {"reload", "relaunch"}},
	.Quit            = {label = "Quit Papier", group = "Papier", keys = {{.Q, {.Ctrl}}, {}}, icon = lucide.POWER, tags = {"exit", "close", "stop"}},
}

// The entries an action acts on: the marked ones in the list's order, else the selected one (temp memory).
acted_on :: proc(app: ^App) -> []^history.Entry {
	out := make([dynamic]^history.Entry, context.temp_allocator)
	if ui.list_mark_count(&app.vl) > 0 {
		for i in 0 ..< len(app.shown) {
			if ui.list_is_marked(&app.vl, i) { append(&out, &app.store.entries[app.shown[i]]) }
		}
	} else if e := selected(app); e != nil {
		append(&out, e)
	}
	return out[:]
}

// Whether `a` can act now.
action_enabled :: proc(app: ^App, a: Action) -> bool {
	on := acted_on(app)
	one := len(on) == 1 ? on[0] : nil
	switch a {
	case .Copy:          return len(on) == 1 || (len(on) > 1 && marked_text(app, on) != "")
	case .Copy_Plain:    return one != nil && one.kind == .Html && history.rep_find(one^, TEXT_MIME) >= 0
	case .Edit:          return one != nil && (one.kind == .Text || one.kind == .Html)
	case .Open:          return one != nil
	case .Save_As:       return one != nil && one.kind != .Files
	case .Pin:           return PINS && len(on) > 0
	case .Remove:        return len(on) > 0
	case .Show_QR:       return one != nil && qr_text(app, one) != ""
	case .Mark_All:      return len(app.shown) > 0
	case .Clear_Marks:   return ui.list_mark_count(&app.vl) > 0
	case .Filter_Pinned: return PINS
	case .Clear_History: return len(app.store.entries) > 0
	case .Filter_All, .Filter_Text, .Filter_Images, .Filter_Files, .Filter_Next, .Filter_Previous,
	     .Settings, .Check_Updates, .Setup, .Palette, .Shortcuts, .Hide, .Restart, .Quit:
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
		// (several: their texts as one new entry, a line between two)
		watcher_send(&app.watcher, {verb = .Add_Text, text = marked_text(app, on), paste = app.settings.paste_on_select})
		ui.list_marks_clear(&app.vl)
		if app.settings.close_on_copy || app.settings.paste_on_select { app_hide(app) } else { say(app, "Copied %d entries", len(on)) }
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
		if len(ids) > 1 { say(app, "Removed %d entries", len(ids)) }
	case .Show_QR:       qr_open(app, on[0])
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
	case .Setup:         setup_open(app)
	case .Palette:       ui.palette_open(&app.palette)
	case .Shortcuts:     app.sheet_open = true
	case .Hide:          app_hide(app)
	case .Restart:       app_restart(app, hidden = false)
	case .Quit:          app.quit = true
	}
}

// The keys of the actions, when nothing else has the keyboard.
actions_keys :: proc(app: ^App) {
	for a in Action {
		if ui.command_pressed(ACTIONS[a], action_enabled(app, a)) { action_run(app, a); return }
	}
}

// The palette and the sheet of the keys, when they are open (at the end of the window's build). The palette holds the
// actions, then every setting: one chosen opens the settings on it alone.
actions_build :: proc(app: ^App) {
	actions := slice.enumerated_array(&ACTIONS)
	if app.palette.open {
		settings, names := prefs_page.palette_commands(&app.prefs, settings_options(app))
		all := slice.concatenate([][]ui.Command{actions, settings}, context.temp_allocator)
		enabled := make([]bool, len(all), context.temp_allocator)
		for a in Action { enabled[int(a)] = action_enabled(app, a) }
		for i in len(actions) ..< len(all) { enabled[i] = true }
		if i, _ := ui.palette(&app.palette, all, enabled); i >= 0 {
			if i < len(actions) { action_run(app, Action(i)) } else { settings_show(app, names[i - len(actions)]) }
		}
	}
	ui.shortcuts_sheet("keys", actions, &app.sheet_open, "Papier's keys")
}

// A tooltip: the action's label and its key.
action_tip :: proc(a: Action) -> string { return ui.command_tip(ACTIONS[a]) }

// The texts of several entries, a line between two (the ones without text left out).
@(private = "file")
marked_text :: proc(app: ^App, on: []^history.Entry) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for e in on {
		if e.kind != .Text && e.kind != .Html { continue }
		if t := entry_text(app, e); t != "" { append(&parts, t) }
	}
	return strings.join(parts[:], "\n", context.temp_allocator)
}

