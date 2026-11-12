package papier

// The thumbnails of the list: an image's row shows a small picture of it in place of its kind's mark, so a scroll tells
// the images apart; a copied file's row shows the system's thumbnail of its first file. The decoder makes the images'
// (decoder.odin), the slow worker the files' (slow.odin: a thumbnailer may take seconds), for the rows in view; the
// window keeps their textures by their key (an image's hash, a path's hash), at most THUMBS_KEPT, the ones least lately
// shown going first.

import "core:strings"
import "gt:draw"
import "gt:render"
import "gt:ui"
import "history"

THUMBS_KEPT :: 300

Thumbs :: struct {
	kept:   map[u64]Thumb_Texture,   // by their key
	failed: map[u64]bool,            // pictures and files that have none: asked no more
	asks:   [dynamic]Thumb_Ask,      // this build's images (strings borrowed from the list shown)
	file_asks: [dynamic]File_Thumb_Ask,   // this build's files (the same)
	build:  u64,                     // builds counted, for "least lately shown"
}

Thumb_Texture :: struct {
	tex:   render.Texture,
	size:  [2]f32,
	shown: u64,   // the build it was last shown in
}

thumbs_destroy :: proc(app: ^App) {
	t := &app.thumbs
	for _, k in t.kept { render.destroy_texture(&app.shared.r, k.tex) }
	delete(t.kept)
	delete(t.failed)
	delete(t.asks)
	delete(t.file_asks)
	t^ = {}
}

// The image representation of an entry (-1: none).
image_rep :: proc(e: ^history.Entry) -> int {
	for r, i in e.reps { if strings.has_prefix(r.mime, "image/") { return i } }
	return -1
}

// At the start of the list's build.
thumbs_begin :: proc(app: ^App) {
	app.thumbs.build += 1
	clear(&app.thumbs.asks)
	clear(&app.thumbs.file_asks)
}

// Whether an entry's row can show a thumbnail: an image, a copied file.
has_thumb :: proc(e: ^history.Entry) -> bool { return e.kind == .Image || e.kind == .Files }

// The mark of an image's or a copied file's row: its thumbnail, `width` wide; false when there is none yet (it is asked,
// unless it is known to have none).
thumb_mark :: proc(app: ^App, e: ^history.Entry, width: f32) -> bool {
	key: u64
	path: string
	at := -1
	#partial switch e.kind {
	case .Image:
		at = image_rep(e)
		if at < 0 { return false }
		key = e.reps[at].hash
	case .Files:
		path = entry_file_name(e)   // (the first file; a row in view: one hash of a path per build)
		if path == "" { return false }
		key = file_thumb_key(path)
	case:
		return false
	}
	t := &app.thumbs
	if k, ok := &t.kept[key]; ok {
		k.shown = t.build
		d := new(Thumb_Draw, context.temp_allocator)
		d^ = {k.tex, k.size}
		ui.next({width = ui.px(width), height = ui.pct(1)})
		ui.custom("thumb", thumb_draw, d)
		return true
	}
	if t.failed[key] { return false }
	if e.kind == .Image {
		append(&t.asks, Thumb_Ask{key, app.list.dir, e.reps[at].mime})
	} else {
		append(&t.file_asks, File_Thumb_Ask{key, path})
	}
	return false
}

// At the end of the list's build: the rows in view that want a thumbnail, to the decoder and to the slow worker.
thumbs_end :: proc(app: ^App) {
	decoder_want_thumbs(&app.decoder, app.thumbs.asks[:])
	slow_want_file_thumbs(&app.slow, app.thumbs.file_asks[:])
}

// What the decoder and the slow worker made: textures, the least lately shown let go past THUMBS_KEPT. True when one
// came.
thumbs_take :: proc(app: ^App) -> bool {
	images := decoder_take_thumbs(&app.decoder)
	files := slow_take_file_thumbs(&app.slow)
	made := make([dynamic]Thumb, 0, len(images) + len(files), context.temp_allocator)
	append(&made, ..images)
	append(&made, ..files)
	t := &app.thumbs
	for &m in made {
		defer thumb_free(&m)
		if !m.ok { t.failed[m.hash] = true; continue }
		if _, ok := t.kept[m.hash]; ok { continue }
		tex := render.create_texture_rgba(&app.shared.r, m.size.x, m.size.y)
		render.update_texture_rgba(&app.shared.r, tex, 0, 0, m.size.x, m.size.y, m.rgba)
		t.kept[m.hash] = {tex, {f32(m.size.x), f32(m.size.y)}, t.build}
	}
	for len(t.kept) > THUMBS_KEPT {
		oldest: u64
		least := max(u64)
		for h, k in t.kept { if k.shown < least { least, oldest = k.shown, h } }
		render.destroy_texture(&app.shared.r, t.kept[oldest].tex)
		delete_key(&t.kept, oldest)
	}
	return len(made) > 0
}

@(private = "file")
Thumb_Draw :: struct { tex: render.Texture, size: [2]f32 }

// The whole picture, as large as the box less its margin allows, centred, its corners rounded.
@(private = "file")
thumb_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Thumb_Draw)(user)
	r := b.rect
	margin := (r.max.y - r.min.y) * THUMB_MARGIN
	room := r.max - r.min - {2 * margin, 2 * margin}
	if room.x <= 0 || room.y <= 0 || d.size.x <= 0 || d.size.y <= 0 { return }
	size := d.size * min(room.x / d.size.x, room.y / d.size.y)
	at := r.min + {margin, margin} + (room - size) * 0.5
	draw.image(dc, d.tex, {at, at + size}, radius = min(size.x, size.y) * 0.12)
}

// Of the row's height, kept clear above and below a thumbnail.
THUMB_MARGIN :: 0.12
