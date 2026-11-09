#+build !windows
package papier

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "gt:fsx"
import "history"

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
