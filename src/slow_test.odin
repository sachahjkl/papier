#+build !windows
package papier

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"
import "gt:fsx"
import ocr "gt:ocr"
import png "gt:png"
import "history"

// The worker says whether the system reads text; a copied file that is not there has no thumbnail, and says so (it is
// asked no more).
@(test)
the_slow_worker_says_what_it_can :: proc(t: ^testing.T) {
	s: Slow
	slow_start(&s, nil)
	defer slow_stop(&s)
	known := false
	for _ in 0 ..< 1000 {
		if known, _ = slow_ocr_state(&s); known { break }
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, known, "the worker says whether OCR is there")

	path := "/nonexistent/papier-test/missing.png"
	key := file_thumb_key(path)
	slow_want_file_thumbs(&s, {{key, path}})
	got: [dynamic]Thumb
	defer { for &m in got { thumb_free(&m) }; delete(got) }
	for _ in 0 ..< 1000 {
		append(&got, ..slow_take_file_thumbs(&s))
		if len(got) > 0 { break }
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 { testing.expect(t, got[0].hash == key && !got[0].ok, "a missing file: no thumbnail, said") }
}

// A picture with no text: read with no error and no line where the system has an engine; without one, the error says so
// (the test passes either way, with a log line).
@(test)
an_image_is_read_on_the_slow_worker :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/papier_test_slow_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(dir)
	defer fsx.remove_tree(dir)
	store: history.Store
	testing.expect(t, history.open(&store, dir))
	defer history.close(&store)
	SIDE :: 64
	white := make([]u8, SIDE * SIDE * 4, context.temp_allocator)
	for &b in white { b = 255 }
	picture := png.encode(white, SIDE, SIDE, allocator = context.temp_allocator)
	history.add(&store, {{"image/png", picture}}, 0, .Image, "", 1)

	s: Slow
	slow_start(&s, nil)
	defer slow_stop(&s)
	slow_ocr(&s, 9, dir, history.hash_bytes(picture), "image/png")
	d: Ocr_Done
	ok := false
	// (a reading takes a second or more: the bound is long, the wait ends as soon as it comes)
	for _ in 0 ..< 3000 {
		if d, ok = slow_take_ocr(&s); ok { break }
		time.sleep(5 * time.Millisecond)
	}
	defer ocr_done_free(&d)
	testing.expect(t, ok, "the reading ends")
	if !ok { return }
	testing.expect_value(t, d.id, u64(9))
	testing.expect(t, !d.unreadable, "the picture is read")
	if _, available := slow_ocr_state(&s); !available {
		log.infof("no OCR engine or language on this system: %s", ocr.error_text(d.err))
		testing.expect(t, d.err != .None, "without an engine, an error")
		return
	}
	testing.expect_value(t, d.err, ocr.Error.None)
	testing.expect_value(t, d.lines, 0)
}
