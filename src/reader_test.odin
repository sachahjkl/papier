#+build !windows
package papier

// The reader on a store of a temporary folder, with no window: what it puts in its mailbox is taken and applied here by
// the window's rules (view_fits), as app_follow_reader does.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"
import "gt:fsx"
import syntax "gt:syntax"
import "history"

// The list's first view, a query's results, a reload's list and view: they come.
@(test)
the_list_comes_with_its_entries_and_pins :: proc(t: ^testing.T) {
	store, dir := reader_test_store(t, "list")
	defer reader_test_store_free(&store, dir)
	_, _ = history.add(&store, reader_test_text("alpha"), 0, .Text, "alpha", 1)
	b, _ := history.add(&store, reader_test_text("beta"), 0, .Text, "beta", 2)
	history.add(&store, reader_test_text("gamma"), 0, .Text, "gamma", 3)
	history.set_pinned(&store, b, true)

	r: Reader
	reader_start(&r, nil, dir)
	defer reader_stop(&r)
	s: Shown
	defer shown_free(&s)
	testing.expect(t, shown_wait_view(&s, &r), "the first view comes")
	testing.expect_value(t, len(s.list.entries), 3)
	testing.expect_value(t, s.list.pinned, 1)
	testing.expect_value(t, len(s.ids), 3)
	testing.expect_value(t, s.list.entries[s.list.at[b]].id, b)

	reader_reload(&r, 5)
	testing.expect(t, shown_wait(&s, &r, proc(s: ^Shown) -> bool { return s.list.version == 5 }), "a reload brings its list")
	testing.expect_value(t, len(s.list.entries), 3)
}

// Two queries sent at once: only the newest one's view is applied.
@(test)
the_newest_query_wins :: proc(t: ^testing.T) {
	store, dir := reader_test_store(t, "query")
	defer reader_test_store_free(&store, dir)
	history.add(&store, reader_test_text("alpha one"), 0, .Text, "alpha one", 1)
	b, _ := history.add(&store, reader_test_text("beta two"), 0, .Text, "beta two", 2)

	r: Reader
	reader_start(&r, nil, dir)
	defer reader_stop(&r)
	s: Shown
	defer shown_free(&s)
	testing.expect(t, shown_wait_view(&s, &r), "the first view comes")
	clear(&s.applied)
	s.seq += 1
	reader_query(&r, s.seq, "alpha", .All, false)
	s.seq += 1
	reader_query(&r, s.seq, "beta", .All, false)
	testing.expect(t, shown_wait_view(&s, &r), "the newest view comes")
	testing.expect_value(t, len(s.ids), 1)
	if len(s.ids) == 1 { testing.expect_value(t, s.ids[0], b) }
	for seq in s.applied { testing.expect_value(t, seq, s.seq) }
}

// A query, then a reload that brings an entry it matches: the view applied is the new list's, the entry in it.
@(test)
a_view_is_never_of_another_list :: proc(t: ^testing.T) {
	store, dir := reader_test_store(t, "reload")
	defer reader_test_store_free(&store, dir)
	history.add(&store, reader_test_text("delta old"), 0, .Text, "delta old", 1)

	r: Reader
	reader_start(&r, nil, dir)
	defer reader_stop(&r)
	s: Shown
	defer shown_free(&s)
	testing.expect(t, shown_wait_view(&s, &r), "the first view comes")
	s.seq += 1
	reader_query(&r, s.seq, "delta", .All, false)
	added, _ := history.add(&store, reader_test_text("delta new"), 0, .Text, "delta new", 2)
	reader_reload(&r, 1)
	testing.expect(t, shown_wait(&s, &r, proc(s: ^Shown) -> bool { return s.list.version == 1 && s.applied_seq == s.seq }), "the new list comes with its view")
	testing.expect_value(t, len(s.ids), 2)
	testing.expect(t, slice.contains(s.ids[:], added), "the new entry is in the view")
	testing.expect_value(t, s.view_serial, s.list.serial)
	// (each row is the list's entry of the same id)
	for id, row in s.ids { testing.expect_value(t, s.list.entries[s.shown[row]].id, id) }
}

// An entry forgotten while a query waits: no view computed after the forget holds it.
@(test)
a_forgotten_entry_stays_out :: proc(t: ^testing.T) {
	store, dir := reader_test_store(t, "forget")
	defer reader_test_store_free(&store, dir)
	gone, _ := history.add(&store, reader_test_text("item one"), 0, .Text, "item one", 1)
	history.add(&store, reader_test_text("item two"), 0, .Text, "item two", 2)

	r: Reader
	reader_start(&r, nil, dir)
	defer reader_stop(&r)
	s: Shown
	defer shown_free(&s)
	testing.expect(t, shown_wait_view(&s, &r), "the first view comes")
	s.seq += 1
	reader_query(&r, s.seq, "item", .All, false)
	s.seq += 1
	s.watch_from, s.watch_id = s.seq, gone
	reader_forget(&r, gone, s.seq)
	testing.expect(t, shown_wait_view(&s, &r), "the view after the forget comes")
	testing.expect(t, !s.watched_seen, "no view after the forget holds the entry")
	testing.expect(t, !slice.contains(s.ids[:], gone), "the entry is not shown")
	_, in_list := s.list.at[gone]
	testing.expect(t, !in_list, "nor in the list")
	testing.expect_value(t, len(s.ids), 1)
}

// The selected entry's content: a text with its QR text and its code's language; rich text without its tags.
@(test)
an_entry_is_loaded_beside_the_window :: proc(t: ^testing.T) {
	store, dir := reader_test_store(t, "load")
	defer reader_test_store_free(&store, dir)
	code := "#!/usr/bin/env python3\nprint('hi')\n"
	text_id, _ := history.add(&store, reader_test_text(code), 0, .Text, code, 1)
	rich := []history.Rep_Data{{HTML_MIME, transmute([]u8)string("<p>Hello <b>world</b></p>")}}
	html_id, _ := history.add(&store, rich, 0, .Html, "Hello world", 2)

	r: Reader
	reader_start(&r, nil, dir)
	defer reader_stop(&r)
	s: Shown
	defer shown_free(&s)
	testing.expect(t, shown_wait_view(&s, &r), "the first view comes")

	e := &s.list.entries[s.list.at[text_id]]
	reader_load(&r, e.id, e.key)
	testing.expect(t, shown_wait_loaded(&s, &r, e.id), "the text comes")
	testing.expect(t, s.loaded.ok)
	testing.expect_value(t, s.loaded.view_text, code)
	testing.expect_value(t, s.loaded.text, code)
	testing.expect_value(t, s.loaded.qr, "#!/usr/bin/env python3\nprint('hi')")
	python, _ := syntax.language("python")
	testing.expect(t, s.loaded.has_code, "a language is found")
	testing.expect_value(t, s.loaded.code.label, python.label)

	h := &s.list.entries[s.list.at[html_id]]
	reader_load(&r, h.id, h.key)
	testing.expect(t, shown_wait_loaded(&s, &r, h.id), "the rich text comes")
	testing.expect_value(t, s.loaded.view_text, "Hello world")
	testing.expect_value(t, s.loaded.text, "Hello world")
	testing.expect(t, !s.loaded.has_code)
}

// What a text is decides how the preview shows it: Markdown rendered (its doc read), a diff in its lines (its files'
// language found), code in its language, prose plain.
@(test)
the_preview_knows_what_a_text_is :: proc(t: ^testing.T) {
	store, dir := reader_test_store(t, "form")
	defer reader_test_store_free(&store, dir)
	MARKDOWN :: "# Release notes\n\nThe **reader** now shows *Markdown*.\n\n- one item\n- another item\n\n```odin\nx := 1\n```\n\nSee [the docs](https://example.org/docs).\n"
	PATCH :: "diff --git a/src/app.odin b/src/app.odin\nindex 1111111..2222222 100644\n--- a/src/app.odin\n+++ b/src/app.odin\n@@ -1,3 +1,3 @@\n package papier\n-old :: proc() {}\n+new :: proc() {}\n import \"core:fmt\"\n"
	CODE :: "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfor i in 0 ..< 3 {\n\t\tfmt.println(i)\n\t}\n}\n"
	PROSE :: "The quick brown fox jumps over the lazy dog, then it rests under a tree until the evening comes."
	texts := [4]string{MARKDOWN, PATCH, CODE, PROSE}
	ids: [4]u64
	for text, i in texts { ids[i], _ = history.add(&store, reader_test_text(text), 0, .Text, text, i64(i + 1)) }

	r: Reader
	reader_start(&r, nil, dir)
	defer reader_stop(&r)
	s: Shown
	defer shown_free(&s)
	testing.expect(t, shown_wait_view(&s, &r), "the first view comes")
	load :: proc(t: ^testing.T, s: ^Shown, r: ^Reader, id: u64) -> bool {
		e := &s.list.entries[s.list.at[id]]
		reader_load(r, e.id, e.key)
		ok := shown_wait_loaded(s, r, e.id)
		testing.expect(t, ok, "the text comes")
		return ok
	}

	if load(t, &s, &r, ids[0]) {
		testing.expect_value(t, s.loaded.form, Preview_Form.Markdown)
		testing.expect(t, s.loaded.markdown != nil && s.loaded.markdown.read, "its doc is read with the answer")
		testing.expect_value(t, s.loaded.source, MARKDOWN)
	}
	if load(t, &s, &r, ids[1]) {
		testing.expect_value(t, s.loaded.form, Preview_Form.Diff)
		testing.expect(t, s.loaded.diff != nil && s.loaded.diff.added == 1 && s.loaded.diff.removed == 1, "its doc is read with the answer")
		testing.expect(t, s.loaded.has_code, "its files' language is found")
		testing.expect_value(t, language_name(s.loaded.code), "odin")
	}
	if load(t, &s, &r, ids[2]) {
		testing.expect_value(t, s.loaded.form, Preview_Form.Code)
		testing.expect(t, s.loaded.has_code)
		testing.expect_value(t, language_name(s.loaded.code), "odin")
	}
	if load(t, &s, &r, ids[3]) {
		testing.expect_value(t, s.loaded.form, Preview_Form.Plain)
		testing.expect(t, !s.loaded.has_code)
	}
}

////////////////////////////////
// What the tests share

// What the window would show: the list, the one that waits for its view, the rows, the last entry loaded.
@(private = "file")
Shown :: struct {
	list:         History_List,
	next:         History_List,
	has_next:     bool,
	seq:          u64,              // the newest query sent
	shown:        [dynamic]int,
	ids:          [dynamic]u64,
	view_serial:  u64,              // the list the rows are of
	applied_seq:  u64,              // the seq of the last view applied
	applied:      [dynamic]u64,     // the seqs of the views applied, in order
	has_view:     bool,             // a view was applied since the last wait
	loaded:       Loaded_Entry,
	watch_from:   u64,              // views of this seq or later must not hold watch_id (0: none watched)
	watch_id:     u64,
	watched_seen: bool,
}

@(private = "file")
shown_free :: proc(s: ^Shown) {
	history_list_free(&s.list)
	if s.has_next { history_list_free(&s.next) }
	delete(s.shown)
	delete(s.ids)
	delete(s.applied)
	loaded_free(&s.loaded)
}

// One take of the mailbox, applied by the window's rules. True when something came.
@(private = "file")
shown_take :: proc(s: ^Shown, r: ^Reader) -> bool {
	res := reader_take(r)
	defer reader_results_free(&res)
	came := res.has_list || res.has_view || res.has_loaded || len(res.done) > 0
	if res.has_list {
		if s.has_next { history_list_free(&s.next) }
		s.next, s.has_next = res.list, true
		res.list, res.has_list = {}, false
	}
	if res.has_view {
		v := &res.view
		if s.watch_from != 0 && v.seq >= s.watch_from && slice.contains(v.ids[:], s.watch_id) { s.watched_seen = true }
		if fits, on_next := view_fits(v^, s.seq, s.list.serial, s.next.serial, s.has_next); fits {
			if on_next {
				history_list_free(&s.list)
				s.list, s.next, s.has_next = s.next, {}, false
			}
			delete(s.shown)
			delete(s.ids)
			s.shown, s.ids = v.shown, v.ids
			v.shown, v.ids = nil, nil
			s.view_serial, s.applied_seq, s.has_view = v.serial, v.seq, true
			append(&s.applied, v.seq)
		}
	}
	if res.has_loaded {
		loaded_free(&s.loaded)
		s.loaded, res.loaded, res.has_loaded = res.loaded, {}, false
	}
	return came
}

// Takes until `done(s)`, for a bounded time.
@(private = "file")
shown_wait :: proc(s: ^Shown, r: ^Reader, done: proc(s: ^Shown) -> bool) -> bool {
	for _ in 0 ..< 1000 {
		shown_take(s, r)
		if done(s) { return true }
		time.sleep(2 * time.Millisecond)
	}
	return false
}

// Takes until the view of the newest query is applied.
@(private = "file")
shown_wait_view :: proc(s: ^Shown, r: ^Reader) -> bool {
	s.has_view = false
	return shown_wait(s, r, proc(s: ^Shown) -> bool { return s.has_view && s.applied_seq == s.seq })
}

// Takes until the content of entry `id` comes.
@(private = "file")
shown_wait_loaded :: proc(s: ^Shown, r: ^Reader, id: u64) -> bool {
	for _ in 0 ..< 1000 {
		shown_take(s, r)
		if s.loaded.id == id { return true }
		time.sleep(2 * time.Millisecond)
	}
	return false
}

@(private = "file")
reader_test_store :: proc(t: ^testing.T, name: string) -> (s: history.Store, dir: string) {
	dir = fmt.aprintf("%s/papier_test_reader_%s_%d", fsx.temp_dir(context.temp_allocator), name, os.get_pid())
	fsx.remove_tree(dir)
	ok, why := history.open(&s, dir)
	testing.expectf(t, ok, "the store opens: %s", why)
	return
}

@(private = "file")
reader_test_store_free :: proc(s: ^history.Store, dir: string) {
	history.close(s)
	fsx.remove_tree(dir)
	delete(dir)
}

@(private = "file")
reader_test_text :: proc(text: string) -> []history.Rep_Data {
	r := make([]history.Rep_Data, 1, context.temp_allocator)
	r[0] = {TEXT_MIME, transmute([]u8)text}
	return r
}
