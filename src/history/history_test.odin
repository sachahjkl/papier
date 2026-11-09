package history

import "core:fmt"
import "core:os"
import "core:testing"
import "gt:fsx"

@(private = "file")
temp_store :: proc(t: ^testing.T, name: string) -> (s: Store, dir: string) {
	dir = fmt.aprintf("%s/papier_test_%s_%d", fsx.temp_dir(context.temp_allocator), name, os.get_pid())
	fsx.remove_tree(dir)
	ok, why := open(&s, dir)
	testing.expectf(t, ok, "the store opens: %s", why)
	return
}

@(private = "file")
text :: proc(s: string) -> []Rep_Data { r := make([]Rep_Data, 1, context.temp_allocator); r[0] = {"text/plain;charset=utf-8", transmute([]u8)s}; return r }

// The same text copied twice is one entry, at the top, with the id it had; another text is a new entry.
@(test)
a_copy_already_there_moves_to_the_top :: proc(t: ^testing.T) {
	s, dir := temp_store(t, "dedup")
	defer { close(&s); fsx.remove_tree(dir); delete(dir) }
	a, _ := add(&s, text("alpha"), 0, .Text, "alpha", 1)
	b, _ := add(&s, text("beta"), 0, .Text, "beta", 2)
	testing.expect(t, a != b)
	again, ok := add(&s, text("alpha"), 0, .Text, "alpha", 3)
	testing.expect(t, ok)
	testing.expect_value(t, again, a)
	testing.expect_value(t, len(s.entries), 2)
	testing.expect_value(t, s.entries[0].id, a)
	testing.expect_value(t, s.entries[0].time_ms, i64(3))
}

// The database read back gives the same entries, previews with tabs and new lines included.
@(test)
the_database_reads_back :: proc(t: ^testing.T) {
	s, dir := temp_store(t, "index")
	defer { fsx.remove_tree(dir); delete(dir) }
	add(&s, text("line one\n\tline two \\ end"), 0, .Text, "line one\n\tline two \\ end", 10)
	reps := []Rep_Data{{"text/html", transmute([]u8)string("<b>x</b>")}, {"text/plain;charset=utf-8", transmute([]u8)string("x")}}
	id, _ := add(&s, reps, 1, .Html, "x", 11)
	set_pinned(&s, id, true)
	close(&s)

	r: Store
	open(&r, dir)
	defer close(&r)
	testing.expect_value(t, len(r.entries), 2)
	testing.expect_value(t, r.entries[0].id, id)
	testing.expect(t, r.entries[0].pinned)
	testing.expect_value(t, r.entries[0].kind, Kind.Html)
	testing.expect_value(t, len(r.entries[0].reps), 2)
	testing.expect_value(t, r.entries[0].reps[0].mime, "text/html")
	testing.expect_value(t, r.entries[1].preview, "line one\n\tline two \\ end")
	data := blob_read(&r, r.entries[0].reps[0].hash, context.temp_allocator)
	testing.expect_value(t, string(data), "<b>x</b>")
	// a new entry after a reload takes an id that was never given
	next, _ := add(&r, text("new"), 0, .Text, "new", 12)
	testing.expect(t, next > id)
}

// trim keeps the pinned entries whatever the limits, and collect deletes the blobs nothing names any more.
@(test)
trim_keeps_pinned_entries_and_collect_frees_blobs :: proc(t: ^testing.T) {
	s, dir := temp_store(t, "trim")
	defer { close(&s); fsx.remove_tree(dir); delete(dir) }
	old, _ := add(&s, text("old pinned"), 0, .Text, "old pinned", 0)
	set_pinned(&s, old, true)
	for i in 1 ..= 5 { _, ok := add(&s, text(fmt.tprintf("item %d", i)), 0, .Text, "", i64(i)); testing.expect(t, ok, "an entry with no preview is added") }
	testing.expect_value(t, trim(&s, 2, 0, 10), 3)
	testing.expect_value(t, len(s.entries), 3)
	testing.expect(t, find(&s, old) >= 0, "the pinned entry stays")
	testing.expect_value(t, collect(&s), 3)
	testing.expect_value(t, blob_count(&s), 3)
	// by age: everything older than 3 ms at time 10, but the pinned one
	testing.expect_value(t, trim(&s, 0, 3, 10), 2)
	testing.expect_value(t, len(s.entries), 1)
}

// A preview is cut at a character boundary.
@(test)
a_preview_is_cut_between_characters :: proc(t: ^testing.T) {
	long: [PREVIEW_MAX_BYTES + 8]u8
	for &c in long { c = 'a' }
	long[PREVIEW_MAX_BYTES - 1], long[PREVIEW_MAX_BYTES] = 0xC3, 0xA9   // "é" across the limit
	p := clip_preview(string(long[:]))
	testing.expect_value(t, len(p), PREVIEW_MAX_BYTES - 1)
}

// An edit keeps the entry's id, place and pin; an entry that already held the new text goes, as a copy would merge them.
@(test)
an_edit_keeps_the_entry :: proc(t: ^testing.T) {
	s, dir := temp_store(t, "replace")
	defer { close(&s); fsx.remove_tree(dir); delete(dir) }
	a, _ := add(&s, text("alpha"), 0, .Text, "alpha", 1)
	b, _ := add(&s, text("beta"), 0, .Text, "beta", 2)
	c, _ := add(&s, text("gamma"), 0, .Text, "gamma", 3)
	set_pinned(&s, b, true)
	testing.expect(t, replace(&s, b, text("beta, edited"), 0, .Text, "beta, edited"))
	testing.expect_value(t, len(s.entries), 3)
	testing.expect_value(t, s.entries[1].id, b)
	testing.expect(t, s.entries[1].pinned)
	testing.expect_value(t, s.entries[1].preview, "beta, edited")
	testing.expect_value(t, string(blob_read(&s, s.entries[1].reps[0].hash, context.temp_allocator)), "beta, edited")
	// the text of another entry: that one goes
	testing.expect(t, replace(&s, b, text("alpha"), 0, .Text, "alpha"))
	testing.expect_value(t, len(s.entries), 2)
	testing.expect(t, find(&s, a) < 0, "the other entry with the same text went")
	testing.expect_value(t, s.entries[0].id, c)
	testing.expect(t, !replace(&s, 999, text("x"), 0, .Text, "x"), "an entry that is not there")
}

// The search reads the whole text, past what the list keeps, case ignored; a word too short for the index says nothing.
@(test)
the_search_reads_the_whole_text :: proc(t: ^testing.T) {
	s, dir := temp_store(t, "search")
	defer { close(&s); fsx.remove_tree(dir); delete(dir) }
	long := make([]u8, PREVIEW_MAX_BYTES * 2, context.temp_allocator)
	for &c in long { c = 'x' }
	body := fmt.tprintf("%s Needle at the end", string(long))
	a, _ := add(&s, text(body), 0, .Text, body, 1)
	add(&s, text("other words"), 0, .Text, "other words", 2)
	ids, used := search(&s, {"needle", "end"})
	testing.expect(t, used)
	testing.expect_value(t, len(ids), 1)
	testing.expect(t, a in ids, "found past the preview")
	none, _ := search(&s, {"needle", "words"})
	testing.expect_value(t, len(none), 0)
	_, short := search(&s, {"at"})
	testing.expect(t, !short, "two letters: the index is not used")
	// a removed entry is no more found
	remove(&s, a)
	gone, _ := search(&s, {"needle"})
	testing.expect_value(t, len(gone), 0)
}

// Another connection (the window) sees each change once it reloads: every change is written at once.
@(test)
another_connection_sees_the_changes :: proc(t: ^testing.T) {
	w, dir := temp_store(t, "two")
	defer { close(&w); fsx.remove_tree(dir); delete(dir) }
	r: Store
	ok, _ := open(&r, dir)
	testing.expect(t, ok)
	defer close(&r)
	id, _ := add(&w, text("shared"), 0, .Text, "shared", 1)
	reload(&r)
	testing.expect_value(t, len(r.entries), 1)
	testing.expect_value(t, r.entries[0].id, id)
	testing.expect_value(t, string(blob_read_in(dir, r.entries[0].reps[0].hash, context.temp_allocator)), "shared")
	set_pinned(&w, id, true)
	reload(&r)
	testing.expect(t, r.entries[0].pinned)
}
