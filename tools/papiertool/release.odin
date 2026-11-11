package papiertool

// A release (gui_toolkit's release package): `package [version]` the archive of the release build, its SHA-256, the
// program alone and its update manifest signed by $UPDATE_SIGNING_KEY; `notes <version>` the changelog's section; `ship
// <version> [--dry-run]` the changelog dated, APP_VERSION set, the checks, a commit, the tag, the push. The release
// workflow (.github/workflows/release.yml) builds and publishes a tag; the site follows.

import "core:os"
import release "gt:release"
import papier_update "../../src/update"

CHANGELOG    :: "CHANGELOG.md"
VERSION_FILE :: "src/main.odin"
VERSION_LINE :: "APP_VERSION :: "
REPOSITORY   :: "https://github.com/sachahjkl/papier"

@(private = "file")
release_config :: proc() -> release.Config {
	// what goes beside the program in the archive: the file, and its name there (the icons' licence is the toolkit's)
	@(static) files := [?][2]string{
		{"README.md", "README.md"}, {"LICENSE", "LICENSE"}, {"CHANGELOG.md", "CHANGELOG.md"},
		{"ext/gui_toolkit/src/lucide/LICENSE.txt", "LUCIDE-LICENSE.txt"},
	}
	return release.Config{
		name = "papier", repository = REPOSITORY, changelog = CHANGELOG,
		version_file = VERSION_FILE, version_line = VERSION_LINE,
		program = PROGRAM, dist = "build/dist", files = files[:], check = proc() -> int { return run_check(nil) },
		update = papier_update.PRODUCT,
	}
}

run_package :: proc(args: []string) -> int { return release.package_(release_config(), args) }
run_notes :: proc(args: []string) -> int { return release.notes(release_config(), args) }
run_ship :: proc(args: []string) -> int { return release.ship(release_config(), args) }

// The version src/main.odin says (APP_VERSION), "" when it cannot be read.
app_version :: proc() -> string {
	source, err := os.read_entire_file(VERSION_FILE, context.temp_allocator)
	return err == nil ? release.version_of(string(source), VERSION_LINE) : ""
}
