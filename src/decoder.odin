package papier

// Images are decoded on a thread of their own: a 4K screenshot takes about 180 ms to decode, and the selection must move
// at once. The window asks for one picture at a time and the newest ask wins: a selection that passes over ten images
// decodes the last one only. When a picture is ready, the decoder wakes the window, which makes its texture.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import os "core:os"
import "gt:platform"

Decoder :: struct {
	thread:  ^thread.Thread,
	window:  ^platform.Window,   // woken when a picture is ready (platform.wake is thread-safe)
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	stop:    bool,
	ask:     Decode_Ask,         // the newest ask, while `asked`
	asked:   bool,
	done:    Decoded,            // the newest picture, while `ready`
	ready:   bool,
}

// What to decode: the entry, the file of its image and the image's MIME type (owned by the decoder's heap).
@(private = "file")
Decode_Ask :: struct { id: u64, path, mime: string }

// A decoded picture: RGBA, straight alpha, `size.x * size.y * 4` bytes, owned by whoever took it (decoded_free).
Decoded :: struct {
	id:   u64,
	rgba: []u8,
	size: [2]int,
	ok:   bool,
}

decoder_start :: proc(d: ^Decoder, window: ^platform.Window) {
	d.window = window
	d.thread = thread.create_and_start_with_data(d, decoder_run, context)
}

decoder_stop :: proc(d: ^Decoder) {
	if d.thread == nil { return }
	sync.mutex_lock(&d.mutex)
	d.stop = true
	sync.cond_signal(&d.cond)
	sync.mutex_unlock(&d.mutex)
	thread.join(d.thread)
	thread.destroy(d.thread)
	d.thread = nil
	heap := runtime.heap_allocator()
	if d.asked { delete(d.ask.path, heap); delete(d.ask.mime, heap) }
	if d.ready { decoded_free(&d.done) }
	d.asked, d.ready = false, false
}

// Asks for the picture of entry `id`, in place of any ask not yet started.
decoder_ask :: proc(d: ^Decoder, id: u64, path, mime: string) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	if d.asked { delete(d.ask.path, heap); delete(d.ask.mime, heap) }
	d.ask = {id, strings.clone(path, heap), strings.clone(mime, heap)}
	d.asked = true
	sync.cond_signal(&d.cond)
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

@(private = "file")
decoder_run :: proc(data: rawptr) {
	d := (^Decoder)(data)
	context.allocator = runtime.heap_allocator()
	for {
		sync.mutex_lock(&d.mutex)
		for !d.asked && !d.stop { sync.cond_wait(&d.cond, &d.mutex) }
		if d.stop { sync.mutex_unlock(&d.mutex); return }
		ask := d.ask
		d.asked = false
		sync.mutex_unlock(&d.mutex)

		out := Decoded{id = ask.id}
		if bytes, err := os.read_entire_file(ask.path, context.allocator); err == nil {
			if img, ok := platform.clipboard_image_decode(ask.mime, bytes, context.allocator); ok {
				out.rgba, out.size, out.ok = img.rgba, img.size, true
			}
			delete(bytes)
		}
		delete(ask.path)
		delete(ask.mime)

		sync.mutex_lock(&d.mutex)
		if d.ready { decoded_free(&d.done) }   // (a picture the window never took: a newer one replaces it)
		d.done, d.ready = out, true
		sync.mutex_unlock(&d.mutex)
		if d.window != nil { platform.wake(d.window) }   // (nil: a test reads the picture itself)
		free_all(context.temp_allocator)
	}
}
