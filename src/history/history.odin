// Package history: the clipboard entries papier keeps, on disk.
//
// One directory holds an index and the blobs. A blob is the bytes of one representation (one MIME type of one copy),
// named by the 64-bit XXH3 hash of its bytes: two copies of the same bytes share one file, and a blob is written once.
// The index lists the entries, newest first, each with its representations; it is rewritten whole and renamed over the
// old one (fsx.write_atomic), so a reader (the picker, another process) sees the old list or the new one, never half.
// One process writes (the daemon); the others ask it to.
//
// An entry has a key: the hash of its main representation (the text of a text copy, the pixels file of an image). A
// copy whose key is already there moves that entry to the top instead of adding a second one.
package history

import "core:fmt"
import "core:hash/xxhash"
import "core:strconv"
import "core:strings"
import "gt:fsx"

INDEX_FILE    :: "index"
BLOBS_DIR     :: "blobs"
INDEX_MAGIC   :: "papier-index 1"
// What the index keeps of a text: enough for a line of the list and for the search.
PREVIEW_MAX_BYTES :: 1024

Kind :: enum u8 { Text, Html, Image, Files, Other }

KIND_NAMES := [Kind]string{.Text = "text", .Html = "html", .Image = "image", .Files = "files", .Other = "other"}

// One representation of an entry: its MIME type, the hash that names its blob, its size.
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
	preview: string,   // what the list shows and the search reads (PREVIEW_MAX_BYTES at most)
	reps:    []Rep,
}

// What a copy brings: one MIME type and its bytes.
Rep_Data :: struct {
	mime: string,
	data: []u8,
}

Store :: struct {
	dir:     string,
	entries: [dynamic]Entry,   // newest first
	next_id: u64,
}

hash_bytes :: proc(b: []u8) -> u64 { return xxhash.XXH3_64_default(b) }

index_path :: proc(s: ^Store, allocator := context.temp_allocator) -> string {
	return strings.concatenate({s.dir, "/", INDEX_FILE}, allocator)
}

blob_path :: proc(s: ^Store, hash: u64, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%s/%016x", s.dir, BLOBS_DIR, hash, allocator = allocator)
}

// Opens the store of `dir` (made when missing) and reads its index. A missing or unreadable index is an empty history.
open :: proc(s: ^Store, dir: string) {
	s.dir = strings.clone(dir)
	fsx.make_dirs(strings.concatenate({dir, "/", BLOBS_DIR}, context.temp_allocator))
	reload(s)
}

close :: proc(s: ^Store) {
	clear_entries(s)
	delete(s.entries)
	delete(s.dir)
	s^ = {}
}

// Reads the index again (another process wrote it).
reload :: proc(s: ^Store) {
	clear_entries(s)
	data, ok := fsx.read_all(index_path(s), context.temp_allocator)
	if !ok { return }
	parse_index(s, string(data))
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

// Adds a copy at the top. `main` is the index in `reps` of the representation that makes the key. The blobs are
// written first, then the entry is listed: an entry never names a blob that is not there. A copy of an entry already
// there moves it to the top (pinned stays pinned) with the new representations. False when a blob cannot be written.
add :: proc(s: ^Store, reps: []Rep_Data, main: int, kind: Kind, preview: string, now_ms: i64) -> (id: u64, ok: bool) {
	if len(reps) == 0 || main < 0 || main >= len(reps) { return 0, false }
	out := make([]Rep, len(reps))
	for r, i in reps {
		h := hash_bytes(r.data)
		path := blob_path(s, h)
		if _, _, there := fsx.stat(path); !there {
			if !fsx.write_atomic(path, r.data) {
				for o in out[:i] { delete(o.mime) }
				delete(out)
				return 0, false
			}
		}
		out[i] = {strings.clone(r.mime), h, len(r.data)}
	}
	e := Entry{time_ms = now_ms, kind = kind, key = out[main].hash, preview = strings.clone(clip_preview(preview)), reps = out}
	if at := find_key(s, e.key); at >= 0 {
		old := s.entries[at]
		e.id, e.pinned = old.id, old.pinned
		entry_free(&s.entries[at])
		ordered_remove(&s.entries, at)
	} else {
		s.next_id += 1
		e.id = s.next_id
	}
	inject_at(&s.entries, 0, e)
	return e.id, true
}

// Moves the entry `id` to the top, as a new copy of it would.
touch :: proc(s: ^Store, id: u64, now_ms: i64) -> bool {
	at := find(s, id)
	if at < 0 { return false }
	e := s.entries[at]
	e.time_ms = now_ms
	ordered_remove(&s.entries, at)
	inject_at(&s.entries, 0, e)
	return true
}

remove :: proc(s: ^Store, id: u64) -> bool {
	at := find(s, id)
	if at < 0 { return false }
	entry_free(&s.entries[at])
	ordered_remove(&s.entries, at)
	return true
}

set_pinned :: proc(s: ^Store, id: u64, pinned: bool) -> bool {
	at := find(s, id)
	if at < 0 { return false }
	s.entries[at].pinned = pinned
	return true
}

// Removes every entry that is not pinned (all of them with `pinned_too`).
clear_all :: proc(s: ^Store, pinned_too := false) -> (removed: int) {
	for i := len(s.entries) - 1; i >= 0; i -= 1 {
		if s.entries[i].pinned && !pinned_too { continue }
		entry_free(&s.entries[i])
		ordered_remove(&s.entries, i)
		removed += 1
	}
	return
}

// Removes the entries past the limits: more than `max_entries` (0: no limit) not pinned, or older than `max_age_ms`
// (0: no limit). Pinned entries stay and do not count.
trim :: proc(s: ^Store, max_entries: int, max_age_ms: i64, now_ms: i64) -> (removed: int) {
	kept := 0
	for i := 0; i < len(s.entries); {
		e := &s.entries[i]
		if e.pinned { i += 1; continue }
		too_many := max_entries > 0 && kept >= max_entries
		too_old := max_age_ms > 0 && now_ms - e.time_ms > max_age_ms
		if too_many || too_old {
			entry_free(e)
			ordered_remove(&s.entries, i)
			removed += 1
			continue
		}
		kept += 1
		i += 1
	}
	return
}

// Deletes the blobs no entry names (after a trim, a removal, a clear). Returns how many went.
collect :: proc(s: ^Store) -> (deleted: int) {
	used := make(map[u64]bool, context.temp_allocator)
	for e in s.entries { for r in e.reps { used[r.hash] = true } }
	dir := strings.concatenate({s.dir, "/", BLOBS_DIR}, context.temp_allocator)
	for f in fsx.list_files(dir) {
		h, ok := strconv.parse_u64_of_base(f.name, 16)
		if ok && used[h] { continue }
		if fsx.delete_file(strings.concatenate({dir, "/", f.name}, context.temp_allocator)) { deleted += 1 }
	}
	return
}

// Writes the index (atomically).
save :: proc(s: ^Store) -> bool {
	return fsx.write_atomic(index_path(s), transmute([]u8)format_index(s))
}

// The bytes of a representation (nil when its blob is gone).
blob_read :: proc(s: ^Store, hash: u64, allocator := context.allocator) -> []u8 {
	data, ok := fsx.read_all(blob_path(s, hash), allocator)
	return data if ok else nil
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

////////////////////////////////
// The index: a line of text per entry and one per representation, tab-separated.
//
//   papier-index 1
//   E <id> <time ms> <pinned 0|1> <kind> <key hex> <preview, escaped>
//   R <hash hex> <size> <mime>

format_index :: proc(s: ^Store, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, INDEX_MAGIC)
	strings.write_byte(&b, '\n')
	for e in s.entries {
		fmt.sbprintf(&b, "E\t%d\t%d\t%d\t%s\t%016x\t", e.id, e.time_ms, e.pinned ? 1 : 0, KIND_NAMES[e.kind], e.key)
		escape_into(&b, e.preview)
		strings.write_byte(&b, '\n')
		for r in e.reps {
			fmt.sbprintf(&b, "R\t%016x\t%d\t", r.hash, r.size)
			escape_into(&b, r.mime)
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

// Reads an index into `s` (which is empty). A line that does not parse is skipped, with the representations under it.
parse_index :: proc(s: ^Store, text: string) {
	rest := text
	first := true
	reps := make([dynamic]Rep, context.temp_allocator)
	cur: Maybe(Entry)
	flush :: proc(s: ^Store, cur: ^Maybe(Entry), reps: ^[dynamic]Rep) {
		if e, ok := cur.?; ok {
			e.reps = make([]Rep, len(reps))
			copy(e.reps, reps[:])
			append(&s.entries, e)
			s.next_id = max(s.next_id, e.id)
		}
		cur^ = nil
		clear(reps)
	}
	for line in strings.split_lines_iterator(&rest) {
		if first {
			first = false
			if line != INDEX_MAGIC { return }
			continue
		}
		f := strings.split(line, "\t", context.temp_allocator)
		switch {
		case len(f) == 7 && f[0] == "E":
			flush(s, &cur, &reps)
			id, ok1 := strconv.parse_u64(f[1])
			t, ok2 := strconv.parse_i64(f[2])
			key, ok3 := strconv.parse_u64_of_base(f[5], 16)
			kind, ok4 := kind_of(f[4])
			if !(ok1 && ok2 && ok3 && ok4) { continue }
			cur = Entry{id = id, time_ms = t, pinned = f[3] == "1", kind = kind, key = key, preview = unescape(f[6])}
		case len(f) == 4 && f[0] == "R":
			if cur == nil { continue }
			h, ok1 := strconv.parse_u64_of_base(f[1], 16)
			n, ok2 := strconv.parse_int(f[2])
			if !(ok1 && ok2) { continue }
			append(&reps, Rep{unescape(f[3]), h, n})
		}
	}
	flush(s, &cur, &reps)
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

@(private)
escape_into :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\': strings.write_string(b, `\\`)
		case '\t': strings.write_string(b, `\t`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case:      strings.write_byte(b, s[i])
		}
	}
}

// The text of an escaped field (heap: owned by the entry).
@(private)
unescape :: proc(s: string) -> string {
	b := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] != '\\' || i + 1 == len(s) { strings.write_byte(&b, s[i]); continue }
		i += 1
		switch s[i] {
		case 't': strings.write_byte(&b, '\t')
		case 'n': strings.write_byte(&b, '\n')
		case 'r': strings.write_byte(&b, '\r')
		case:     strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}
