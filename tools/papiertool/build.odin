package papiertool

// build, test, check: the program and its tests, the same steps on a laptop and in the CI.

import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "gt:toolbox"

// What a build on Linux needs: the toolkit's native text backend, and the Rust standard library that both it and
// wgpu-native carry linked once (the same code: the toolkit's own CI does the same).
LINUX_DEFINES :: "-define:FONT_BACKEND=native"
LINUX_LINK    :: "-extra-linker-flags:-Wl,--allow-multiple-definition"
// The packages that have tests, and this tool.
TEST_PACKAGES :: [?]string{"src", "src/history", "tools/papiertool"}
when ODIN_OS == .Windows {
	PROGRAM :: "build/papier.exe"
} else {
	PROGRAM :: "build/papier"
}

toolkit :: proc() -> string {
	if v := os.get_env("GT", context.temp_allocator); v != "" { return v }
	return "ext/gui_toolkit"
}

collection :: proc() -> string { return fmt.tprintf("-collection:gt=%s/src", toolkit()) }

// An odin command on a package of the program: the toolkit's collection, -vet, and on Linux the text backend.
odin_cmd :: proc(verb, pkg: string, extra: []string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", verb, pkg, collection(), "-vet")
	when ODIN_OS == .Linux {
		append(&cmd, LINUX_DEFINES)
		if verb != "check" { append(&cmd, LINUX_LINK) }   // (check links nothing)
	}
	append(&cmd, ..extra)
	return cmd[:]
}

// The toolkit's text library, built by its own tool (it skips what is up to date).
build_text :: proc() -> bool {
	when ODIN_OS == .Linux {
		_ = os.make_directory_all(fmt.tprintf("%s/build", toolkit()))   // (a fresh checkout has none: the linker writes tk there)
		return toolbox.run({"odin", "run", "tools/tk", "-out:build/tk", "--", "build_text"}, {dir = toolkit(), echo = true})
	} else {
		return true
	}
}

// SQLite, from its amalgamation in ext/sqlite (3.54.1), compiled into build/sqlite/libsqlite3.a: the history's database
// (src/sqlite links it). Built again when its sources or the flags below change (the stamp beside it).
SQLITE_DIR   :: "ext/sqlite"
SQLITE_OUT   :: "build/sqlite"
SQLITE_LIB   :: "build/sqlite/libsqlite3.a"
SQLITE_STAMP :: "build/sqlite/STAMP"
// FTS5 for the search; no extensions loaded at run time, no deprecated or shared-cache code; double quotes only for names.
SQLITE_FLAGS :: [?]string{
	"-O2", "-fPIC", "-w",
	"-DSQLITE_ENABLE_FTS5", "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_MEMSTATUS=0",
	"-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_SHARED_CACHE", "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
}

build_sqlite :: proc() -> bool {
	when ODIN_OS == .Linux {
		source, err := os.read_entire_file(SQLITE_DIR + "/sqlite3.c", context.temp_allocator)
		if err != nil { fmt.eprintln("papiertool: " + SQLITE_DIR + "/sqlite3.c cannot be read"); return false }
		flags := SQLITE_FLAGS
		stamp := toolbox.sha256_hex(transmute([]u8)strings.concatenate({toolbox.sha256_hex(source), strings.join(flags[:], " ", context.temp_allocator)}, context.temp_allocator))
		if old, e := os.read_entire_file(SQLITE_STAMP, context.temp_allocator); e == nil && string(old) == stamp && os.exists(SQLITE_LIB) { return true }
		_ = os.make_directory_all(SQLITE_OUT)
		object := SQLITE_OUT + "/sqlite3.o"
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "cc", "-c", SQLITE_DIR + "/sqlite3.c", "-o", object)
		append(&cmd, ..flags[:])
		if !toolbox.run(cmd[:], {echo = true}) { return false }
		_ = os.remove(SQLITE_LIB)
		if !toolbox.run({"ar", "rcs", SQLITE_LIB, object}, {echo = true}) { return false }
		if os.write_entire_file(SQLITE_STAMP, transmute([]u8)stamp) != nil { return false }
		fmt.printfln("built %s", SQLITE_LIB)
	}
	return true
}

run_build :: proc(args: []string) -> int {
	release := len(args) > 0 && args[0] == "release"
	if !build_text() || !build_sqlite() { return 1 }
	_ = os.make_directory("build")
	mode := release ? []string{"-o:speed"} : []string{"-debug"}
	extra := make([dynamic]string, context.temp_allocator)
	append(&extra, fmt.tprintf("-out:%s", PROGRAM))
	append(&extra, ..mode)
	// (Windows: no console of its own, none flashes at a start with the session; its text goes to the parent's: output.odin)
	when ODIN_OS == .Windows { if release { append(&extra, "-subsystem:windows") } }
	if !toolbox.run(odin_cmd("build", "src", extra[:]), {echo = true}) { return 1 }
	fmt.printfln("built %s", PROGRAM)
	return 0
}

run_test :: proc(args: []string) -> int {
	if !build_text() || !build_sqlite() { return 1 }
	_ = os.make_directory("build")
	for pkg in TEST_PACKAGES {
		name, _ := strings.replace_all(pkg, "/", "_", context.temp_allocator)
		out := fmt.tprintf("-out:build/test_%s%s", name, ODIN_OS == .Windows ? ".exe" : "")
		cmd := pkg == "tools/papiertool" ? []string{"odin", "test", pkg, collection(), "-vet", out} : odin_cmd("test", pkg, {out})
		if !toolbox.run(cmd, {echo = true}) { return 1 }
	}
	return 0
}

run_check :: proc(args: []string) -> int {
	if !toolbox.run(odin_cmd("check", "src", nil), {echo = true}) { return 1 }
	if !toolbox.run({"odin", "check", "tools/papiertool", collection(), "-vet"}, {echo = true}) { return 1 }
	if run_test(nil) != 0 { return 1 }
	return run_build({"release"})
}
