package papiertool

// logo: papier's mark, drawn by the toolkit's paint package (the same bytes on every system). A silhouette on nothing,
// with the depth of Wren's logo: two sheets of paper, the one behind turned a little and darker (the history under the
// last copy), parted from the front one by a gap; each sheet a soft vertical gradient of paper with a darker edge; the
// folded corner lighter; the lines of the text cut out. Small sizes drop the lines that would blur (detail_for).
// assets/logo.png (1024 px) and the sizes the program and the site embed.

import "core:fmt"
import "core:os"
import paint "gt:paint"

LOGO_DIR    :: "assets"
LOGO_MASTER :: 1024
LOGO_SIZES  :: [?]int{16, 32, 64, 128, 256}
// The drawing's own units: a square of LOGO_UNITS, scaled to the canvas.
LOGO_UNITS  :: 512.0
// The transparent space between the sheets, and the width of an edge, in units.
LOGO_GAP    :: 22.0
LOGO_EDGE   :: 12.0
// Small sizes are drawn from a master this many times larger, in one step of the cubic filter at most this factor.
LOGO_SHRINK_STEP :: 4

// The colours: top and bottom of each gradient, and the edges.
FRONT_TOP    :: 0xEFE9DF
FRONT_BOTTOM :: 0xD9CFBF
FRONT_EDGE   :: 0x8F8472
BACK_TOP     :: 0xBDB2A0
BACK_BOTTOM  :: 0x9A8F7D
BACK_EDGE    :: 0x6B6253
FOLD_TOP     :: 0xFFFFFF
FOLD_BOTTOM  :: 0xEEE8DD

// A sheet: a rectangle whose top right corner is cut by `fold` (0: none), its other corners rounded by `r`.
@(private = "file")
sheet_path :: proc(p: ^paint.Path, x0, y0, x1, y1, fold, r: f32) {
	paint.move_to(p, x0 + r, y0)
	if fold > 0 {
		paint.line_to(p, x1 - fold, y0)
		paint.line_to(p, x1, y0 + fold)
	} else {
		paint.line_to(p, x1 - r, y0)
		paint.quad_to(p, x1, y0, x1, y0 + r)
	}
	paint.line_to(p, x1, y1 - r)
	paint.quad_to(p, x1, y1, x1 - r, y1)
	paint.line_to(p, x0 + r, y1)
	paint.quad_to(p, x0, y1, x0, y1 - r)
	paint.line_to(p, x0, y0 + r)
	paint.quad_to(p, x0, y0, x0 + r, y0)
	paint.close(p)
}

// Clears (to transparent) what `p` covers, widened by `width` when it is not 0.
@(private = "file")
cut :: proc(c: ^paint.Canvas, p: paint.Path, width: f32 = 0) {
	if width > 0 {
		ring := paint.widen(p, {width = width, join = .Round})
		defer paint.path_destroy(&ring)
		paint.set_clip(c, ring)
	} else {
		paint.set_clip(c, p)
	}
	paint.clear(c)
	paint.reset_clip(c)
}

// A shape with its gradient from `y0` to `y1` and an edge inside its outline.
@(private = "file")
shape :: proc(c: ^paint.Canvas, p: paint.Path, y0, y1: f32, top, bottom, edge: u32) {
	paint.fill(c, p, paint.linear({0, y0}, {0, y1}, paint.hex(top), paint.hex(bottom)))
	paint.set_clip(c, p)   // (the edge inside the outline only: the silhouette keeps its size)
	paint.stroke(c, p, {width = LOGO_EDGE * 2, join = .Round}, paint.solid(paint.hex(edge, 200)))
	paint.reset_clip(c)
}

// 2: everything (64 px and up); 1: two lines of text, wider (32 to 48); 0: no line (16 to 24).
detail_for :: proc(size: int) -> int { return size <= 24 ? 0 : size <= 48 ? 1 : 2 }

logo_draw :: proc(size: int, detail: int) -> paint.Canvas {
	c := paint.canvas_make(size, size)
	k := f32(size) / LOGO_UNITS
	c.transform = paint.scale(paint.IDENTITY, k, k)

	// the sheet behind, turned a little
	back: paint.Path
	defer paint.path_destroy(&back)
	sheet_path(&back, 120, 64, 360, 384, 0, 28)
	paint.path_transform(&back, paint.rotate_at(paint.IDENTITY, -10, 240, 224))
	shape(&c, back, 40, 410, BACK_TOP, BACK_BOTTOM, BACK_EDGE)

	// the front sheet, a gap around it
	FOLD :: 96.0
	x0, y0, x1, y1 :: f32(152), f32(112), f32(408), f32(456)
	front: paint.Path
	defer paint.path_destroy(&front)
	sheet_path(&front, x0, y0, x1, y1, FOLD, 28)
	cut(&c, front, LOGO_GAP * 2)
	shape(&c, front, y0, y1, FRONT_TOP, FRONT_BOTTOM, FRONT_EDGE)

	// the folded corner: lighter, over the cut
	fold: paint.Path
	defer paint.path_destroy(&fold)
	paint.move_to(&fold, x1 - FOLD, y0)
	paint.line_to(&fold, x1, y0 + FOLD)
	paint.line_to(&fold, x1 - FOLD + 22, y0 + FOLD)
	paint.quad_to(&fold, x1 - FOLD, y0 + FOLD, x1 - FOLD, y0 + FOLD - 22)
	paint.close(&fold)
	shape(&c, fold, y0, y0 + FOLD, FOLD_TOP, FOLD_BOTTOM, FRONT_EDGE)

	// the lines of the text, cut out (fewer and thicker when the picture is small)
	if detail > 0 {
		lines: paint.Path
		defer paint.path_destroy(&lines)
		if detail == 2 {
			widths := [3]f32{184, 184, 116}
			for w, i in widths { paint.round_rect(&lines, 200, 256 + f32(i) * 58, w, 28, 14) }
		} else {
			widths := [2]f32{184, 120}
			for w, i in widths { paint.round_rect(&lines, 196, 268 + f32(i) * 84, w, 44, 22) }
		}
		cut(&c, lines)
	}
	return c
}

// The picture at `size`: drawn large, then shrunk in steps the cubic filter keeps clean.
logo_render :: proc(size: int) -> paint.Canvas {
	n := size
	for n < LOGO_MASTER { n *= LOGO_SHRINK_STEP }
	c := logo_draw(n, detail_for(size))
	for n > size {
		next := max(n / LOGO_SHRINK_STEP, size)
		small := paint.resize(c, next, next)
		paint.canvas_destroy(&c)
		c, n = small, next
	}
	return c
}

run_logo :: proc(args: []string) -> int {
	master := logo_render(LOGO_MASTER)
	defer paint.canvas_destroy(&master)
	path := fmt.tprintf("%s/logo.png", LOGO_DIR)
	if !paint.write_png(master, path) { fmt.eprintfln("papiertool: %s cannot be written", path); return 1 }
	fmt.printfln("wrote %s", path)
	for size in LOGO_SIZES {
		c := logo_render(size)
		defer paint.canvas_destroy(&c)
		p := fmt.tprintf("%s/logo_%d.png", LOGO_DIR, size)
		if !paint.write_png(c, p) { fmt.eprintfln("papiertool: %s cannot be written", p); return 1 }
		fmt.printfln("wrote %s", p)
	}
	// the project's picture (.project/image.png, 512 px): what the repository and opencode's sessions of it show
	project := logo_render(PROJECT_IMAGE_SIZE)
	defer paint.canvas_destroy(&project)
	_ = os.make_directory_all(".project")
	if !paint.write_png(project, PROJECT_IMAGE) { fmt.eprintfln("papiertool: %s cannot be written", PROJECT_IMAGE); return 1 }
	fmt.printfln("wrote %s", PROJECT_IMAGE)
	return 0
}

PROJECT_IMAGE      :: ".project/image.png"
PROJECT_IMAGE_SIZE :: 512
