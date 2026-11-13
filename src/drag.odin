package papier

// An entry dragged out of the list into another program: a press on a row, then a move past the system's threshold,
// starts a drag of the system with what the entry is: its text (and its markup for rich text), an image as its PNG and as
// a file of its own, copied files as their paths. The reader makes that data (it reads the bytes, writes the file); the
// drag blocks while the user drags (the system runs its loop): it runs between two frames (app_run's loop), never
// inside a build.
//
// Its states: idle (asked = 0); asked (the reader makes the data); ready (has_ready: the data came); running (in
// drag_start). Asked or ready goes back to idle when the press on the row ends first; ready runs at the next turn of the
// loop, then idle.

import "gt:platform"
import i18n "gt:i18n"
import "gt:ui"
import "history"

Drag_Out :: struct {
	asked:     u64,                  // the entry whose drag the reader prepares (0: none)
	held:      bool,                 // the last list built saw the press on that entry still held
	ready:     platform.Drag_Data,   // its data, while has_ready (the reader's heap)
	has_ready: bool,
}

// At the start of the list's build: the press is looked for again in the rows.
drag_build_begin :: proc(app: ^App) {
	app.drag.held = false
}

// In a row's build: a press on it that moved far enough asks for its drag.
drag_watch :: proc(app: ^App, row: ui.Signal, e: ^history.Entry) {
	if !row.dragging { return }
	if app.drag.asked == e.id { app.drag.held = true; return }
	if app.drag.asked != 0 { return }
	limit := platform.drag_threshold(app.main.win)
	d := row.drag_delta * ui.scale()
	if abs(d.x) > limit.x || abs(d.y) > limit.y {
		app.drag.asked, app.drag.held = e.id, true
		reader_job(&app.reader, {kind = .Drag, id = e.id})
	}
}

// The reader's data for a drag: kept when it is the one asked, else let go.
drag_arrived :: proc(app: ^App, done: ^Job_Done) {
	if done.id != app.drag.asked || app.drag.has_ready { return }
	app.drag.ready, app.drag.has_ready = done.drag, true
	done.drag = {}
}

// Between two frames: the drag asked for, once its data came.
drag_run :: proc(app: ^App) {
	d := &app.drag
	if d.asked == 0 { return }
	// (the press ended, or went to another row, before the data came: no drag)
	if !d.held { drag_reset(app); return }
	if !d.has_ready { return }
	data := d.ready
	d.ready, d.has_ready, d.asked = {}, false, 0
	defer drag_data_free(&data)
	if platform.drag_data_empty(data) { return }
	if _, ok := platform.drag_start(app.main.win, data, {.Copy}); !ok { say(app, i18n.tr("The entry cannot be dragged here")) }
	app.main.settle = max(app.main.settle, FRAMES_AFTER_INPUT)
}

drag_reset :: proc(app: ^App) {
	if app.drag.has_ready { drag_data_free(&app.drag.ready) }
	app.drag = {}
}
