package history

// The history of papier 0.4 and before: a text index and a directory of blobs. open imports it into the database once,
// in one transaction, then deletes it.
//
//   papier-index 1
//   E <id> <time ms> <pinned 0|1> <kind> <key hex> <preview, escaped>
//   R <hash hex> <size> <mime, escaped>
//
// Blobs: blobs/<hash, 16 hex digits>. A representation whose blob is gone is left out, and an entry with none left.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "gt:fsx"
import "../sqlite"

OLD_INDEX_FILE  :: "index"
OLD_BLOBS_DIR   :: "blobs"
OLD_INDEX_MAGIC :: "papier-index 1"

// Imports the old history of `dir` when there is one. The entries already in the database (the same key) stay as they
// are; an old entry keeps its id unless the database gives it to another. The old files are deleted once the
// transaction is written. How many entries came; ok = false when the import failed (the old files stay).
@(private)
import_old :: proc(s: ^Store, dir: string) -> (imported: int, ok: bool) {
	index_path := strings.concatenate({dir, "/", OLD_INDEX_FILE}, context.temp_allocator)
	text, read := fsx.read_all(index_path, context.temp_allocator)
	if !read { return 0, true }   // (none)
	old := parse_old_index(string(text))
	if !begin(s) { return 0, false }
	next := meta_next_id(s)
	written := true
	for e in old {
		if row_exists(s, "SELECT 1 FROM entries WHERE key = ?", e.key) { continue }
		reps := make([dynamic]Rep, context.temp_allocator)
		body := e.preview
		for r in e.reps {
			data, found := fsx.read_all(fmt.tprintf("%s/%s/%016x", dir, OLD_BLOBS_DIR, r.hash), context.temp_allocator)
			if !found { continue }
			if !sqlite.run_sql(s.db, "INSERT OR IGNORE INTO blobs (hash, data) VALUES (?, ?)", r.hash, data) { written = false; break }
			append(&reps, r)
			// the whole text, for the search
			if e.kind == .Text && strings.has_prefix(r.mime, "text/plain") { body = string(data) }
		}
		if !written { break }
		if len(reps) == 0 { continue }
		n := e
		n.reps = reps[:]
		if n.id == 0 || row_exists(s, "SELECT 1 FROM entries WHERE id = ?", n.id) { next += 1; n.id = next }
		next = max(next, n.id)
		if !write_entry(s, n, body) { written = false; break }
		imported += 1
	}
	written = written && sqlite.run_sql(s.db, "INSERT OR REPLACE INTO meta (k, v) VALUES ('next_id', ?)", next)
	if !end(s, written) { return 0, false }
	fsx.delete_file(index_path)
	fsx.remove_tree(strings.concatenate({dir, "/", OLD_BLOBS_DIR}, context.temp_allocator))
	return imported, true
}

@(private = "file")
meta_next_id :: proc(s: ^Store) -> (next: u64) {
	q, ok := sqlite.prepare(s.db, "SELECT max(coalesce((SELECT v FROM meta WHERE k = 'next_id'), 0), coalesce((SELECT max(id) FROM entries), 0))")
	if !ok { return 0 }
	defer sqlite.finalize(q)
	if sqlite.step(q) { next = sqlite.column_u64(q, 0) }
	return
}

@(private = "file")
row_exists :: proc(s: ^Store, sql: string, arg: u64) -> bool {
	q, ok := sqlite.prepare(s.db, sql, arg)
	if !ok { return false }
	defer sqlite.finalize(q)
	return sqlite.step(q)
}

// The entries of an old index (temp memory). A line that does not parse is skipped, with the representations under it.
@(private)
parse_old_index :: proc(text: string) -> []Entry {
	out := make([dynamic]Entry, context.temp_allocator)
	reps := make([dynamic]Rep, context.temp_allocator)
	cur: Maybe(Entry)
	flush :: proc(out: ^[dynamic]Entry, cur: ^Maybe(Entry), reps: ^[dynamic]Rep) {
		if e, ok := cur.?; ok {
			e.reps = make([]Rep, len(reps), context.temp_allocator)
			copy(e.reps, reps[:])
			append(out, e)
		}
		cur^ = nil
		clear(reps)
	}
	rest := text
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if first {
			first = false
			if line != OLD_INDEX_MAGIC { return nil }
			continue
		}
		f := strings.split(line, "\t", context.temp_allocator)
		switch {
		case len(f) == 7 && f[0] == "E":
			flush(&out, &cur, &reps)
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
	flush(&out, &cur, &reps)
	return out[:]
}

// The text of an escaped field (\\, \t, \n, \r), in temp memory.
@(private = "file")
unescape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
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
