package papiertool

// build, test, check: the program and its tests, the same steps on a laptop and in the CI.

import "core:fmt"
import "core:os"
import "core:strings"
import changelog "gt:changelog"
import toolbox "gt:toolbox"

// The packages that have tests (this tool has none of its own: its steps are gui_toolkit's, tested there; check still
// type-checks it).
TEST_PACKAGES :: [?]string{"src", "src/history"}

// SQLite, from its amalgamation in ext/sqlite (3.54.1), compiled into build/sqlite/libsqlite3.a: the history's database
// (src/sqlite links it). Built again when its sources or the flags below change (toolbox.build_c_lib's stamp).
SQLITE_SOURCES :: [?]string{"ext/sqlite/sqlite3.c"}
SQLITE_OUT     :: "build/sqlite"
// FTS5 for the search; no extensions loaded at run time, no deprecated or shared-cache code; double quotes only for names.
SQLITE_FLAGS :: [?]string{
	"-O2", "-fPIC", "-w",
	"-DSQLITE_ENABLE_FTS5", "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_MEMSTATUS=0",
	"-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_SHARED_CACHE", "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
}

// Linux: SQLite as a static library (Windows reads the system's own history: no database).
build_sqlite :: proc() -> bool {
	when ODIN_OS == .Linux {
		sources, flags := SQLITE_SOURCES, SQLITE_FLAGS
		return toolbox.build_c_lib("sqlite3", sources[:], SQLITE_OUT, flags[:])
	} else {
		return true
	}
}

// What a build or a test needs first: the toolkit's native libraries and the Lucide subset (build_native), SQLite, the
// console launcher (papier embeds it).
@(private = "file")
build_parts :: proc(p: toolbox.Project) -> bool {
	return toolbox.build_native(p) && build_sqlite() && toolbox.build_launcher(p)
}

run_build :: proc(args: []string) -> int {
	p := project()
	release := len(args) > 0 && args[0] == "release"
	if !build_parts(p) { return 1 }
	_ = os.make_directory("build")
	mode := release ? []string{"-o:speed"} : []string{"-debug"}
	extra := make([dynamic]string, context.temp_allocator)
	append(&extra, fmt.tprintf("-out:%s", PROGRAM))
	append(&extra, ..mode)
	// (Windows: no console of its own, none flashes at a start with the session; its text goes to the parent's: output.odin)
	when ODIN_OS == .Windows {
		if release { append(&extra, "-subsystem:windows") }
		// the icon, the manifest and the version (res/papier.rc)
		if !write_version_header(p) { return 1 }
		append(&extra, "-resource:res/papier.rc")
	}
	if !toolbox.run(toolbox.odin_command(p, "build", "", extra[:]), {echo = true}) { return 1 }
	// (an exe without its icon shows a blank one in the Start menu and Settings > Apps)
	when ODIN_OS == .Windows {
		if !toolbox.exe_has_icon(PROGRAM) { fmt.eprintfln("papiertool: %s has no icon (res/papier.rc)", PROGRAM); return 1 }
	}
	fmt.printfln("built %s", PROGRAM)
	return 0
}

// build/version.h: APP_VERSION's numbers for res/papier.rc.
VERSION_H :: "build/version.h"

write_version_header :: proc(p: toolbox.Project) -> bool {
	if why := toolbox.write_version_header(VERSION_H, toolbox.project_version(p)); why != "" {
		fmt.eprintfln("papiertool: %s", why)
		return false
	}
	return true
}

run_test :: proc(args: []string) -> int {
	p := project()
	if !build_parts(p) { return 1 }
	_ = os.make_directory("build")
	for pkg in TEST_PACKAGES {
		name, _ := strings.replace_all(pkg, "/", "_", context.temp_allocator)
		out := fmt.tprintf("-out:build/test_%s%s", name, ODIN_OS == .Windows ? ".exe" : "")
		if !toolbox.run(toolbox.odin_command(p, "test", pkg, {out}), {echo = true}) { return 1 }
	}
	return 0
}

run_check :: proc(args: []string) -> int {
	p := project()
	if !changelog_check(p) { return 1 }
	if !toolbox.check_scopes("src") { return 1 }
	// (a text of the code not in the catalogue, or not translated, shows in English to a French user)
	if problem := toolbox.i18n_catalogue(I18N.dirs, "i18n/fr.txt", "fr", true); problem != "" { fmt.eprintln(problem); return 1 }
	if !toolbox.build_launcher(p) { return 1 }   // (papier embeds it: odin check reads it)
	if !toolbox.run(toolbox.odin_command(p, "check"), {echo = true}) { return 1 }
	// (the whole program for Windows too, from any system: Windows code that does not compile fails the Linux job)
	when ODIN_OS != .Windows {
		// (papier for Windows embeds papier.com, which only Windows builds: an empty one stands for it in a check)
		if !os.exists(LAUNCHER_OUT) {
			_ = os.make_directory("build")
			if os.write_entire_file(LAUNCHER_OUT, []u8{}) != nil { fmt.eprintfln("papiertool: %s cannot be written", LAUNCHER_OUT); return 1 }
		}
		if !toolbox.check_windows(p) { return 1 }
	}
	if !toolbox.run({"odin", "check", "tools/papiertool", fmt.tprintf("-collection:gt=%s/src", toolbox.toolkit_dir(p)), "-vet"}, {echo = true}) { return 1 }
	if run_test(nil) != 0 { return 1 }
	if run_build({"release"}) != 0 { return 1 }
	return toolbox.check_launcher(p) ? 0 : 1
}

// The fragments of changelog.d/, as `changelog check` says them.
@(private = "file")
changelog_check :: proc(p: toolbox.Project) -> bool {
	q := p
	errors, n := changelog.check(changelog.project_options(&q))
	for e in errors { fmt.eprintln("changelog:", e) }
	if len(errors) == 0 { fmt.printfln("changelog: %d fragments, all well formed", n) }
	return len(errors) == 0
}
