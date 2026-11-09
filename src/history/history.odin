// Package history: the clipboard entries papier keeps, in one SQLite database (history.db, WAL mode).
//
//   entries  an entry: its id, the time of its last copy, its pin, its kind, its key, its preview
//   reps     its representations, in order: a MIME type, the hash of the bytes, their size
//   blobs    the bytes, by their 64-bit XXH3 hash: two copies of the same bytes share one row
//   texts    the full text of each entry (FTS5, trigram): what the search reads
//   meta     the next id
//
// The list is also in memory (Store.entries, newest first): the window reads it at each frame. Each change is one
// transaction, written at once: another connection (the window, `papier list`) reads the old list or the new one,
// never half. One process writes (the watcher); the others read, and ask it for changes.
//
// An entry has a key: the hash of its main representation (the text of a text copy, the bytes of an image). A copy whose
// key is already there moves that entry to the top instead of adding a second one.
package history

import "base:runtime"
import "core:hash/xxhash"
import "core:strings"
import "gt:fsx"
import "../sqlite"

DB_FILE :: "history.db"
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

Store :: struct {
	dir:     string,            // its directory (owned)
	db:      sqlite.DB,
	entries: [dynamic]Entry,   // newest first
	next_id: u64,
}

hash_bytes :: proc(b: []u8) -> u64 { return xxhash.XXH3_64_default(b) }

@(private = "file")
SCHEMA :: `
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS entries (id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, pinned INTEGER NOT NULL,
	kind INTEGER NOT NULL, key INTEGER NOT NULL, preview TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reps (entry INTEGER NOT NULL, ord INTEGER NOT NULL, mime TEXT NOT NULL, hash INTEGER NOT NULL,
	size INTEGER NOT NULL, PRIMARY KEY (entry, ord));
CREATE INDEX IF NOT EXISTS reps_hash ON reps (hash);
CREATE TABLE IF NOT EXISTS blobs (hash INTEGER PRIMARY KEY, data BLOB NOT NULL);
CREATE VIRTUAL TABLE IF NOT EXISTS texts USING fts5 (body, tokenize = 'trigram');
`

// Opens the store of `dir` (made when missing) and reads its list. ok = false, with why, when the database cannot be
// opened (no SQLite, a file that is not one).
open :: proc(s: ^Store, dir: string) -> (ok: bool, why: string) {
	fsx.make_dirs(dir)
	s.db, why = sqlite.open(strings.concatenate({dir, "/", DB_FILE}, context.temp_allocator))
	if s.db == nil { return false, why }
	s.dir = strings.clone(dir)
	if done, err := sqlite.exec(s.db, SCHEMA); !done {
		sqlite.close(s.db)
		delete(s.dir)
		s^ = {}
		return false, err
	}
	reload(s)
	return true, ""
}

close :: proc(s: ^Store) {
	clear_entries(s)
	delete(s.entries)
	sqlite.close(s.db)
	delete(s.dir)
	s^ = {}
}

// Reads the list again (another connection changed it).
reload :: proc(s: ^Store) {
	clear_entries(s)
	if q, ok := sqlite.prepare(s.db, "SELECT v FROM meta WHERE k = 'next_id'"); ok {
		if sqlite.step(q) { s.next_id = sqlite.column_u64(q, 0) }
		sqlite.finalize(q)
	}
	at := make(map[u64]int, context.temp_allocator)
	if q, ok := sqlite.prepare(s.db, "SELECT id, time_ms, pinned, kind, key, preview FROM entries ORDER BY time_ms DESC, id DESC"); ok {
		for sqlite.step(q) {
			e := Entry{
				id = sqlite.column_u64(q, 0), time_ms = sqlite.column_i64(q, 1), pinned = sqlite.column_i64(q, 2) != 0,
				kind = Kind(clamp(sqlite.column_i64(q, 3), 0, i64(max(Kind)))), key = sqlite.column_u64(q, 4),
				preview = strings.clone(sqlite.column_text(q, 5)),
			}
			at[e.id] = len(s.entries)
			append(&s.entries, e)
			s.next_id = max(s.next_id, e.id)
		}
		sqlite.finalize(q)
	}
	reps := make(map[u64][dynamic]Rep, context.temp_allocator)
	if q, ok := sqlite.prepare(s.db, "SELECT entry, mime, hash, size FROM reps ORDER BY entry, ord"); ok {
		for sqlite.step(q) {
			id := sqlite.column_u64(q, 0)
			if id not_in at { continue }
			if id not_in reps { reps[id] = make([dynamic]Rep, context.temp_allocator) }
			append(&reps[id], Rep{strings.clone(sqlite.column_text(q, 1)), sqlite.column_u64(q, 2), int(sqlite.column_i64(q, 3))})
		}
		sqlite.finalize(q)
	}
	for &e in s.entries {
		list := reps[e.id]
		e.reps = make([]Rep, len(list))
		copy(e.reps, list[:])
	}
}

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

find_key :: proc(s: ^Store, key: u64) -> int {
	for e, i in s.entries { if e.key == key { return i } }
	return -1
}

// One change of the database: done whole or not at all.
@(private)
begin :: proc(s: ^Store) -> bool { ok, _ := sqlite.exec(s.db, "BEGIN IMMEDIATE"); return ok }

@(private)
end :: proc(s: ^Store, ok: bool) -> bool {
	if ok { done, _ := sqlite.exec(s.db, "COMMIT"); if done { return true } }
	sqlite.exec(s.db, "ROLLBACK")
	return false
}

// The bytes of `reps`, stored (once each), and their representations (owned).
@(private)
store_reps :: proc(s: ^Store, reps: []Rep_Data) -> (out: []Rep, ok: bool) {
	out = make([]Rep, len(reps))
	for r, i in reps {
		h := hash_bytes(r.data)
		if !sqlite.run_sql(s.db, "INSERT OR IGNORE INTO blobs (hash, data) VALUES (?, ?)", h, r.data) {
			for o in out[:i] { delete(o.mime) }
			delete(out)
			return nil, false
		}
		out[i] = {strings.clone(r.mime), h, len(r.data)}
	}
	return out, true
}

// The rows of an entry: itself, its representations, its text. (Its old ones go first.)
@(private)
write_entry :: proc(s: ^Store, e: Entry, body: string) -> bool {
	ok := sqlite.run_sql(s.db, "INSERT OR REPLACE INTO entries (id, time_ms, pinned, kind, key, preview) VALUES (?, ?, ?, ?, ?, ?)",
		e.id, e.time_ms, e.pinned, int(e.kind), e.key, e.preview)
	ok = ok && sqlite.run_sql(s.db, "DELETE FROM reps WHERE entry = ?", e.id)
	for r, i in e.reps { ok = ok && sqlite.run_sql(s.db, "INSERT INTO reps (entry, ord, mime, hash, size) VALUES (?, ?, ?, ?, ?)", e.id, i, r.mime, r.hash, r.size) }
	ok = ok && sqlite.run_sql(s.db, "DELETE FROM texts WHERE rowid = ?", e.id)
	if body != "" { ok = ok && sqlite.run_sql(s.db, "INSERT INTO texts (rowid, body) VALUES (?, ?)", e.id, body) }
	return ok
}

@(private)
delete_entry :: proc(s: ^Store, id: u64) -> bool {
	ok := sqlite.run_sql(s.db, "DELETE FROM entries WHERE id = ?", id)
	ok = ok && sqlite.run_sql(s.db, "DELETE FROM reps WHERE entry = ?", id)
	return ok && sqlite.run_sql(s.db, "DELETE FROM texts WHERE rowid = ?", id)
}

// Adds a copy at the top. `main` is the index in `reps` of the representation that makes the key; `preview` is the
// copy's whole text (what the search reads; the list keeps its first PREVIEW_MAX_BYTES). A copy of an entry already
// there moves it to the top (pinned stays pinned) with the new representations. False when it cannot be written.
add :: proc(s: ^Store, reps: []Rep_Data, main: int, kind: Kind, preview: string, now_ms: i64) -> (id: u64, ok: bool) {
	if len(reps) == 0 || main < 0 || main >= len(reps) || !begin(s) { return 0, false }
	out, stored := store_reps(s, reps)
	if !stored { end(s, false); return 0, false }
	e := Entry{time_ms = now_ms, kind = kind, key = out[main].hash, preview = strings.clone(clip_preview(preview)), reps = out}
	at := find_key(s, e.key)
	next := s.next_id
	if at >= 0 {
		e.id, e.pinned = s.entries[at].id, s.entries[at].pinned
	} else {
		next += 1
		e.id = next
	}
	written := write_entry(s, e, preview) && sqlite.run_sql(s.db, "INSERT OR REPLACE INTO meta (k, v) VALUES ('next_id', ?)", next)
	if !end(s, written) { entry_free(&e); return 0, false }
	s.next_id = next
	if at >= 0 {
		entry_free(&s.entries[at])
		ordered_remove(&s.entries, at)
	}
	inject_at(&s.entries, 0, e)
	return e.id, true
}

// Moves the entry `id` to the top, as a new copy of it would.
touch :: proc(s: ^Store, id: u64, now_ms: i64) -> bool {
	at := find(s, id)
	if at < 0 || !sqlite.run_sql(s.db, "UPDATE entries SET time_ms = ? WHERE id = ?", now_ms, id) { return false }
	e := s.entries[at]
	e.time_ms = now_ms
	ordered_remove(&s.entries, at)
	inject_at(&s.entries, 0, e)
	return true
}

// Gives the entry `id` new representations (an edit): it keeps its id, its place and its pin. Another entry with the
// same main bytes goes, as a copy of them would merge with it. False when the entry is gone or it cannot be written.
replace :: proc(s: ^Store, id: u64, reps: []Rep_Data, main: int, kind: Kind, preview: string) -> bool {
	if len(reps) == 0 || main < 0 || main >= len(reps) || find(s, id) < 0 || !begin(s) { return false }
	out, stored := store_reps(s, reps)
	if !stored { end(s, false); return false }
	key := out[main].hash
	old := s.entries[find(s, id)]
	e := Entry{id = id, time_ms = old.time_ms, pinned = old.pinned, kind = kind, key = key, preview = strings.clone(clip_preview(preview)), reps = out}
	other := find_key(s, key)
	if other >= 0 && s.entries[other].id == id { other = -1 }
	written := write_entry(s, e, preview)
	if other >= 0 { written = written && delete_entry(s, s.entries[other].id) }
	if !end(s, written) { entry_free(&e); return false }
	if other >= 0 {
		entry_free(&s.entries[other])
		ordered_remove(&s.entries, other)
	}
	at := find(s, id)
	entry_free(&s.entries[at])
	s.entries[at] = e
	return true
}

remove :: proc(s: ^Store, id: u64) -> bool {
	at := find(s, id)
	if at < 0 || !begin(s) || !end(s, delete_entry(s, id)) { return false }
	entry_free(&s.entries[at])
	ordered_remove(&s.entries, at)
	return true
}

set_pinned :: proc(s: ^Store, id: u64, pinned: bool) -> bool {
	at := find(s, id)
	if at < 0 || !sqlite.run_sql(s.db, "UPDATE entries SET pinned = ? WHERE id = ?", pinned, id) { return false }
	s.entries[at].pinned = pinned
	return true
}

// Removes the entries `drop` says, in one change. How many went.
@(private)
remove_where :: proc(s: ^Store, drop: proc(e: Entry, kept: ^int, data: rawptr) -> bool, data: rawptr) -> (removed: int) {
	ids := make([dynamic]u64, context.temp_allocator)
	kept := 0
	for e in s.entries { if drop(e, &kept, data) { append(&ids, e.id) } }
	if len(ids) == 0 || !begin(s) { return 0 }
	ok := true
	for id in ids { ok = ok && delete_entry(s, id) }
	if !end(s, ok) { return 0 }
	for id in ids {
		at := find(s, id)
		entry_free(&s.entries[at])
		ordered_remove(&s.entries, at)
	}
	return len(ids)
}

// Removes every entry that is not pinned (all of them with `pinned_too`).
clear_all :: proc(s: ^Store, pinned_too := false) -> (removed: int) {
	all := pinned_too
	return remove_where(s, proc(e: Entry, kept: ^int, data: rawptr) -> bool { return !e.pinned || (^bool)(data)^ }, &all)
}

// Removes the entries past the limits: more than `max_entries` (0: no limit) not pinned, or older than `max_age_ms`
// (0: no limit). Pinned entries stay and do not count.
trim :: proc(s: ^Store, max_entries: int, max_age_ms: i64, now_ms: i64) -> (removed: int) {
	Limits :: struct { max_entries: int, max_age_ms, now_ms: i64 }
	l := Limits{max_entries, max_age_ms, now_ms}
	return remove_where(s, proc(e: Entry, kept: ^int, data: rawptr) -> bool {
		l := (^Limits)(data)
		if e.pinned { return false }
		too_many := l.max_entries > 0 && kept^ >= l.max_entries
		too_old := l.max_age_ms > 0 && l.now_ms - e.time_ms > l.max_age_ms
		if too_many || too_old { return true }
		kept^ += 1
		return false
	}, &l)
}

// Deletes the bytes no representation names (after a trim, a removal, a clear). Returns how many went.
collect :: proc(s: ^Store) -> (deleted: int) {
	before := blob_count(s)
	sqlite.run_sql(s.db, "DELETE FROM blobs WHERE hash NOT IN (SELECT hash FROM reps)")
	return before - blob_count(s)
}

// How many distinct bytes are stored.
blob_count :: proc(s: ^Store) -> int {
	q, ok := sqlite.prepare(s.db, "SELECT count(*) FROM blobs")
	if !ok { return 0 }
	defer sqlite.finalize(q)
	return sqlite.step(q) ? int(sqlite.column_i64(q, 0)) : 0
}

// The bytes of a representation (nil when they are gone).
blob_read :: proc(s: ^Store, hash: u64, allocator := context.allocator) -> []u8 { return read_blob(s.db, hash, allocator) }

// The bytes of a representation in the store of `dir`, through a connection of this call's own: for another thread
// than the store's (a connection is one thread's). nil when they are gone or the store cannot be opened.
blob_read_in :: proc(dir: string, hash: u64, allocator := context.allocator) -> []u8 {
	db, _ := sqlite.open(strings.concatenate({dir, "/", DB_FILE}, context.temp_allocator))
	if db == nil { return nil }
	defer sqlite.close(db)
	return read_blob(db, hash, allocator)
}

@(private)
read_blob :: proc(db: sqlite.DB, hash: u64, allocator: runtime.Allocator) -> []u8 {
	q, ok := sqlite.prepare(db, "SELECT data FROM blobs WHERE hash = ?", hash)
	if !ok { return nil }
	defer sqlite.finalize(q)
	if !sqlite.step(q) { return nil }
	b := sqlite.column_blob(q, 0)
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return out
}

// The entries whose whole text holds every word of `words` of SEARCH_WORD_MIN letters or more (case ignored), by id.
// `used` = false when no word is that long: the index says nothing then.
search :: proc(s: ^Store, words: []string, allocator := context.temp_allocator) -> (ids: map[u64]bool, used: bool) {
	b := strings.builder_make(context.temp_allocator)
	for w in words {
		if len(w) < SEARCH_WORD_MIN { continue }
		if used { strings.write_string(&b, " AND ") }
		used = true
		// a phrase of one word: its quotes doubled (FTS5's string)
		strings.write_byte(&b, '"')
		for i in 0 ..< len(w) { if w[i] == '"' { strings.write_byte(&b, '"') }; strings.write_byte(&b, w[i]) }
		strings.write_byte(&b, '"')
	}
	ids = make(map[u64]bool, allocator)
	if !used { return }
	q, ok := sqlite.prepare(s.db, "SELECT rowid FROM texts WHERE texts MATCH ?", strings.to_string(b))
	if !ok { return }
	defer sqlite.finalize(q)
	for sqlite.step(q) { ids[sqlite.column_u64(q, 0)] = true }
	return
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
