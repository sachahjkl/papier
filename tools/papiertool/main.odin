// papiertool: the project's machinery, one program, whatever the shell.
//
//   odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -- <command>
//   (build.sh and build.bat are its shortcuts for `build`)
//
// What it needs is on the path: git, odin, cargo (the toolkit's text library), cc and ar (SQLite), tar; gh for what is
// published. GT=<folder>: another checkout of gui_toolkit (its root, not its src).
package papiertool

import changelog "gt:changelog"
import release "gt:release"
import toolbox "gt:toolbox"
import papier_licence "../../src/licence"
import papier_update "../../src/update"

REPOSITORY :: "https://github.com/sachahjkl/papier"
when ODIN_OS == .Windows {
	PROGRAM :: "build/papier.exe"
} else {
	PROGRAM :: "build/papier"
}
// papier.com, the console launcher papier embeds (src/integration.odin).
LAUNCHER_OUT :: "build/papier.com"

// What papier is to its tool and to the toolkit's standard commands. papier.com's rules: a command waits and gives its
// output and exit code through; no argument, --hidden and toggle, which may become the running papier, do not wait.
project :: proc() -> toolbox.Project {
	return {
		name = "papier", repository = REPOSITORY, changelog = "CHANGELOG.md",
		version_file = "src/main.odin", version_line = "APP_VERSION :: ", program = PROGRAM,
		launcher = {out = LAUNCHER_OUT, mark = "(papier console launcher)", default_rule = "wait",
		            others = "(none),toggle,--hidden", refuses_exit = 2},
		// (live and shots drive the release build over CDP: Devtools; only the icons papier names: Lucide_Subset)
		features = {.Devtools, .Lucide_Subset},
	}
}

// The `licence` and `paddle` commands: papier's licence (src/licence.odin), its development pair, its Paddle catalogue.
LICENCE_TOOL :: toolbox.Licence_Tool{
	product  = papier_licence.PRODUCT,
	// (the development pair's private key, public on purpose: "papier-dev-licence-test-seed-01!")
	dev_seed = "cGFwaWVyLWRldi1saWNlbmNlLXRlc3Qtc2VlZC0wMSE",
	hint     = "Open this file with papier (Settings > General > Choose a file), or paste the key there.",
	paddle   = {name = "Papier User Licence", description = "A personal, perpetual licence of papier, the clipboard history.", amounts = "supporter=1500,patron=4500", currency = "EUR"},
}

// What goes beside the program in a release's archive: the file, and its name there (the icons' licence is the
// toolkit's).
@(rodata)
RELEASE_FILES := [?][2]string{
	{"README.md", "README.md"}, {"LICENSE", "LICENSE"}, {"CHANGELOG.md", "CHANGELOG.md"},
	{"ext/gui_toolkit/src/lucide/LICENSE.txt", "LUCIDE-LICENSE.txt"},
}

// papier's texts, from its code, into i18n/<language>.txt (the program embeds them: src/app.odin).
// (a variable: a constant's slice would be made again where it is used, on a stack the command outlives)
I18N := toolbox.I18n_Catalogues{dirs = {"src"}, folder = "i18n"}

commands :: proc() -> []toolbox.Command {
	p := project()
	r := release.commands({project = p, dist = "build/dist", files = RELEASE_FILES[:], check = proc() -> int { return run_check(nil) }, update = papier_update.PRODUCT})
	list := make([dynamic]toolbox.Command, context.temp_allocator)
	append(&list,
		toolbox.Command{name = "build", usage = "[release]: the toolkit's text library and SQLite when their sources changed, then build/papier", run = run_build},
		toolbox.Command{name = "test", usage = ": the tests of the program and of its packages", run = run_test},
		toolbox.Command{name = "check", usage = ": the changelog, the scopes, the French catalogue, odin check of the program for this system and for Windows and of this tool (-vet), the tests, then a release build", run = run_check},
		toolbox.logo_command(logo()),
		r[0], r[1], r[2],
		toolbox.Command{name = "update", usage = "keygen <file> | pubkey | manifest <program> <version> - <out> | verify <manifest> -: papier's update key and manifests", run = proc(args: []string) -> int { return toolbox.update_command(papier_update.PRODUCT, args) }},
		changelog.command(p),
		toolbox.i18n_command(I18N),
		site_command(),
	)
	l := toolbox.licence_commands(LICENCE_TOOL)
	append(&list, l[0], l[1])
	// (the real program in a sway nobody sees: Linux)
	when ODIN_OS == .Linux {
		append(&list,
			toolbox.Command{name = "shots", usage = "[--out folder]: the pictures of the README and the site, the program's own frames in a sway nobody sees", run = run_shots},
			toolbox.Command{name = "live", usage = "[--keep]: the real program in a sway nobody sees: copies of each kind, a secret, the window hidden and shown", run = run_live},
		)
	}
	return list[:]
}

main :: proc() {
	toolbox.tool_main("papiertool", commands(), toolbox.ROOT_MARK_DEFAULT)
}
