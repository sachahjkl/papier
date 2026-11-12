package papier

// The slow worker: what takes seconds, on a thread of its own, so that it never waits behind the preview's decoder or
// the reader, nor makes them wait. It reads the text of an image (OCR: a second or more) and makes the system's
// thumbnails of copied files (a thumbnailer may run 30 seconds).
//
// At its start it asks whether the system can read text (ocr.available loads a library): the window offers the action
// once it says so. An OCR ask goes first; the newest one replaces one not yet started. The thumbnails of files are asked
// at each build for the rows in view, in place of those asked before, as the decoder's.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import desktop "gt:desktop"
import ocr "gt:ocr"
import "gt:platform"
import "history"

Slow :: struct {
	thread:  ^thread.Thread,
	window:  ^platform.Window,   // woken when a result is ready (nil: a test reads it itself)
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	stop:    bool,
	ocr_known:     bool,         // atomic: the worker asked the system whether it can read text
	ocr_available: bool,         // atomic: and it can
	ocr_ask:   Ocr_Ask,          // the newest OCR ask, while ocr_asked (heap)
	ocr_asked: bool,
	ocr_done:  Ocr_Done,         // the last text read, while ocr_ready (heap)
	ocr_ready: bool,
	files_wanted: [dynamic]File_Thumb_Ask,   // the rows in view without a thumbnail, first first (heap)
	files_done:   [dynamic]Thumb,            // thumbnails made, not yet taken (heap)
	file_making:  u64,                       // the key of the one being made (0: none)
}

// A copied file's thumbnail to make: its key (history.hash_bytes of the path: the thumbnails' map holds images too) and
// its path.
File_Thumb_Ask :: struct { key: u64, path: string }

// What OCR read in the picture of entry `id` (heap; ocr_done_free).
Ocr_Done :: struct {
	id:    u64,
	text:  string,      // its lines in reading order
	lines: int,         // how many (0: no text)
	err:   ocr.Error,
	unreadable: bool,   // the picture's bytes are gone, or not a picture papier decodes (err is then None)
}

@(private = "file")
Ocr_Ask :: struct { id: u64, dir: string, hash: u64, mime: string }

ocr_done_free :: proc(d: ^Ocr_Done) {
	delete(d.text, runtime.heap_allocator())
	d^ = {}
}

// The key of a copied file's thumbnail.
file_thumb_key :: proc(path: string) -> u64 { return history.hash_bytes(transmute([]u8)path) }

slow_start :: proc(s: ^Slow, window: ^platform.Window) {
	heap := runtime.heap_allocator()
	s.window = window
	s.files_wanted = make([dynamic]File_Thumb_Ask, heap)
	s.files_done = make([dynamic]Thumb, heap)
	s.thread = thread.create_and_start_with_data(s, slow_run, context)
}

// Stops the worker. (A thumbnailer or a reading under way ends first: neither can be cut short.)
slow_stop :: proc(s: ^Slow) {
	if s.thread == nil { return }
	sync.mutex_lock(&s.mutex)
	s.stop = true
	sync.cond_signal(&s.cond)
	sync.mutex_unlock(&s.mutex)
	thread.join(s.thread)
	thread.destroy(s.thread)
	s.thread = nil
	if s.ocr_asked { ocr_ask_free(&s.ocr_ask) }
	if s.ocr_ready { ocr_done_free(&s.ocr_done) }
	s.ocr_asked, s.ocr_ready = false, false
	file_asks_clear(s)
	delete(s.files_wanted)
	for &t in s.files_done { thumb_free(&t) }
	delete(s.files_done)
}

// Whether the worker asked the system yet (known), and whether the system can read the text of a picture.
slow_ocr_state :: proc(s: ^Slow) -> (known, available: bool) {
	return sync.atomic_load(&s.ocr_known), sync.atomic_load(&s.ocr_available)
}

// Reads the text of the picture of entry `id` (the store of `dir`, the representation `hash` of type `mime`), in place
// of an ask not yet started.
slow_ocr :: proc(s: ^Slow, id: u64, dir: string, hash: u64, mime: string) {
	heap := runtime.heap_allocator()
	sync.guard(&s.mutex)
	if s.ocr_asked { ocr_ask_free(&s.ocr_ask) }
	s.ocr_ask = {id, strings.clone(dir, heap), hash, strings.clone(mime, heap)}
	s.ocr_asked = true
	sync.cond_signal(&s.cond)
}

// The text read, if a reading ended. The caller owns it.
slow_take_ocr :: proc(s: ^Slow) -> (out: Ocr_Done, ok: bool) {
	sync.guard(&s.mutex)
	if !s.ocr_ready { return }
	out, ok = s.ocr_done, true
	s.ocr_done, s.ocr_ready = {}, false
	return
}

// The thumbnails of copied files the rows in view want, first first, in place of those asked before. One being made, or
// made and not taken, is not asked again.
slow_want_file_thumbs :: proc(s: ^Slow, asks: []File_Thumb_Ask) {
	heap := runtime.heap_allocator()
	sync.guard(&s.mutex)
	file_asks_clear(s)
	next: for a in asks {
		if a.key == s.file_making { continue }
		for t in s.files_done { if t.hash == a.key { continue next } }
		append(&s.files_wanted, File_Thumb_Ask{a.key, strings.clone(a.path, heap)})
	}
	if len(s.files_wanted) > 0 { sync.cond_signal(&s.cond) }
}

// The thumbnails made since the last take (temp slice; the caller owns each: thumb_free).
slow_take_file_thumbs :: proc(s: ^Slow) -> []Thumb {
	sync.guard(&s.mutex)
	if len(s.files_done) == 0 { return nil }
	out := make([]Thumb, len(s.files_done), context.temp_allocator)
	copy(out, s.files_done[:])
	clear(&s.files_done)
	return out
}

@(private = "file")
ocr_ask_free :: proc(a: ^Ocr_Ask) {
	heap := runtime.heap_allocator()
	delete(a.dir, heap)
	delete(a.mime, heap)
	a^ = {}
}

@(private = "file")
file_asks_clear :: proc(s: ^Slow) {
	for a in s.files_wanted { delete(a.path, runtime.heap_allocator()) }
	clear(&s.files_wanted)
}

@(private = "file")
slow_run :: proc(data: rawptr) {
	s := (^Slow)(data)
	context.allocator = runtime.heap_allocator()
	// (it may load libtesseract: never on the window's thread)
	_, available := ocr.available()
	sync.atomic_store(&s.ocr_available, available)
	sync.atomic_store(&s.ocr_known, true)
	if s.window != nil { platform.wake(s.window) }

	for {
		sync.mutex_lock(&s.mutex)
		for !s.ocr_asked && len(s.files_wanted) == 0 && !s.stop { sync.cond_wait(&s.cond, &s.mutex) }
		if s.stop { sync.mutex_unlock(&s.mutex); return }
		// (the text the user asked for first: a thumbnail is only a row's mark)
		if s.ocr_asked {
			ask := s.ocr_ask
			s.ocr_ask, s.ocr_asked = {}, false
			sync.mutex_unlock(&s.mutex)
			out := ocr_read(ask)
			ocr_ask_free(&ask)
			sync.mutex_lock(&s.mutex)
			if s.ocr_ready { ocr_done_free(&s.ocr_done) }
			s.ocr_done, s.ocr_ready = out, true
			sync.mutex_unlock(&s.mutex)
		} else {
			ask := s.files_wanted[0]
			ordered_remove(&s.files_wanted, 0)
			s.file_making = ask.key
			sync.mutex_unlock(&s.mutex)
			t := Thumb{hash = ask.key}
			if th, ok := desktop.thumbnail(ask.path, 2 * THUMB_PX); ok { t = thumb_of(ask.key, th.rgba, th.size) }
			delete(ask.path)
			sync.mutex_lock(&s.mutex)
			append(&s.files_done, t)
			s.file_making = 0
			sync.mutex_unlock(&s.mutex)
		}
		if s.window != nil { platform.wake(s.window) }
		free_all(context.temp_allocator)
	}
}

// The text in a picture of the store: its bytes read, decoded, read by the system's engine.
@(private = "file")
ocr_read :: proc(ask: Ocr_Ask) -> (out: Ocr_Done) {
	out.id = ask.id
	bytes := history.blob_read_in(ask.dir, ask.hash)
	if bytes == nil { out.unreadable = true; return }
	defer delete(bytes)
	img, ok := platform.clipboard_image_decode(ask.mime, bytes, context.allocator)
	if !ok { out.unreadable = true; return }
	defer delete(img.rgba)
	r, err := ocr.recognize(img.rgba, img.size.x, img.size.y, img.size.x * 4, .RGBA)
	out.err = err
	if err != .None { return }
	out.lines = len(r.lines)
	out.text, r.text = r.text, ""
	ocr.result_destroy(&r)
	return
}
