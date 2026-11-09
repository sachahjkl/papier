package papier

import "core:testing"
import "core:time"

// A picture is decoded on the decoder's thread; an unreadable file gives a picture that is not ok.
@(test)
a_picture_is_decoded_beside_the_window :: proc(t: ^testing.T) {
	d: Decoder
	decoder_start(&d, nil)
	defer decoder_stop(&d)
	decoder_ask(&d, 7, "assets/logo_64.png", "image/png")
	p, ok := decoder_wait(&d)
	defer decoded_free(&p)
	testing.expect(t, ok, "a picture comes")
	testing.expect_value(t, p.id, u64(7))
	testing.expect(t, p.ok)
	testing.expect_value(t, p.size, [2]int{64, 64})
	testing.expect_value(t, len(p.rgba), 64 * 64 * 4)

	decoder_ask(&d, 8, "assets/no such file.png", "image/png")
	q, qok := decoder_wait(&d)
	defer decoded_free(&q)
	testing.expect(t, qok && q.id == 8 && !q.ok, "a file that cannot be read gives no picture")
}

@(private = "file")
decoder_wait :: proc(d: ^Decoder) -> (p: Decoded, ok: bool) {
	for _ in 0 ..< 500 {
		if p, ok = decoder_take(d); ok { return }
		time.sleep(5 * time.Millisecond)
	}
	return
}
