package papiertool

import "core:testing"

@(test)
the_version_is_read_and_written :: proc(t: ^testing.T) {
	src := "package papier\n\nAPP_VERSION :: \"0.1.0\"\n\nmain :: proc() {}\n"
	testing.expect_value(t, version_of(src), "0.1.0")
	out, ok := version_set(src, "0.2.0")
	testing.expect(t, ok)
	testing.expect_value(t, version_of(out), "0.2.0")
	_, ok = version_set("package x\n", "1.0.0")
	testing.expect(t, !ok, "no version line")
}

@(test)
versions_compare_as_numbers :: proc(t: ^testing.T) {
	testing.expect(t, semver_newer("0.9.0", "0.10.0"))
	testing.expect(t, semver_newer("0.1.9", "0.2.0"))
	testing.expect(t, !semver_newer("1.0.0", "1.0.0"))
	testing.expect(t, !semver_newer("1.2.0", "1.1.9"))
	_, ok := semver("1.02.0")
	testing.expect(t, !ok, "a leading zero")
	_, ok = semver("1.2")
	testing.expect(t, !ok, "two numbers")
}

// [Unreleased] becomes the version with its date, a new [Unreleased] above it, the version's link at the end; the notes
// of the release are its section alone.
@(test)
the_changelog_is_released :: proc(t: ^testing.T) {
	before := "# Changelog\n\n## [Unreleased]\n\n### Added\n- A thing.\n\n## [0.1.0] - 2026-11-01\n\n### Added\n- The first.\n\n[0.1.0]: https://github.com/sachahjkl/papier/releases/tag/v0.1.0\n"
	after, ok := changelog_release(before, "0.2.0", "2026-11-09")
	testing.expect(t, ok)
	testing.expect_value(t, changelog_section(after, "0.2.0"), "### Added\n- A thing.")
	testing.expect_value(t, changelog_section(after, "0.1.0"), "### Added\n- The first.")
	testing.expect(t, contains(after, "## [Unreleased]\n\n## [0.2.0] - 2026-11-09"), "a new [Unreleased] above the version")
	testing.expect(t, contains(after, "[0.2.0]: https://github.com/sachahjkl/papier/releases/tag/v0.2.0\n"), "the version's link")
	_, ok = changelog_release(after, "0.3.0", "2026-11-10")
	testing.expect(t, !ok, "nothing under [Unreleased]: nothing to release")
	first, fok := changelog_release("# Changelog\n\n## [Unreleased]\n\n### Added\n- All of it.\n", "0.1.0", "2026-11-09")
	testing.expect(t, fok)
	testing.expect_value(t, changelog_section(first, "0.1.0"), "### Added\n- All of it.")
}

@(private = "file")
contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) { if s[i:i + len(sub)] == sub { return true } }
	return false
}
