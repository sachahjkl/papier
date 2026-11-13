package papier

// papier's licence (gt:licence, gui_toolkit docs/licence.md): a signed key, checked on this computer with no network. A
// licence changes nothing of what papier does: it says who supports it. The settings' General page shows it under its
// preferences: whose it is, or a way to buy one, a key to paste, a file to choose, Remove.
//
// The states: unknown until the store's first read comes (read false); then the status read last. Each change
// (a key, a file, Remove) is one task at a time (busy): it writes, reads the status again, and its answer comes
// at a next build. The store's file is touched only in those tasks, never on the window's thread.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import i18n "gt:i18n"
import licence "gt:licence"
import "gt:platform"
import "gt:ui"
import papier_licence "licence"

// Where a licence is bought: the site's pricing page.
PRICING_URL :: "https://papier.froment.software/pricing/"

// What the window keeps of the licence.
Licence_View :: struct {
	store:   licence.Store,
	status:  licence.Status,   // the last read (heap allocator)
	read:    bool,             // a status has come
	busy:    bool,             // a task on the store is on its way
	key:     ui.Text_Field,    // the key being pasted
	problem: string,           // why the last install failed (owned; "": none)
}

@(private = "file")
Licence_Do :: enum u8 { Read, Install, Install_File, Remove }

@(private = "file")
Licence_Job :: struct {
	app:    ^App,
	act:    Licence_Do,
	text:   string,            // the key, or the file (heap)
	err:    licence.Error,
	status: licence.Status,    // read after the change (heap)
}

licence_init :: proc(app: ^App) {
	// (a debug build accepts the development pair: the tests and the pictures register with it)
	licence.store_init(&app.licence.store, {product = papier_licence.PRODUCT, program = APP_NAME, accept_dev = ODIN_DEBUG})
	licence_run(app, .Read, "")
}

// After the chores have stopped: no task holds the store any more.
licence_destroy :: proc(app: ^App) {
	l := &app.licence
	licence.status_destroy(&l.status, runtime.heap_allocator())
	licence.store_destroy(&l.store)
	ui.field_wipe(&l.key)
	ui.field_destroy(&l.key)
	delete(l.problem)
	l^ = {}
}

@(private = "file")
licence_run :: proc(app: ^App, act: Licence_Do, text: string) {
	a := runtime.heap_allocator()
	j := new(Licence_Job, a)
	j^ = {app = app, act = act, text = strings.clone(text, a)}
	app.licence.busy = true
	work :: proc(d: rawptr) {
		j := (^Licence_Job)(d)
		s := &j.app.licence.store
		switch j.act {
		case .Read:
		case .Install:      j.err = licence.store_install(s, j.text)
		case .Install_File: j.err = licence.store_install_file(s, j.text)
		case .Remove:       if !licence.store_remove(s) { j.err = .Not_Written }
		}
		j.status = licence.store_read(s, runtime.heap_allocator())
	}
	done :: proc(d: rawptr, _: u64) {
		j := (^Licence_Job)(d)
		app := j.app
		l := &app.licence
		licence.status_destroy(&l.status, runtime.heap_allocator())
		l.status, j.status = j.status, {}
		l.read, l.busy = true, false
		delete(l.problem)
		l.problem = ""
		if j.err != .None {
			l.problem = strings.clone(licence_error_words(j.err))
		} else {
			#partial switch j.act {
			case .Install, .Install_File:
				ui.field_wipe(&l.key)
				announce(app, i18n.tr("Licence registered: thank you"))
			case .Remove:
				announce(app, i18n.tr("Licence removed"))
			}
		}
		licence_job_free(d)
	}
	ui.task(&app.main.state, work, done, j, licence_job_free)
}

@(private = "file")
licence_job_free :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	j := (^Licence_Job)(d)
	licence.status_destroy(&j.status, a)
	delete(j.text, a)
	free(j, a)
}

// What went wrong, in papier's words.
@(private = "file")
licence_error_words :: proc(e: licence.Error) -> string {
	#partial switch e {
	case .Wrong_Product: return i18n.tr("This licence is not papier's.")
	case .Bad_Signature: return i18n.tr("This key is not a valid licence of papier: check that it was copied whole.")
	case .No_Public_Key: return i18n.tr("This build of papier accepts no licence yet.")
	case .Not_Read:      return i18n.tr("The licence file cannot be read.")
	case .Not_Written:   return i18n.tr("The licence cannot be saved.")
	}
	return licence.error_text(e)
}

// The Licence section, under the General page's preferences (prefs_page Options.page_foot).
licence_section :: proc(app: ^App, em: f32) {
	l := &app.licence
	ui.spacer(ui.px(em * 1.2))
	ui.next({width = ui.fill(), height = ui.px(em * 1.6), font_size = math.round(em * 1.02), text_pad = 0})
	ui.label(fmt.tprintf("%s###licence_title", i18n.tr("Licence")))
	ui.spacer(ui.px(em * 0.3))
	switch {
	case !l.read:
		if ui.tags("weak") {
			ui.next({width = ui.fill(), text_pad = 0})
			ui.paragraph(fmt.tprintf("%s###licence_state", i18n.tr("Reading the licence…")))
		}
	case l.status.registered:
		lic := l.status.licence
		ui.next({width = ui.fill(), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###licence_state", fmt.tprintf(i18n.tr("Registered to %s (%s). Thank you for supporting papier."), lic.name, licence.edition_title(papier_licence.PRODUCT, lic.edition))))
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.text_size(em * 0.6), height = ui.px(math.round(em * 1.9))})
		if ui.button(fmt.tprintf("%s###licence_remove", i18n.tr("Remove the licence")), intent = .Danger, face = .Ghost, disabled = l.busy).clicked {
			licence_run(app, .Remove, "")
		}
	case:
		ui.next({width = ui.fill(), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###licence_state", i18n.tr("Unregistered. Papier is free; a licence supports its work.")))
		if l.status.stored {
			// (a key is there, but it does not check out: said, not hidden)
			if ui.tags("bad") {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###licence_stored", fmt.tprintf(i18n.tr("The licence stored here is not valid: %s"), licence_error_words(l.status.err))))
			}
		}
		ui.spacer(ui.px(em * 0.3))
		if ui.hint_action("###licence_buy", i18n.tr("Support papier: buy a licence"), intent = .Primary).clicked { ui.open(PRICING_URL, .Url) }
		ui.spacer(ui.px(em * 0.6))
		h := ui.px(math.round(em * 1.9))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(id = "###licence_row") {
			ui.next({width = ui.fill(), height = h})
			res := ui.line_edit("###licence_key", &l.key, i18n.tr("Paste a licence key"))
			key := strings.trim_space(ui.field_string(&l.key))
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(em * 0.6), height = h})
			register := ui.button(fmt.tprintf("%s###licence_register", i18n.tr("Register")), intent = .Primary, disabled = l.busy || key == "")
			if (register.clicked || res.committed) && key != "" && !l.busy { licence_run(app, .Install, key) }
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(em * 0.6), height = h})
			if ui.button(fmt.tprintf("%s###licence_file", i18n.tr("Choose a file…")), disabled = l.busy).clicked { licence_choose_file(app) }
		}
	}
	if l.problem != "" {
		ui.spacer(ui.px(em * 0.3))
		if ui.tags("bad") {
			ui.next({width = ui.fill(), text_pad = 0})
			ui.paragraph(fmt.tprintf("%s###licence_problem", l.problem))
		}
	}
}

// The system's Open dialog, then the file installed: both off the window's thread.
@(private = "file")
licence_choose_file :: proc(app: ^App) {
	d := licence.file_dialog(papier_licence.PRODUCT, i18n.tr("Choose a licence file"), i18n.tr("Papier licence"))
	d.owner = app.main.win
	ui.file_dialog(&app.main.state, .Open, d, proc(r: platform.Dialog_Result, user: rawptr) {
		if r.status != .Chosen || len(r.paths) == 0 { return }
		app := (^App)(user)
		// (licence_run copies the path: the result's are freed after this call)
		licence_run(app, .Install_File, r.paths[0])
	}, app)
}
