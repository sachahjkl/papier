package papier

// Images are decoded by a job on a pool of one thread of their own (gt:tasks): a 4K screenshot takes about 180 ms to
// decode, and the selection must move at once. The window asks for one picture at a time and the newest ask wins: a
// selection that passes over ten images decodes the last one only. When a picture is ready, the decoder wakes the
// window, which makes its texture.
//
// The list's thumbnails come after it: the window says at each build which rows in view still want one, in place of what
// it said before (a list scrolled fast decodes only what stays in view), and each is shrunk here to THUMB_PX.
//
// The preview's picture is also read for a QR code (a screenshot of a code, a ticket): its text comes with the picture.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import paint "gt:paint"
import "gt:platform"
import "gt:qr"
import tasks "gt:tasks"
import "history"

Decoder :: struct {
	pool:    tasks.Pool,         // one thread: a decode never waits behind the reader or the slow worker
	job:     tasks.Job,          // decoder_work: asked at each ask, merged while it runs
	up:      bool,
	window:  ^platform.Window,   // woken when a picture is ready (platform.wake is thread-safe)
	mutex:   sync.Mutex,
	stop:    bool,
	ask:     Decode_Ask,         // the newest ask, while `asked`
	asked:   bool,
	done:    Decoded,            // the newest picture, while `ready`
	ready:   bool,
	qr:      Picture_Qr,         // the text of a QR code in the newest picture, while `qr_ready`
	qr_ready: bool,
	thumbs_wanted: [dynamic]Thumb_Ask,   // the rows in view without a thumbnail, first first (heap)
	thumbs_done:   [dynamic]Thumb,       // thumbnails made, not yet taken (heap)
	thumb_making:  u64,                  // the image being shrunk (0: none)
}

// The shorter side of a thumbnail, in pixels: a row's mark at twice the scale, cropped to a square when drawn.
THUMB_PX :: 72

// A thumbnail to make: the image's representation (its hash names it), the store that holds it, its MIME type.
Thumb_Ask :: struct { hash: u64, dir: string, mime: string }

// A thumbnail: RGBA, straight alpha (heap; thumb_free). ok = false: the image cannot be read (asked no more).
Thumb :: struct {
	hash: u64,
	rgba: []u8,
	size: [2]int,
	ok:   bool,
}

thumb_free :: proc(t: ^Thumb) {
	delete(t.rgba, runtime.heap_allocator())
	t^ = {}
}

// What to decode: the entry, the store that holds its image (its directory) and the image's hash and MIME type (owned
// by the decoder's heap).
@(private = "file")
Decode_Ask :: struct { id: u64, dir: string, hash: u64, mime: string }

// A decoded picture: RGBA, straight alpha, `size.x * size.y * 4` bytes, owned by whoever took it (decoded_free).
Decoded :: struct {
	id:   u64,
	rgba: []u8,
	size: [2]int,
	ok:   bool,
}

decoder_start :: proc(d: ^Decoder, window: ^platform.Window) {
	d.window = window
	d.thumbs_wanted = make([dynamic]Thumb_Ask, runtime.heap_allocator())
	d.thumbs_done = make([dynamic]Thumb, runtime.heap_allocator())
	d.job = {work = decoder_work, data = d}
	tasks.start(&d.pool, {threads = 1})
	d.up = true
}

// What was asked is decoded, and what is asked meanwhile in one more run.
@(private = "file")
decoder_poke :: proc(d: ^Decoder) { tasks.job_ask(&d.pool, &d.job) }

decoder_stop :: proc(d: ^Decoder) {
	if !d.up { return }
	sync.mutex_lock(&d.mutex)
	d.stop = true
	sync.mutex_unlock(&d.mutex)
	// (a run under way ends at its next look at `stop`; one waiting is dropped)
	tasks.stop(&d.pool, proc(_: rawptr) {})
	d.up = false
	heap := runtime.heap_allocator()
	if d.asked { delete(d.ask.dir, heap); delete(d.ask.mime, heap) }
	if d.ready { decoded_free(&d.done) }
	if d.qr_ready { picture_qr_free(&d.qr) }
	d.asked, d.ready, d.qr_ready = false, false, false
	thumb_asks_clear(d)
	delete(d.thumbs_wanted)
	for &t in d.thumbs_done { thumb_free(&t) }
	delete(d.thumbs_done)
}

@(private = "file")
thumb_asks_clear :: proc(d: ^Decoder) {
	heap := runtime.heap_allocator()
	for a in d.thumbs_wanted { delete(a.dir, heap); delete(a.mime, heap) }
	clear(&d.thumbs_wanted)
}

// The thumbnails the rows in view want, first first, in place of those asked before. One being made, or made and not
// taken, is not made again.
decoder_want_thumbs :: proc(d: ^Decoder, asks: []Thumb_Ask) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	thumb_asks_clear(d)
	next: for a in asks {
		if a.hash == d.thumb_making { continue }
		for t in d.thumbs_done { if t.hash == a.hash { continue next } }
		append(&d.thumbs_wanted, Thumb_Ask{a.hash, strings.clone(a.dir, heap), strings.clone(a.mime, heap)})
	}
	if len(d.thumbs_wanted) > 0 { decoder_poke(d) }
}

// The thumbnails made since the last take (temp slice; the caller owns each: thumb_free).
decoder_take_thumbs :: proc(d: ^Decoder) -> []Thumb {
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	if len(d.thumbs_done) == 0 { return nil }
	out := make([]Thumb, len(d.thumbs_done), context.temp_allocator)
	copy(out, d.thumbs_done[:])
	clear(&d.thumbs_done)
	return out
}

// A thumbnail of the image: decoded, then shrunk (thumb_of).
@(private = "file")
thumb_make :: proc(ask: Thumb_Ask) -> (t: Thumb) {
	t.hash = ask.hash
	bytes := history.blob_read_in(ask.dir, ask.hash)
	if bytes == nil { return }
	defer delete(bytes)
	img, ok := platform.clipboard_image_decode(ask.mime, bytes, context.allocator)
	if !ok { return }
	return thumb_of(ask.hash, img.rgba, img.size)
}

// The thumbnail `key` names of a picture (heap; taken: it is kept or freed), shrunk so its shorter side is THUMB_PX (a
// smaller one is kept as it is). On a worker's thread, whose allocator is the heap.
thumb_of :: proc(key: u64, rgba: []u8, size: [2]int) -> (t: Thumb) {
	t.hash = key
	w, h := size.x, size.y
	short := min(w, h)
	if short <= 0 || len(rgba) < w * h * 4 { delete(rgba); return }
	if short <= THUMB_PX {
		t.rgba, t.size = rgba, size
	} else {
		dw, dh := max(w * THUMB_PX / short, 1), max(h * THUMB_PX / short, 1)
		t.rgba, t.size = paint.rgba_shrink(rgba, w, h, dw, dh), {dw, dh}
		delete(rgba)
	}
	t.ok = t.rgba != nil
	return
}

// Asks for the picture of entry `id`, in place of any ask not yet started.
decoder_ask :: proc(d: ^Decoder, id: u64, dir: string, hash: u64, mime: string) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	if d.asked { delete(d.ask.dir, heap); delete(d.ask.mime, heap) }
	d.ask = {id, strings.clone(dir, heap), hash, strings.clone(mime, heap)}
	d.asked = true
	decoder_poke(d)
}

// The newest picture decoded, if one is ready. The caller owns it.
decoder_take :: proc(d: ^Decoder) -> (out: Decoded, ok: bool) {
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	if !d.ready { return }
	out, ok = d.done, true
	d.done, d.ready = {}, false
	return
}

decoded_free :: proc(p: ^Decoded) {
	delete(p.rgba, runtime.heap_allocator())
	p^ = {}
}

// The text of a QR code in the preview's picture ("" none, or data that is not UTF-8 text: a code of raw bytes is not
// copied as text), for entry `id` (heap; picture_qr_free).
Picture_Qr :: struct {
	id:   u64,
	text: string,
}

picture_qr_free :: proc(q: ^Picture_Qr) {
	delete(q.text, runtime.heap_allocator())
	q^ = {}
}

// The QR text of the newest picture, once it was looked for. The caller owns it.
decoder_take_qr :: proc(d: ^Decoder) -> (out: Picture_Qr, ok: bool) {
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	if !d.qr_ready { return }
	out, ok = d.qr, true
	d.qr, d.qr_ready = {}, false
	return
}

// A picture in grey, 0 black (what the QR reader reads), so that the RGBA can go to the window before the search.
@(private = "file")
picture_gray :: proc(rgba: []u8, size: [2]int) -> []u8 {
	n := size.x * size.y
	gray := make([]u8, n)
	for i in 0 ..< n {
		p := rgba[i * 4:]
		gray[i] = u8((u32(p[0]) * 299 + u32(p[1]) * 587 + u32(p[2]) * 114) / 1000)
	}
	return gray
}

@(private = "file")
gray_qr :: proc(gray: []u8, size: [2]int) -> string {
	// (not the temp allocator: decode_gray gives its temp memory back as it returns, the result's data with it)
	d, err := qr.decode_gray(gray, size.x, size.y, size.x)
	defer qr.decoded_destroy(&d)
	if err != .None || len(d.data) == 0 || !utf8.valid_string(string(d.data)) { return "" }
	return strings.clone(string(d.data))
}

// A run: the preview's picture and the thumbnails asked, one at a time, until none waits.
@(private = "file")
decoder_work :: proc(data: rawptr) {
	d := (^Decoder)(data)
	context.allocator = runtime.heap_allocator()
	for {
		sync.mutex_lock(&d.mutex)
		if d.stop || (!d.asked && len(d.thumbs_wanted) == 0) { sync.mutex_unlock(&d.mutex); return }
		// (the preview first: the one picture the user looks at)
		if !d.asked {
			ask := d.thumbs_wanted[0]
			ordered_remove(&d.thumbs_wanted, 0)
			d.thumb_making = ask.hash
			sync.mutex_unlock(&d.mutex)
			t := thumb_make(ask)
			delete(ask.dir)
			delete(ask.mime)
			sync.mutex_lock(&d.mutex)
			append(&d.thumbs_done, t)
			d.thumb_making = 0
			sync.mutex_unlock(&d.mutex)
			if d.window != nil { platform.wake(d.window) }
			free_all(context.temp_allocator)
			continue
		}
		ask := d.ask
		d.asked = false
		sync.mutex_unlock(&d.mutex)

		out := Decoded{id = ask.id}
		gray: []u8
		if bytes := history.blob_read_in(ask.dir, ask.hash); bytes != nil {
			if img, ok := platform.clipboard_image_decode(ask.mime, bytes, context.allocator); ok {
				out.rgba, out.size, out.ok = img.rgba, img.size, true
				// (the preview's picture only: a thumbnail is too small to hold a readable code)
				gray = picture_gray(img.rgba, img.size)
			}
			delete(bytes)
		}
		delete(ask.dir)
		delete(ask.mime)

		sync.mutex_lock(&d.mutex)
		if d.ready { decoded_free(&d.done) }   // (a picture the window never took: a newer one replaces it)
		d.done, d.ready = out, true
		// (the search for a code comes after: on a 4K screenshot it takes about 100 ms, which the picture does not wait
		// for; a newer picture asked meanwhile makes it pointless)
		search := gray != nil && !d.asked && !d.stop
		sync.mutex_unlock(&d.mutex)
		if d.window != nil { platform.wake(d.window) }   // (nil: a test reads the picture itself)
		if search {
			found := Picture_Qr{ask.id, gray_qr(gray, out.size)}
			sync.mutex_lock(&d.mutex)
			if d.qr_ready { picture_qr_free(&d.qr) }
			d.qr, d.qr_ready = found, true
			sync.mutex_unlock(&d.mutex)
			if d.window != nil { platform.wake(d.window) }
		}
		delete(gray)
		free_all(context.temp_allocator)
	}
}
