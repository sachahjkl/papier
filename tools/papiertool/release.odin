package papiertool

// What a release is made of, the same steps on a laptop and in the release workflow:
//
//   package [version]       build/dist: papier-<version>-linux-x64.tar.gz (the program, its licences, the README and the
//                           changelog) and SHA256SUMS.txt; the version is APP_VERSION's when none is given
//   notes <version>         the changelog's section of that version (the notes of its GitHub release)
//   ship <version> [--dry-run]
//                           from a clean master: the changelog's [Unreleased] becomes [<version>] with today's date,
//                           APP_VERSION becomes <version>, the checks, a commit, the tag v<version>, the push. The release
//                           workflow builds the archive and publishes it; the site follows.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import toolbox "gt:toolbox"

CHANGELOG    :: "CHANGELOG.md"
VERSION_FILE :: "src/main.odin"
VERSION_LINE :: "APP_VERSION :: "
REPOSITORY   :: "https://github.com/sachahjkl/papier"
DIST_DIR     :: "build/dist"
// What goes beside the program in the archive.
DIST_FILES   :: [?]string{"README.md", "LICENSE", "CHANGELOG.md", "assets/fonts/LUCIDE-LICENSE.txt"}

// The version of the sources: APP_VERSION's value ("" when the line is not there).
version_of :: proc(source: string) -> string {
	rest := source
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, VERSION_LINE) { continue }
		v := strings.trim_space(line[len(VERSION_LINE):])
		if len(v) >= 2 && v[0] == '"' {
			if end := strings.index_byte(v[1:], '"'); end >= 0 { return v[1:end + 1] }
		}
	}
	return ""
}

// The sources with APP_VERSION set to `version`; ok = false when the line is not there.
version_set :: proc(source, version: string, allocator := context.temp_allocator) -> (out: string, ok: bool) {
	old := version_of(source)
	if old == "" { return "", false }
	from := fmt.tprintf("%s\"%s\"", VERSION_LINE, old)
	to := fmt.tprintf("%s\"%s\"", VERSION_LINE, version)
	out, _ = strings.replace(source, from, to, 1, allocator)
	return out, out != source || old == version
}

// The three numbers of "x.y.z"; ok = false for anything else.
semver :: proc(v: string) -> (n: [3]int, ok: bool) {
	parts := strings.split(v, ".", context.temp_allocator)
	if len(parts) != 3 { return }
	for p, i in parts {
		if p == "" || (len(p) > 1 && p[0] == '0') { return }
		n[i] = strconv.parse_int(p, 10) or_return
		if n[i] < 0 { return }
	}
	return n, true
}

// Whether `b` comes after `a`.
semver_newer :: proc(a, b: string) -> bool {
	x, ok1 := semver(a)
	y, ok2 := semver(b)
	if !(ok1 && ok2) { return false }
	for i in 0 ..< 3 { if y[i] != x[i] { return y[i] > x[i] } }
	return false
}

// The changelog with its [Unreleased] section become [<version>] - <date>, a new empty [Unreleased] above it, and the
// version's link at the end. ok = false when there is no [Unreleased] section or it says nothing.
changelog_release :: proc(text, version, date: string, allocator := context.temp_allocator) -> (out: string, ok: bool) {
	HEAD :: "## [Unreleased]"
	at := strings.index(text, HEAD)
	if at < 0 { return }
	body_start := at + len(HEAD)
	next := strings.index(text[body_start:], "\n## [")
	body_end := next < 0 ? len(text) : body_start + next
	// (the links at the end are not part of the section)
	if next < 0 { if links := strings.index(text[body_start:], "\n["); links >= 0 { body_end = body_start + links } }
	if strings.trim_space(text[body_start:body_end]) == "" { return }
	b := strings.builder_make(allocator)
	strings.write_string(&b, text[:at])
	fmt.sbprintf(&b, "%s\n\n## [%s] - %s", HEAD, version, date)
	strings.write_string(&b, text[body_start:])
	if !strings.has_suffix(strings.to_string(b), "\n") { strings.write_byte(&b, '\n') }
	fmt.sbprintf(&b, "[%s]: %s/releases/tag/v%s\n", version, REPOSITORY, version)
	return strings.to_string(b), true
}

// The body of the changelog's section of `version` (its ### parts), "" when there is none.
changelog_section :: proc(text, version: string) -> string {
	head := fmt.tprintf("## [%s]", version)
	at := strings.index(text, head)
	if at < 0 { return "" }
	start := at + len(head)
	if nl := strings.index_byte(text[start:], '\n'); nl >= 0 { start += nl + 1 } else { return "" }
	end := len(text)
	if next := strings.index(text[start:], "\n## ["); next >= 0 { end = start + next }
	if links := strings.index(text[start:end], "\n["); links >= 0 { end = start + links }
	return strings.trim_space(text[start:end])
}

@(private = "file")
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

run_notes :: proc(args: []string) -> int {
	if len(args) != 1 { fmt.eprintln("papiertool notes <version>"); return EXIT_USAGE }
	text, ok := read_text(CHANGELOG)
	if !ok { fmt.eprintfln("papiertool: %s cannot be read", CHANGELOG); return 1 }
	section := changelog_section(text, strings.trim_prefix(args[0], "v"))
	if section == "" { fmt.eprintfln("papiertool: %s has no section %s", CHANGELOG, args[0]); return 1 }
	fmt.println(section)
	return 0
}

run_package :: proc(args: []string) -> int {
	source, _ := read_text(VERSION_FILE)
	version := version_of(source)
	if len(args) > 0 {
		asked := strings.trim_prefix(args[0], "v")
		if asked != version { fmt.eprintfln("papiertool: the tag says %s, APP_VERSION %s", asked, version); return 1 }
	}
	if !os.exists(PROGRAM) { fmt.eprintfln("papiertool: %s is not built (papiertool build release)", PROGRAM); return 1 }
	name := fmt.tprintf("papier-%s-linux-x64", version)
	stage := fmt.tprintf("%s/%s", DIST_DIR, name)
	_ = os.remove_all(DIST_DIR)
	if os.make_directory_all(stage) != nil { fmt.eprintfln("papiertool: %s cannot be made", stage); return 1 }
	files := DIST_FILES
	for f in ([]string{PROGRAM}) { if !copy_file(f, fmt.tprintf("%s/papier", stage)) { return 1 } }
	for f in files {
		base := f[strings.last_index_byte(f, '/') + 1:]
		if !copy_file(f, fmt.tprintf("%s/%s", stage, base)) { return 1 }
	}
	// (the symbols are a third of the program: a crash in a release is read again with a build of its tag)
	if !toolbox.run({"strip", fmt.tprintf("%s/papier", stage)}) { return 1 }
	_ = os.chmod(fmt.tprintf("%s/papier", stage), {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	archive := fmt.tprintf("%s.tar.gz", name)
	if !toolbox.run({"tar", "--owner=0", "--group=0", "--numeric-owner", "-czf", archive, name}, {dir = DIST_DIR}) { return 1 }
	_ = os.remove_all(stage)
	sum, ok := toolbox.sha256_file(fmt.tprintf("%s/%s", DIST_DIR, archive))
	if !ok { return 1 }
	sums := fmt.tprintf("%s  %s\n", sum, archive)
	if os.write_entire_file(fmt.tprintf("%s/SHA256SUMS.txt", DIST_DIR), sums) != nil { return 1 }
	fmt.printfln("wrote %s/%s and %s/SHA256SUMS.txt", DIST_DIR, archive, DIST_DIR)
	return 0
}

@(private = "file")
copy_file :: proc(from, to: string) -> bool {
	data, err := os.read_entire_file(from, context.temp_allocator)
	if err != nil { fmt.eprintfln("papiertool: %s cannot be read", from); return false }
	if os.write_entire_file(to, data) != nil { fmt.eprintfln("papiertool: %s cannot be written", to); return false }
	return true
}

run_ship :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprintln("papiertool ship <version> [--dry-run]"); return EXIT_USAGE }
	version := strings.trim_prefix(args[0], "v")
	dry := len(args) > 1 && args[1] == "--dry-run"
	if _, ok := semver(version); !ok { fmt.eprintfln("papiertool: %s is not x.y.z", version); return EXIT_USAGE }
	source, _ := read_text(VERSION_FILE)
	current := version_of(source)
	if !semver_newer(current, version) && current != version { fmt.eprintfln("papiertool: %s does not come after %s", version, current); return 1 }
	branch, _ := toolbox.capture({"git", "rev-parse", "--abbrev-ref", "HEAD"})
	if strings.trim_space(branch) != "master" { fmt.eprintln("papiertool: ship from master"); return 1 }
	if status, _ := toolbox.capture({"git", "status", "--porcelain"}); strings.trim_space(status) != "" {
		fmt.eprintln("papiertool: the working tree is not clean")
		return 1
	}
	changes, _ := read_text(CHANGELOG)
	date := fmt.tprintf("%04d-%02d-%02d", time.date(time.now()))
	new_changes, ok := changelog_release(changes, version, date)
	if !ok { fmt.eprintfln("papiertool: %s has nothing under [Unreleased]", CHANGELOG); return 1 }
	new_source, sok := version_set(source, version)
	if !sok { fmt.eprintfln("papiertool: %s has no %s line", VERSION_FILE, VERSION_LINE); return 1 }
	if dry {
		fmt.printfln("ship %s (dry run): the section it releases\n%s", version, changelog_section(new_changes, version))
		return 0
	}
	if os.write_entire_file(CHANGELOG, new_changes) != nil || os.write_entire_file(VERSION_FILE, new_source) != nil { return 1 }
	if run_check(nil) != 0 { fmt.eprintln("papiertool: the checks failed: nothing is committed (git checkout . takes the changes back)"); return 1 }
	steps := [][]string{
		{"git", "add", CHANGELOG, VERSION_FILE},
		{"git", "commit", "-m", fmt.tprintf("papier %s", version)},
		{"git", "tag", "-a", fmt.tprintf("v%s", version), "-m", fmt.tprintf("papier %s", version)},
		{"git", "push", "origin", "master", fmt.tprintf("v%s", version)},
	}
	for s in steps { if !toolbox.run(s, {echo = true}) { return 1 } }
	fmt.printfln("shipped v%s: the release workflow builds and publishes it (%s/actions)", version, REPOSITORY)
	return 0
}
