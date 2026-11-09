package papier

// What the window remembers from one run to the next: its size, its place (X11 only: a Wayland client cannot place its
// window), the width of the list. A few lines of text in $XDG_STATE_HOME/papier/window, written when the window hides
// and when papier quits.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "gt:fsx"

Window_State :: struct {
	size:   [2]int,    // logical pixels (0: the preferences' size)
	place:  [2]int,    // the window's top left corner, screen pixels
	placed: bool,      // `place` was read (X11)
	split:  f32,       // the list's width, logical pixels (0: a share of the window)
}


// The state in `text` ("size w h", "place x y", "split w": one per line, any order, unknown lines skipped).
state_parse :: proc(text: string) -> (s: Window_State) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 { continue }
		switch {
		case f[0] == "size" && len(f) == 3:
			w, ok1 := strconv.parse_int(f[1])
			h, ok2 := strconv.parse_int(f[2])
			if ok1 && ok2 && w > 0 && h > 0 { s.size = {w, h} }
		case f[0] == "place" && len(f) == 3:
			x, ok1 := strconv.parse_int(f[1])
			y, ok2 := strconv.parse_int(f[2])
			if ok1 && ok2 { s.place, s.placed = {x, y}, true }
		case f[0] == "split" && len(f) == 2:
			if v, ok := strconv.parse_f32(f[1]); ok && v > 0 { s.split = v }
		}
	}
	return
}

state_format :: proc(s: Window_State, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if s.size != {} { fmt.sbprintf(&b, "size %d %d\n", s.size.x, s.size.y) }
	if s.placed { fmt.sbprintf(&b, "place %d %d\n", s.place.x, s.place.y) }
	if s.split > 0 { fmt.sbprintf(&b, "split %.0f\n", s.split) }
	return strings.to_string(b)
}

state_load :: proc() -> Window_State {
	data, ok := fsx.read_all(state_path(), context.temp_allocator)
	return ok ? state_parse(string(data)) : {}
}

state_save :: proc(s: Window_State) -> bool {
	path := state_path()
	fsx.make_dirs(path[:strings.last_index_byte(path, '/')])
	return fsx.write_atomic(path, transmute([]u8)state_format(s))
}
