package papier

// An entry dragged out of the list into another program: a press on a row, then a move past the system's threshold,
// starts a drag of the system with what the entry is: its text (and its markup for rich text), an image as its PNG and as
// a file of its own, copied files as their paths. The drag blocks while the user drags (the system runs its loop): it runs
// between two frames (app_run's loop), never inside a build.

import "core:strings"
import "gt:platform"
import "gt:ui"
import "history"

// In a row's build: a press on it that moved far enough asks for its drag.
drag_watch :: proc(app: ^App, row: ui.Signal, e: ^history.Entry) {
	if !row.dragging || app.drag_out != 0 { return }
	limit := platform.drag_threshold(app.main.win)
	d := row.drag_delta * ui.scale()
	if abs(d.x) > limit.x || abs(d.y) > limit.y { app.drag_out = e.id }
}

// Between two frames: the drag asked for, if any.
drag_run :: proc(app: ^App) {
	id := app.drag_out
	app.drag_out = 0
	if id == 0 { return }
	at := history.find(&app.store, id)
	if at < 0 { return }
	e := &app.store.entries[at]
	data: platform.Drag_Data
	defer platform.drag_data_destroy(&data)
	switch e.kind {
	case .Text:
		data.text = strings.clone(entry_text(app, e))
	case .Html:
		data.text = strings.clone(entry_text(app, e))
		if h := history.rep_find(e^, HTML_MIME); h >= 0 {
			data.html = strings.clone(string(history.blob_read(&app.store, e.reps[h].hash, context.temp_allocator)))
		}
	case .Image:
		// (a file for those that take files, the picture's bytes for those that take pixels)
		if path, ok := entry_file(app, e); ok { append(&data.files, strings.clone(path)) }
		if p := history.rep_find(e^, "image/png"); p >= 0 {
			data.image = history.blob_read(&app.store, e.reps[p].hash)
		}
	case .Files:
		for line in strings.split_lines(e.preview, context.temp_allocator) {
			if line != "" { append(&data.files, strings.clone(line)) }
		}
	case .Other:
		if path, ok := entry_file(app, e); ok { append(&data.files, strings.clone(path)) }
	}
	if platform.drag_data_empty(data) { return }
	if _, ok := platform.drag_start(app.main.win, data, {.Copy}); !ok { say(app, "The entry cannot be dragged here") }
	app.main.settle = max(app.main.settle, FRAMES_AFTER_INPUT)
}
