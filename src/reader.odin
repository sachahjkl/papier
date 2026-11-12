package papier

// The reader: a thread of its own that does every read and write of the window, so that the window's thread never waits
// on the disk, a database or a program (docs/architecture.md). It owns the window's connection to the history (the
// watcher writes it, the reader reads it) and keeps the list, each preview in lower case for the search.
//
// The window asks, and never waits:
//
//   reader_reload   the list again (the watcher changed it): a new History_List, and the view of the last query on it
//   reader_query    the entries the search and the filter keep (the newest query wins)
//   reader_forget   an entry the user removed: out of the list at once, the view again without it
//   reader_pin      an entry pinned or unpinned: the same in the reader's list, until the watcher's reload says it
//   reader_load     the selected entry's text, its code's language, its QR text (the newest ask wins)
//   reader_job      a file to write, a program to start, a drag's data, the preferences: in order, each with its result
//
// What comes back waits in a mailbox that the window empties once per turn of its loop (reader_take); the reader wakes
// the window when it puts something there. A list and its view are put there together: the window never shows a view
// of one list with another.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"
import config "gt:config"
import desktop "gt:desktop"
import "gt:fsx"
import "gt:platform"
import syntax "gt:syntax"
import "history"

// The history as the window shows it: a copy of the reader's list (heap; history_list_free).
History_List :: struct {
	entries: [dynamic]history.Entry,   // newest first
	at:      map[u64]int,              // an entry's index in `entries`, by its id
	pinned:  int,                      // how many entries are pinned
	dir:     string,                   // the store's directory (the decoder reads the pictures there)
	version: u64,                      // the watcher's version it was read at
	serial:  u64,                      // the reader's list it copies: moves at each reload and each forget
}

// The entries a query keeps, in the list's order (heap; history_view_free).
History_View :: struct {
	seq:      u64,            // the query's (the window applies the newest only)
	serial:   u64,            // the list it was computed on
	reset:    bool,           // a new look: the first row selected, the list at its top
	shown:    [dynamic]int,   // indices in the list's entries
	ids:      [dynamic]u64,   // their ids
	keep_id:  u64,            // the entry selected when it was computed
	keep_row: int,            // its row in `ids` (-1: not shown)
}

// The selected entry, read in full (heap; loaded_free).
Loaded_Entry :: struct {
	id, key:   u64,
	view_text: string,            // what the preview shows (VIEW_TEXT_MAX_BYTES at most)
	code:      syntax.Language,   // the language of a text (has_code: syntax.guess found one)
	has_code:  bool,
	text:      string,            // the whole text (what the edit view and the drag take)
	qr:        string,            // what its QR code holds ("" none: no text, or too long)
	ok:        bool,              // the entry was there, with this key
}

Job_Kind :: enum u8 {
	Save_As,       // id, path: the entry's bytes into the file the user chose
	Open,          // id: an address in the browser, else the entry as a file, with its program
	Open_With,     // id, handler: the entry as a file, with that program
	Reveal,        // path: a copied file in the file manager
	Handlers,      // id, path: the programs that open a file of that name ("Open with")
	Drag,          // id: what a drag of the entry carries
	Join,          // ids: the texts of several entries as one
	Write,         // path, data: a file of the window (its state)
	Write_Prefs,   // path, text: the preferences file
	Read_Prefs,    // the preferences file, read again
}

// A job for the reader (heap; the reader frees it).
Job :: struct {
	kind:    Job_Kind,
	id:      u64,
	ids:     []u64,
	path:    string,
	handler: string,
	text:    string,
	data:    []u8,
}

// A job done (heap; job_done_free).
Job_Done :: struct {
	kind:     Job_Kind,
	id:       u64,
	ok:       bool,
	message:  string,               // for the status bar ("" none)
	text:     string,               // Join
	drag:     platform.Drag_Data,   // Drag
	handlers: []desktop.Handler,    // Handlers
	prefs:    config.Prefs,         // Read_Prefs (ok: read)
}

// What the window takes from the mailbox at a turn of its loop. The caller owns each part (reader_results_free).
Reader_Results :: struct {
	failure:    string,   // the history cannot be opened: why ("" it can)
	failed:     bool,
	list:       History_List,
	has_list:   bool,
	view:       History_View,
	has_view:   bool,
	loaded:     Loaded_Entry,
	has_loaded: bool,
	done:       []Job_Done,   // in the order they were asked (temp slice)
}

Reader :: struct {
	thread: ^thread.Thread,
	window: ^platform.Window,   // woken when the mailbox has something (nil: a test reads it itself)
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	stop:   bool,
	dir:    string,             // the store's directory (heap)

	// asked (guarded by `mutex`)
	reload_asked:   bool,
	reload_version: u64,
	query_asked:    bool,
	query:          Reader_Query,
	forgets:        [dynamic]Reader_Forget,
	pins:           [dynamic]Reader_Pin,
	load_asked:     bool,
	load:           [2]u64,          // id, key
	selected:       u64,             // the entry the window shows (the last load asked)
	jobs:           [dynamic]Job,

	// the mailbox (guarded by `mutex`)
	failure:    string,
	failed:     bool,
	list:       History_List,
	has_list:   bool,
	view:       History_View,
	has_view:   bool,
	loaded:     Loaded_Entry,
	has_loaded: bool,
	done:       [dynamic]Job_Done,

	// the thread's own
	store:   history.Store,
	opened:  bool,
	lowered: [dynamic]string,   // each entry's preview in lower case (the search's short words)
	current: Reader_Query,      // the last query given (its text owned)
	serial:  u64,
	version: u64,
}

@(private = "file")
Reader_Query :: struct { seq: u64, text: string, filter: Filter, reset: bool }

@(private = "file")
Reader_Forget :: struct { id: u64, seq: u64 }

@(private = "file")
Reader_Pin :: struct { id: u64, pinned: bool }

////////////////////////////////
// The window's side

// Starts the reader on the store of `dir`: it opens it on its own thread and puts the first list in the mailbox (or why
// it cannot be opened).
reader_start :: proc(r: ^Reader, window: ^platform.Window, dir: string) {
	heap := runtime.heap_allocator()
	r.window = window
	r.dir = strings.clone(dir, heap)
	r.forgets = make([dynamic]Reader_Forget, heap)
	r.pins = make([dynamic]Reader_Pin, heap)
	r.jobs = make([dynamic]Job, heap)
	r.done = make([dynamic]Job_Done, heap)
	r.lowered = make([dynamic]string, heap)
	r.thread = thread.create_and_start_with_data(r, reader_run, context)
}

// Stops the reader once the jobs asked are done (a state written at quit lands), and frees what nobody took.
reader_stop :: proc(r: ^Reader) {
	if r.thread == nil { return }
	sync.mutex_lock(&r.mutex)
	r.stop = true
	sync.cond_signal(&r.cond)
	sync.mutex_unlock(&r.mutex)
	thread.join(r.thread)
	thread.destroy(r.thread)
	r.thread = nil
	heap := runtime.heap_allocator()
	delete(r.dir, heap)
	if r.query_asked { delete(r.query.text, heap) }
	delete(r.forgets)
	delete(r.pins)
	for &j in r.jobs { job_free(&j) }
	delete(r.jobs)
	delete(r.failure, heap)
	if r.has_list { history_list_free(&r.list) }
	if r.has_view { history_view_free(&r.view) }
	if r.has_loaded { loaded_free(&r.loaded) }
	for &d in r.done { job_done_free(&d) }
	delete(r.done)
	r^ = {}
}

// Read the list again: the watcher's version moved to `version`.
reader_reload :: proc(r: ^Reader, version: u64) {
	sync.guard(&r.mutex)
	r.reload_asked, r.reload_version = true, version
	sync.cond_signal(&r.cond)
}

// The view of `query` and `filter` on the reader's list, in place of any query not yet computed.
reader_query :: proc(r: ^Reader, seq: u64, query: string, filter: Filter, reset: bool) {
	heap := runtime.heap_allocator()
	sync.guard(&r.mutex)
	// (a reset asked and not yet computed stays asked: the newer query is still a new look)
	keep_reset := r.query_asked && r.query.reset
	if r.query_asked { delete(r.query.text, heap) }
	r.query = {seq, strings.clone(query, heap), filter, reset || keep_reset}
	r.query_asked = true
	sync.cond_signal(&r.cond)
}

// The entry `id` is out of the list (the user removed it; the watcher deletes it): the view comes again as `seq`.
reader_forget :: proc(r: ^Reader, id: u64, seq: u64) {
	sync.guard(&r.mutex)
	append(&r.forgets, Reader_Forget{id, seq})
	sync.cond_signal(&r.cond)
}

// The entry `id` is pinned or unpinned in the reader's list too (a Pinned filter sees it before the watcher's reload).
reader_pin :: proc(r: ^Reader, id: u64, pinned: bool) {
	sync.guard(&r.mutex)
	append(&r.pins, Reader_Pin{id, pinned})
	sync.cond_signal(&r.cond)
}

// The content of entry `id` as it is with `key`, in place of any load not yet started. It is the selected entry: the
// views keep its row.
reader_load :: proc(r: ^Reader, id: u64, key: u64) {
	sync.guard(&r.mutex)
	r.load, r.load_asked, r.selected = {id, key}, true, id
	sync.cond_signal(&r.cond)
}

// A job, after those asked before it. Its strings and slices are copied.
reader_job :: proc(r: ^Reader, j: Job) {
	heap := runtime.heap_allocator()
	own := Job{kind = j.kind, id = j.id}
	if j.ids != nil { own.ids = make([]u64, len(j.ids), heap); copy(own.ids, j.ids) }
	own.path = strings.clone(j.path, heap)
	own.handler = strings.clone(j.handler, heap)
	own.text = strings.clone(j.text, heap)
	if j.data != nil { own.data = make([]u8, len(j.data), heap); copy(own.data, j.data) }
	sync.guard(&r.mutex)
	append(&r.jobs, own)
	sync.cond_signal(&r.cond)
}

// What the mailbox holds, emptied. Never waits.
reader_take :: proc(r: ^Reader) -> (out: Reader_Results) {
	sync.guard(&r.mutex)
	out.failure, out.failed = r.failure, r.failed
	r.failure, r.failed = "", false
	out.list, out.has_list = r.list, r.has_list
	r.list, r.has_list = {}, false
	out.view, out.has_view = r.view, r.has_view
	r.view, r.has_view = {}, false
	out.loaded, out.has_loaded = r.loaded, r.has_loaded
	r.loaded, r.has_loaded = {}, false
	if len(r.done) > 0 {
		out.done = make([]Job_Done, len(r.done), context.temp_allocator)
		copy(out.done, r.done[:])
		clear(&r.done)
	}
	return
}

// What the caller did not keep of a take.
reader_results_free :: proc(res: ^Reader_Results) {
	delete(res.failure, runtime.heap_allocator())
	if res.has_list { history_list_free(&res.list) }
	if res.has_view { history_view_free(&res.view) }
	if res.has_loaded { loaded_free(&res.loaded) }
	for &d in res.done { job_done_free(&d) }
	res^ = {}
}

history_list_free :: proc(l: ^History_List) {
	heap := runtime.heap_allocator()
	for &e in l.entries { history.entry_free(&e, heap) }
	delete(l.entries)
	delete(l.at)
	delete(l.dir, heap)
	l^ = {}
}

history_view_free :: proc(v: ^History_View) {
	delete(v.shown)
	delete(v.ids)
	v^ = {}
}

loaded_free :: proc(l: ^Loaded_Entry) {
	heap := runtime.heap_allocator()
	delete(l.view_text, heap)
	delete(l.text, heap)
	delete(l.qr, heap)
	l^ = {}
}

job_done_free :: proc(d: ^Job_Done) {
	heap := runtime.heap_allocator()
	delete(d.message, heap)
	delete(d.text, heap)
	drag_data_free(&d.drag)
	if d.handlers != nil { desktop.handlers_destroy(d.handlers, heap) }
	if d.ok && d.kind == .Read_Prefs { config.prefs_destroy(&d.prefs) }
	d^ = {}
}

// A drag's data made by the reader (its heap).
drag_data_free :: proc(d: ^platform.Drag_Data) {
	context.allocator = runtime.heap_allocator()
	platform.drag_data_destroy(d)
}

@(private = "file")
job_free :: proc(j: ^Job) {
	heap := runtime.heap_allocator()
	delete(j.ids, heap)
	delete(j.path, heap)
	delete(j.handler, heap)
	delete(j.text, heap)
	delete(j.data, heap)
	j^ = {}
}

////////////////////////////////
// The reader's thread

@(private = "file")
reader_run :: proc(data: rawptr) {
	r := (^Reader)(data)
	context.allocator = runtime.heap_allocator()
	// (Windows: COM on this thread, which the shell's open of a file wants; nothing elsewhere)
	platform.dragdrop_thread_init()
	ok, why := history.open(&r.store, r.dir)
	r.opened = ok
	if ok {
		reader_lower(r)
		r.serial = 1
		sync.mutex_lock(&r.mutex)
		selected := r.selected
		sync.mutex_unlock(&r.mutex)
		reader_publish(r, true, selected)
	} else {
		sync.mutex_lock(&r.mutex)
		r.failure, r.failed = strings.clone(why), true
		sync.mutex_unlock(&r.mutex)
	}
	if r.window != nil { platform.wake(r.window) }

	for {
		sync.mutex_lock(&r.mutex)
		for !reader_has_work(r) && !r.stop { sync.cond_wait(&r.cond, &r.mutex) }
		// (stopping: the jobs still asked are done first; the views and loads nobody will read are not)
		if r.stop && len(r.jobs) == 0 { sync.mutex_unlock(&r.mutex); break }
		stopping := r.stop
		forgets := make([]Reader_Forget, len(r.forgets), context.temp_allocator)
		copy(forgets, r.forgets[:])
		clear(&r.forgets)
		pins := make([]Reader_Pin, len(r.pins), context.temp_allocator)
		copy(pins, r.pins[:])
		clear(&r.pins)
		reload, version := r.reload_asked, r.reload_version
		r.reload_asked = false
		query, has_query := r.query, r.query_asked
		r.query, r.query_asked = {}, false
		load, has_load := r.load, r.load_asked
		r.load_asked = false
		selected := r.selected
		// (one job per turn: a query typed meanwhile is not kept behind a slow program's start)
		job: Job
		has_job := len(r.jobs) > 0
		if has_job {
			job = r.jobs[0]
			ordered_remove(&r.jobs, 0)
		}
		sync.mutex_unlock(&r.mutex)

		woke := false
		if r.opened && !stopping {
			list_changed := false
			for f in forgets {
				if at := history.find(&r.store, f.id); at >= 0 {
					history.forget(&r.store, f.id)
					delete(r.lowered[at])
					ordered_remove(&r.lowered, at)
					list_changed = true
				}
				r.current.seq = max(r.current.seq, f.seq)
			}
			// (the view of a removal is asked even when the entry was gone: the window waits for its seq)
			view_due := len(forgets) > 0
			for p in pins {
				if at := history.find(&r.store, p.id); at >= 0 { r.store.entries[at].pinned = p.pinned }
			}
			if reload {
				history.reload(&r.store)
				reader_lower(r)
				r.version = version
				list_changed = true
			}
			if has_query {
				delete(r.current.text)
				r.current.text, r.current.filter = query.text, query.filter
				r.current.seq = max(r.current.seq, query.seq)
				r.current.reset = r.current.reset || query.reset
				view_due = true
			}
			if list_changed { r.serial += 1 }
			if list_changed || view_due {
				reader_publish(r, list_changed, selected)
				woke = true
			}
			if has_load {
				l := reader_load_entry(r, load[0], load[1])
				sync.mutex_lock(&r.mutex)
				if r.has_loaded { loaded_free(&r.loaded) }
				r.loaded, r.has_loaded = l, true
				sync.mutex_unlock(&r.mutex)
				woke = true
			}
		} else if has_query {
			delete(query.text)
		}
		if has_job {
			d := reader_run_job(r, &job)
			job_free(&job)
			sync.mutex_lock(&r.mutex)
			append(&r.done, d)
			sync.mutex_unlock(&r.mutex)
			woke = true
		}
		if woke && r.window != nil { platform.wake(r.window) }
		free_all(context.temp_allocator)
	}

	for s in r.lowered { delete(s) }
	delete(r.lowered)
	delete(r.current.text)
	if r.opened { history.close(&r.store) }
}

@(private = "file")
reader_has_work :: proc(r: ^Reader) -> bool {
	return r.reload_asked || r.query_asked || r.load_asked || len(r.forgets) > 0 || len(r.pins) > 0 || len(r.jobs) > 0
}

// Each preview in lower case, for the list read again.
@(private = "file")
reader_lower :: proc(r: ^Reader) {
	for s in r.lowered { delete(s) }
	clear(&r.lowered)
	for e in r.store.entries { append(&r.lowered, strings.to_lower(e.preview)) }
}

// The view of the current query in the mailbox, and with `with_list` a copy of the list it was computed on: both in one
// hold of the mutex, so that the window takes them together. They are made before, without it: the window's asks never
// wait on a search. A list or a view not yet taken gives way; a reset the view carried for the same query stays.
@(private = "file")
reader_publish :: proc(r: ^Reader, with_list: bool, selected: u64) {
	heap := runtime.heap_allocator()
	l: History_List
	if with_list {
		l = History_List{version = r.version, serial = r.serial, dir = strings.clone(r.store.dir, heap)}
		l.entries = make([dynamic]history.Entry, 0, len(r.store.entries), heap)
		l.at = make(map[u64]int, len(r.store.entries), heap)
		for e, i in r.store.entries {
			append(&l.entries, history.entry_clone(e, heap))
			l.at[e.id] = i
			if e.pinned { l.pinned += 1 }
		}
	}
	v := reader_view(r, selected)
	r.current.reset = false

	sync.guard(&r.mutex)
	if with_list {
		if r.has_list { history_list_free(&r.list) }
		r.list, r.has_list = l, true
	}
	if r.has_view {
		if r.view.seq == v.seq && r.view.reset { v.reset = true }
		history_view_free(&r.view)
	}
	r.view, r.has_view = v, true
}

// The entries that pass the filter and hold every word of the query, in the list's order: the words long enough for
// the full-text index are looked for in the whole text, the shorter ones in the lowered preview.
@(private = "file")
reader_view :: proc(r: ^Reader, keep: u64) -> History_View {
	heap := runtime.heap_allocator()
	q := r.current
	v := History_View{seq = q.seq, serial = r.serial, reset = q.reset, keep_id = keep, keep_row = -1}
	v.shown = make([dynamic]int, heap)
	v.ids = make([dynamic]u64, heap)
	words := strings.fields(strings.to_lower(q.text, context.temp_allocator), context.temp_allocator)
	found, indexed := history.search(&r.store, words)
	outer: for e, i in r.store.entries {
		if !filter_keeps(q.filter, e) { continue }
		if indexed && e.id not_in found { continue }
		for w in words { if len(w) < history.SEARCH_WORD_MIN && !strings.contains(r.lowered[i], w) { continue outer } }
		if e.id == keep { v.keep_row = len(v.ids) }
		append(&v.shown, i)
		append(&v.ids, e.id)
	}
	return v
}

// Whether an entry passes the filter.
@(private = "file")
filter_keeps :: proc(f: Filter, e: history.Entry) -> bool {
	switch f {
	case .All:    return true
	case .Text:   return e.kind == .Text || e.kind == .Html
	case .Images: return e.kind == .Image
	case .Files:  return e.kind == .Files
	case .Pinned: return e.pinned
	}
	return true
}

@(private = "file")
reader_entry :: proc(r: ^Reader, id: u64) -> ^history.Entry {
	at := history.find(&r.store, id)
	return at >= 0 ? &r.store.entries[at] : nil
}

// The content of entry `id` for the preview, the edit view and the QR code. An image's picture is the decoder's.
@(private = "file")
reader_load_entry :: proc(r: ^Reader, id, key: u64) -> (out: Loaded_Entry) {
	out.id, out.key = id, key
	e := reader_entry(r, id)
	if e == nil || e.key != key { return }
	out.ok = true
	switch e.kind {
	case .Image:
	case .Files:
		out.view_text = strings.clone(shown_text(e.preview))
		out.text = strings.clone(e.preview)
	case .Text, .Html, .Other:
		main := 0
		for rep, i in e.reps { if rep.hash == e.key { main = i } }
		data := history.blob_read(&r.store, e.reps[main].hash, context.temp_allocator)
		// rich text reads as its text: the program's own when it gave one, else the markup without its tags
		if e.kind == .Html && e.reps[main].mime == HTML_MIME { data = transmute([]u8)strip_tags(string(data)) }
		text := string(data[:min(len(data), VIEW_TEXT_MAX_BYTES)])
		for len(text) > 0 && !utf8.valid_string(text) { text = text[:len(text) - 1] }   // (cut inside a character)
		// (code: shown in the theme's colours, its language named in the header; guessed on the text as it is)
		if e.kind == .Text { out.code, out.has_code = syntax.guess(text) }
		// (as the window shows it: a "##" would end a box's shown text, so it is escaped here, once)
		out.view_text = strings.clone(shown_text(text))
		if e.kind != .Other { out.text = strings.clone(entry_whole_text(r, e)) }
	}
	out.qr = strings.clone(qr_content(e.kind, out.text))
	return
}

// The whole text of an entry: its text, unless that is its markup (a program may offer HTML as text too); else its
// markup without the tags (temp allocator).
@(private = "file")
entry_whole_text :: proc(r: ^Reader, e: ^history.Entry) -> string {
	html := ""
	if at := history.rep_find(e^, HTML_MIME); at >= 0 { html = string(history.blob_read(&r.store, e.reps[at].hash, context.temp_allocator)) }
	if at := history.rep_find(e^, TEXT_MIME); at >= 0 {
		text := string(history.blob_read(&r.store, e.reps[at].hash, context.temp_allocator))
		if text != html { return text }
	}
	if html != "" { return strip_tags(html) }
	return e.preview
}

// The file a program opens for the entry: a copied file itself, else its bytes written under open_dir (temp allocator).
@(private = "file")
entry_file :: proc(r: ^Reader, e: ^history.Entry) -> (path: string, ok: bool) {
	if e.kind == .Files { return entry_file_name(e), true }
	at := entry_open_rep(e)
	if at < 0 { return }
	data := history.blob_read(&r.store, e.reps[at].hash, context.temp_allocator)
	if data == nil { return }
	dir := open_dir()
	fsx.make_dirs(dir)
	path = fmt.tprintf("%s/%s", dir, entry_file_name(e))
	return path, fsx.write_atomic(path, data)
}

@(private = "file")
reader_run_job :: proc(r: ^Reader, j: ^Job) -> (d: Job_Done) {
	d.kind, d.id = j.kind, j.id
	switch j.kind {
	case .Write:
		if i := strings.last_index_any(j.path, "/\\"); i > 0 { fsx.make_dirs(j.path[:i]) }
		d.ok = fsx.write_atomic(j.path, j.data)
	case .Write_Prefs:
		d.ok = config.write_user_file(j.path, j.text)
		if !d.ok { d.message = strings.clone("The preferences cannot be written") }
	case .Read_Prefs:
		prefs_open(&d.prefs, nil)
		d.ok = true
	case .Handlers:
		// (the type is in the name: the file need not be written for its applications to be found)
		d.handlers = desktop.handlers_for_file(j.path)
		d.ok = true
	case .Reveal:
		d.ok = platform.reveal_in_folder(j.path)
		if !d.ok { d.message = strings.clone("The file manager does not start") }
	case .Save_As, .Open, .Open_With, .Drag:
		if !r.opened { d.message = strings.clone("The history cannot be read"); break }
		e := reader_entry(r, j.id)
		if e == nil { d.message = strings.clone("The entry is gone"); break }
		reader_entry_job(r, j, e, &d)
	case .Join:
		if !r.opened { break }
		parts := make([dynamic]string, context.temp_allocator)
		for id in j.ids {
			e := reader_entry(r, id)
			if e == nil || (e.kind != .Text && e.kind != .Html) { continue }
			if t := entry_whole_text(r, e); t != "" { append(&parts, t) }
		}
		d.text = strings.join(parts[:], "\n")
		d.ok = d.text != ""
		d.message = d.ok ? fmt.aprintf("Copied %d entries", len(j.ids)) : strings.clone("Nothing to copy")
	}
	return
}

// The jobs on one entry.
@(private = "file")
reader_entry_job :: proc(r: ^Reader, j: ^Job, e: ^history.Entry, d: ^Job_Done) {
	#partial switch j.kind {
	case .Save_As:
		data: []u8
		if at := entry_open_rep(e); at >= 0 { data = history.blob_read(&r.store, e.reps[at].hash, context.temp_allocator) }
		d.ok = data != nil && fsx.write_atomic(j.path, data)
		d.message = d.ok ? fmt.aprintf("Saved %s", file_name(j.path)) : fmt.aprintf("%s cannot be written", file_name(j.path))
	case .Open:
		if e.kind == .Text {
			if url := strings.trim_space(e.preview); is_address(url) {
				d.ok = platform.open_url(url)
				if !d.ok { d.message = strings.clone("No program opens addresses") }
				return
			}
		}
		path, ok := entry_file(r, e)
		if !ok { d.message = strings.clone("The entry cannot be written to a file"); return }
		d.ok = platform.open_path(path)
		if !d.ok { d.message = fmt.aprintf("No program opens %s", file_name(path)) }
	case .Open_With:
		path, ok := entry_file(r, e)
		if !ok { d.message = strings.clone("The entry cannot be written to a file"); return }
		d.ok = desktop.open_with(path, j.handler)
		if !d.ok { d.message = strings.clone("The program does not start") }
	case .Drag:
		// what the entry is: its text (and its markup for rich text), an image as a file of its own and as its PNG, copied
		// files as their paths
		data := &d.drag
		switch e.kind {
		case .Text:
			data.text = strings.clone(entry_whole_text(r, e))
		case .Html:
			data.text = strings.clone(entry_whole_text(r, e))
			if h := history.rep_find(e^, HTML_MIME); h >= 0 {
				data.html = strings.clone(string(history.blob_read(&r.store, e.reps[h].hash, context.temp_allocator)))
			}
		case .Image:
			if path, ok := entry_file(r, e); ok { append(&data.files, strings.clone(path)) }
			if p := history.rep_find(e^, "image/png"); p >= 0 { data.image = history.blob_read(&r.store, e.reps[p].hash) }
		case .Files:
			for line in strings.split_lines(e.preview, context.temp_allocator) {
				if line != "" { append(&data.files, strings.clone(line)) }
			}
		case .Other:
			if path, ok := entry_file(r, e); ok { append(&data.files, strings.clone(path)) }
		}
		d.ok = !platform.drag_data_empty(data^)
	}
}
