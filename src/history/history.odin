// Package history: the clipboard entries papier shows, newest first (Store.entries), and the bytes of each type of each
// entry, by their hash.
//
//   Linux    papier keeps them: a SQLite database it writes (store_linux.odin).
//   Windows  the system keeps them: its clipboard history, read through the Windows Runtime (store_windows.odin).
//
// An entry has a key: the hash of its main representation (the text of a text copy, the bytes of an image).
package history

import "core:hash/xxhash"
import "core:strings"

// What an entry keeps of its text for the list: a line of it, and the first words of what the search finds.
PREVIEW_MAX_BYTES :: 1024
// The shortest word the full-text index finds (a trigram); a shorter one is looked for in the previews.
SEARCH_WORD_MIN :: 3

Kind :: enum u8 { Text, Html, Image, Files, Other }

KIND_NAMES := [Kind]string{.Text = "text", .Html = "html", .Image = "image", .Files = "files", .Other = "other"}

// One representation of an entry: its MIME type, the hash that names its bytes, their size.
Rep :: struct {
	mime: string,
	hash: u64,
	size: int,
}

Entry :: struct {
	id:      u64,
	time_ms: i64,      // Unix time of the last copy
	pinned:  bool,     // kept by trim, whatever the limits
	kind:    Kind,
	key:     u64,      // the hash of the main representation: what makes two copies the same
	preview: string,   // what the list shows (PREVIEW_MAX_BYTES at most)
	reps:    []Rep,
}

// What a copy brings: one MIME type and its bytes.
Rep_Data :: struct {
	mime: string,
	data: []u8,
}

hash_bytes :: proc(b: []u8) -> u64 { return xxhash.XXH3_64_default(b) }

@(private)
clear_entries :: proc(s: ^Store) {
	for &e in s.entries { entry_free(&e) }
	clear(&s.entries)
}

@(private)
entry_free :: proc(e: ^Entry) {
	delete(e.preview)
	for r in e.reps { delete(r.mime) }
	delete(e.reps)
	e^ = {}
}

// Where the entry `id` is in the list, -1 when it is not.
find :: proc(s: ^Store, id: u64) -> int {
	for e, i in s.entries { if e.id == id { return i } }
	return -1
}

// Takes the entry `id` out of this list only (the window shows a removal at once; the watcher makes it).
forget :: proc(s: ^Store, id: u64) {
	at := find(s, id)
	if at < 0 { return }
	entry_free(&s.entries[at])
	ordered_remove(&s.entries, at)
}

find_key :: proc(s: ^Store, key: u64) -> int {
	for e, i in s.entries { if e.key == key { return i } }
	return -1
}

// The first representation of `e` whose MIME type is `mime` (or starts with it, for "image/"), -1 when none.
rep_find :: proc(e: Entry, mime: string) -> int {
	for r, i in e.reps { if r.mime == mime || (strings.has_suffix(mime, "/") && strings.has_prefix(r.mime, mime)) { return i } }
	return -1
}

// The total bytes an entry holds.
entry_size :: proc(e: Entry) -> (n: int) {
	for r in e.reps { n += r.size }
	return
}

kind_of :: proc(name: string) -> (Kind, bool) {
	for n, k in KIND_NAMES { if n == name { return k, true } }
	return .Other, false
}

// The first PREVIEW_MAX_BYTES of `text`, cut at a character boundary.
clip_preview :: proc(text: string) -> string {
	if len(text) <= PREVIEW_MAX_BYTES { return text }
	n := PREVIEW_MAX_BYTES
	for n > 0 && text[n] & 0xC0 == 0x80 { n -= 1 }   // (not inside a UTF-8 sequence)
	return text[:n]
}
