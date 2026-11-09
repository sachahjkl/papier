package papier

import "core:testing"

// The window's state reads back what was written; unknown, malformed and partial lines are left out.
@(test)
the_window_state_reads_back :: proc(t: ^testing.T) {
	s := Window_State{size = {900, 560}, place = {-40, 120}, placed = true, split = 412}
	testing.expect_value(t, state_parse(state_format(s)), s)
	testing.expect_value(t, state_parse("size 800 600\n"), Window_State{size = {800, 600}})
	testing.expect_value(t, state_parse("size 0 600\nsplit -3\nplace 1\nnonsense here\nsize a b\n"), Window_State{})
	testing.expect_value(t, state_format(Window_State{}), "")
}
