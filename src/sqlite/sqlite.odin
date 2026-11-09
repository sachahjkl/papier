// Package sqlite: the part of SQLite's C interface papier uses. SQLite is linked into papier (ext/sqlite, built by
// papiertool): the history needs no library of the system.
package sqlite

import "core:c"
import "core:strings"

DB   :: distinct rawptr
Stmt :: distinct rawptr

OK   :: 0
ROW  :: 100
DONE :: 101

OPEN_READWRITE :: 0x00000002
OPEN_CREATE    :: 0x00000004
OPEN_NOMUTEX   :: 0x00008000

// SQLITE_TRANSIENT: SQLite copies what is bound.
@(private) TRANSIENT :: rawptr(~uintptr(0))

// (papiertool build_sqlite compiles it from ext/sqlite)
foreign import lib {
	"../../build/sqlite/libsqlite3.a",
	"system:pthread",
	"system:m",
}

@(default_calling_convention = "c", link_prefix = "sqlite3_", private)
foreign lib {
	open_v2        :: proc(name: cstring, db: ^DB, flags: c.int, vfs: cstring) -> c.int ---
	close_v2       :: proc(db: DB) -> c.int ---
	@(link_name = "sqlite3_exec") exec_c :: proc(db: DB, sql: cstring, cb: rawptr, arg: rawptr, err: ^cstring) -> c.int ---
	prepare_v2     :: proc(db: DB, sql: cstring, n: c.int, stmt: ^Stmt, tail: ^cstring) -> c.int ---
	@(link_name = "sqlite3_step") step_c :: proc(s: Stmt) -> c.int ---
	@(link_name = "sqlite3_finalize") finalize_c :: proc(s: Stmt) -> c.int ---
	bind_int64     :: proc(s: Stmt, i: c.int, v: i64) -> c.int ---
	bind_text      :: proc(s: Stmt, i: c.int, v: [^]u8, n: c.int, d: rawptr) -> c.int ---
	bind_blob      :: proc(s: Stmt, i: c.int, v: rawptr, n: c.int, d: rawptr) -> c.int ---
	column_int64   :: proc(s: Stmt, i: c.int) -> i64 ---
	@(link_name = "sqlite3_column_text") column_text_c :: proc(s: Stmt, i: c.int) -> [^]u8 ---
	@(link_name = "sqlite3_column_blob") column_blob_c :: proc(s: Stmt, i: c.int) -> rawptr ---
	column_bytes   :: proc(s: Stmt, i: c.int) -> c.int ---
	@(link_name = "sqlite3_errmsg") errmsg_c :: proc(db: DB) -> cstring ---
	busy_timeout   :: proc(db: DB, ms: c.int) -> c.int ---
	free           :: proc(p: rawptr) ---
}

// How long a statement waits for another connection's write to end before it fails.
BUSY_WAIT_MS :: 5000

// Opens (makes) the database at `path`. db = nil, with why, when the file cannot be opened.
open :: proc(path: string) -> (db: DB, why: string) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if open_v2(cpath, &db, OPEN_READWRITE | OPEN_CREATE | OPEN_NOMUTEX, nil) != OK {
		why = strings.clone(string(errmsg_c(db)), context.temp_allocator)
		if db != nil { close_v2(db) }
		return nil, why
	}
	busy_timeout(db, BUSY_WAIT_MS)
	return db, ""
}

close :: proc(db: DB) { if db != nil { close_v2(db) } }

// Runs statements that return no rows. False, with the error, when one fails.
exec :: proc(db: DB, sql: string) -> (ok: bool, why: string) {
	err: cstring
	if exec_c(db, strings.clone_to_cstring(sql, context.temp_allocator), nil, nil, &err) != OK {
		why = strings.clone(string(err), context.temp_allocator)
		free(rawptr(err))
		return false, why
	}
	return true, ""
}

errmsg :: proc(db: DB) -> string { return string(errmsg_c(db)) }

// A statement, its values bound in order (i64, int, bool, string, []u8).
prepare :: proc(db: DB, sql: string, args: ..any) -> (s: Stmt, ok: bool) {
	if prepare_v2(db, strings.clone_to_cstring(sql, context.temp_allocator), -1, &s, nil) != OK { return nil, false }
	for a, i in args {
		n := c.int(i + 1)
		switch v in a {
		case i64:    bind_int64(s, n, v)
		case int:    bind_int64(s, n, i64(v))
		case u64:    bind_int64(s, n, i64(v))
		case bool:   bind_int64(s, n, v ? 1 : 0)
		// (an empty one from a nil pointer: SQLite would bind NULL)
		case string: bind_text(s, n, len(v) > 0 ? raw_data(v) : &empty, c.int(len(v)), TRANSIENT)
		case []u8:   bind_blob(s, n, len(v) > 0 ? raw_data(v) : &empty, c.int(len(v)), TRANSIENT)
		case:        panic("sqlite: a value of a kind it does not bind")
		}
	}
	return s, true
}

@(private = "file", rodata) empty := u8(0)

// The next row: true while there is one.
step :: proc(s: Stmt) -> bool { return step_c(s) == ROW }

// Runs a statement to its end. True when it ran without an error.
run :: proc(s: Stmt) -> bool {
	for {
		r := step_c(s)
		if r == ROW { continue }
		return r == DONE
	}
}

finalize :: proc(s: Stmt) { finalize_c(s) }

// Runs one statement that returns no rows, with its values. True when it ran.
run_sql :: proc(db: DB, sql: string, args: ..any) -> bool {
	s, ok := prepare(db, sql, ..args)
	if !ok { return false }
	defer finalize(s)
	return run(s)
}

column_i64 :: proc(s: Stmt, i: int) -> i64 { return column_int64(s, c.int(i)) }
column_u64 :: proc(s: Stmt, i: int) -> u64 { return u64(column_int64(s, c.int(i))) }

// The text of a column, valid until the next step (clone it to keep it).
column_text :: proc(s: Stmt, i: int) -> string {
	p := column_text_c(s, c.int(i))
	if p == nil { return "" }
	return string(p[:column_bytes(s, c.int(i))])
}

// The bytes of a column, valid until the next step.
column_blob :: proc(s: Stmt, i: int) -> []u8 {
	p := column_blob_c(s, c.int(i))
	if p == nil { return nil }
	return ([^]u8)(p)[:column_bytes(s, c.int(i))]
}
