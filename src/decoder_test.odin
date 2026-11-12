#+build !windows
package papier

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "gt:fsx"
import png "gt:png"
import "gt:qr"
import "history"

// The preview's picture is read for a QR code: a picture of one gives its text, a picture without one gives "".
@(test)
a_qr_code_in_a_picture_is_read :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/papier_test_decoder_qr_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(dir)
	defer fsx.remove_tree(dir)
	store: history.Store
	testing.expect(t, history.open(&store, dir))
	defer history.close(&store)

	TEXT :: "https://papier.example/qr?é"
	// (not the temp allocator: encode gives its temp memory back as it returns, the modules with it)
	code, err := qr.encode(TEXT)
	defer qr.destroy(&code)
	testing.expect_value(t, err, qr.Error.None)
	// (dark modules on white, 4 pixels each, the quiet zone around: as a screenshot of a code shows it)
	SCALE :: 4
	side := (code.size + 2 * qr.QUIET_ZONE) * SCALE
	rgba := make([]u8, side * side * 4, context.temp_allocator)
	for y in 0 ..< side {
		for x in 0 ..< side {
			dark := qr.module(code, x / SCALE - qr.QUIET_ZONE, y / SCALE - qr.QUIET_ZONE)
			v := u8(dark ? 0 : 255)
			rgba[(y * side + x) * 4 + 0], rgba[(y * side + x) * 4 + 1], rgba[(y * side + x) * 4 + 2], rgba[(y * side + x) * 4 + 3] = v, v, v, 255
		}
	}
	picture := png.encode(rgba, side, side, allocator = context.temp_allocator)
	_, added := history.add(&store, {{"image/png", picture}}, 0, .Image, "", 1)
	testing.expect(t, added, "the picture is stored")
	plain, _ := os.read_entire_file("assets/logo_64.png", context.temp_allocator)
	history.add(&store, {{"image/png", plain}}, 0, .Image, "", 2)

	d: Decoder
	decoder_start(&d, nil)
	defer decoder_stop(&d)
	decoder_ask(&d, 1, dir, history.hash_bytes(picture), "image/png")
	p, ok := decoder_wait(&d)
	defer decoded_free(&p)
	testing.expect(t, ok && p.ok, "the picture comes")
	c, cok := decoder_wait_qr(&d)
	defer picture_qr_free(&c)
	testing.expect(t, cok && c.id == 1, "its code is looked for after it")
	testing.expect_value(t, c.text, TEXT)

	decoder_ask(&d, 2, dir, history.hash_bytes(plain), "image/png")
	q, qok := decoder_wait(&d)
	defer decoded_free(&q)
	testing.expect(t, qok && q.ok, "the other picture comes")
	n, nok := decoder_wait_qr(&d)
	defer picture_qr_free(&n)
	testing.expect(t, nok && n.id == 2, "it is looked for too")
	testing.expect_value(t, n.text, "")
}

@(private = "file")
decoder_wait_qr :: proc(d: ^Decoder) -> (q: Picture_Qr, ok: bool) {
	for _ in 0 ..< 500 {
		if q, ok = decoder_take_qr(d); ok { return }
		time.sleep(5 * time.Millisecond)
	}
	return
}

// A picture is decoded on the decoder's thread, from the history's bytes; bytes that are not there give a picture
// that is not ok.
@(test)
a_picture_is_decoded_beside_the_window :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/papier_test_decoder_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(dir)
	defer fsx.remove_tree(dir)
	store: history.Store
	testing.expect(t, history.open(&store, dir))
	defer history.close(&store)
	png, _ := os.read_entire_file("assets/logo_64.png", context.temp_allocator)
	_, added := history.add(&store, {{"image/png", png}}, 0, .Image, "", 1)
	testing.expect(t, added, "the picture is stored")
	testing.expect_value(t, len(history.blob_read_in(dir, history.hash_bytes(png), context.temp_allocator)), len(png))

	d: Decoder
	decoder_start(&d, nil)
	defer decoder_stop(&d)
	decoder_ask(&d, 7, dir, history.hash_bytes(png), "image/png")
	p, ok := decoder_wait(&d)
	defer decoded_free(&p)
	testing.expect(t, ok, "a picture comes")
	testing.expect_value(t, p.id, u64(7))
	testing.expect(t, p.ok)
	testing.expect_value(t, p.size, [2]int{64, 64})
	testing.expect_value(t, len(p.rgba), 64 * 64 * 4)

	decoder_ask(&d, 8, dir, 12345, "image/png")
	q, qok := decoder_wait(&d)
	defer decoded_free(&q)
	testing.expect(t, qok && q.id == 8 && !q.ok, "bytes that are not there give no picture")
}

@(private = "file")
decoder_wait :: proc(d: ^Decoder) -> (p: Decoded, ok: bool) {
	for _ in 0 ..< 500 {
		if p, ok = decoder_take(d); ok { return }
		time.sleep(5 * time.Millisecond)
	}
	return
}

// The rows' thumbnails: a picture larger than THUMB_PX shrunk to it on its shorter side, a smaller one kept; an image that
// is not there reported, so that it is asked no more.
@(test)
thumbnails_are_made_for_the_rows_in_view :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/papier_test_thumbs_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(dir)
	defer fsx.remove_tree(dir)
	store: history.Store
	testing.expect(t, history.open(&store, dir))
	defer history.close(&store)
	big, _ := os.read_entire_file("assets/logo_256.png", context.temp_allocator)
	small, _ := os.read_entire_file("assets/logo_32.png", context.temp_allocator)
	history.add(&store, {{"image/png", big}}, 0, .Image, "", 1)
	history.add(&store, {{"image/png", small}}, 0, .Image, "", 2)

	d: Decoder
	decoder_start(&d, nil)
	defer decoder_stop(&d)
	decoder_want_thumbs(&d, {{history.hash_bytes(big), dir, "image/png"}, {history.hash_bytes(small), dir, "image/png"}, {999, dir, "image/png"}})
	got: [dynamic]Thumb
	defer { for &m in got { thumb_free(&m) }; delete(got) }
	for _ in 0 ..< 500 {
		append(&got, ..decoder_take_thumbs(&d))
		if len(got) == 3 { break }
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, len(got), 3)
	if len(got) != 3 { return }
	testing.expect(t, got[0].ok && got[0].size == {THUMB_PX, THUMB_PX}, "shrunk to THUMB_PX, in the rows' order")
	testing.expect_value(t, len(got[0].rgba), THUMB_PX * THUMB_PX * 4)
	testing.expect(t, got[1].ok && got[1].size == {32, 32}, "a small one as it is")
	testing.expect(t, got[2].hash == 999 && !got[2].ok, "not there: said")
}
