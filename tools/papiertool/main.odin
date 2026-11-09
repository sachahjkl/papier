// papiertool: every step of papier's build and checks.
//
//   odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -- <command>
//
//   build [release]   the toolkit's text library (cargo, when its sources changed), then build/papier
//   check             odin check of the program and of this tool, then the tests
//   test              the tests of the program and of its packages
//   help              this list
//
// GT=<folder>: another checkout of gui_toolkit (its root, not its src).
package papiertool

import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "gt:toolbox"

// What a build on Linux needs: the toolkit's native text backend, and the Rust standard library that both it and
// wgpu-native carry linked once (the same code: the toolkit's own CI does the same).
@(rodata) LINUX_FLAGS := [?]string{"-define:FONT_BACKEND=native", "-extra-linker-flags:-Wl,--allow-multiple-definition"}
// The packages that have tests.
TEST_PACKAGES :: [?]string{"src", "src/history"}

USAGE :: `papiertool <command>
  build [release]   build build/papier (debug unless release)
  check             odin check of the program and the tool, then the tests
  test              the tests
  help              this list
`

toolkit :: proc() -> string {
	if v := os.get_env("GT", context.temp_allocator); v != "" { return v }
	return "ext/gui_toolkit"
}

collection :: proc() -> string { return fmt.tprintf("-collection:gt=%s/src", toolkit()) }

odin_cmd :: proc(verb, pkg: string, extra: []string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", verb, pkg, collection(), "-vet")
	when ODIN_OS == .Linux {
		append(&cmd, LINUX_FLAGS[0])
		if verb != "check" { append(&cmd, LINUX_FLAGS[1]) }   // (check links nothing)
	}
	append(&cmd, ..extra)
	return cmd[:]
}

// The toolkit's text library, built by its own tool (it skips what is up to date).
build_text :: proc() -> bool {
	when ODIN_OS == .Linux {
		return toolbox.run({"odin", "run", "tools/tk", "--", "build_text"}, {dir = toolkit(), echo = true})
	} else {
		return true
	}
}

cmd_build :: proc(args: []string) -> int {
	release := len(args) > 0 && args[0] == "release"
	if !build_text() { return 1 }
	_ = os.make_directory("build")
	mode := release ? "-o:speed" : "-debug"
	cmd := odin_cmd("build", "src", {"-out:build/papier", mode})
	if !toolbox.run(cmd, {echo = true}) { return 1 }
	fmt.println("built build/papier")
	return 0
}

cmd_test :: proc() -> int {
	if !build_text() { return 1 }
	_ = os.make_directory("build")
	for pkg in TEST_PACKAGES {
		name, _ := strings.replace_all(pkg, "/", "_", context.temp_allocator)
		out := fmt.tprintf("-out:build/test_%s", name)
		if !toolbox.run(odin_cmd("test", pkg, {out}), {echo = true}) { return 1 }
	}
	return 0
}

cmd_check :: proc() -> int {
	if !toolbox.run(odin_cmd("check", "src", nil), {echo = true}) { return 1 }
	tool := []string{"odin", "check", "tools/papiertool", collection(), "-vet"}
	if !toolbox.run(tool, {echo = true}) { return 1 }
	return cmd_test()
}

main :: proc() {
	args := os.args[1:]
	code := 0
	switch len(args) > 0 ? args[0] : "help" {
	case "build": code = cmd_build(args[1:])
	case "test":  code = cmd_test()
	case "check": code = cmd_check()
	case "help", "-h", "--help": fmt.print(USAGE)
	case:
		fmt.eprint(USAGE)
		code = 2
	}
	os.exit(code)
}
