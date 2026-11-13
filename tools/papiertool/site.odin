package papiertool

// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release. The steps are the
// toolkit's (gt:site, its `site` command: build <site> <out>, check, card); this file says what this site is: its address,
// names and colours. {{version}} in the home page is the last version: its download link names the file of that release.

import "core:fmt"
import "core:os"
import "core:strings"
import tk_site "gt:site"
import toolbox "gt:toolbox"

VERSION_MARK :: "{{version}}"

// Where the site is published, what it is: the one place that says it.
SITE_META :: tk_site.Meta{
	url         = "https://papier.froment.software/",
	name        = "papier",
	repository  = REPOSITORY,
	tagline     = "A fast clipboard history, searched as you type",
	changes     = "CHANGELOG.md",
	card        = "img/main.png",
	logo        = "img/logo.png",
	logo_file   = "site/img/logo.png",
	theme       = "#131315",
	accent      = "#cbbca3",
	author      = "Sacha Froment",
	author_url  = "https://froment.software",
	publisher   = "Froment Software",
	ld_type     = "SoftwareApplication",
	root_domain = false,   // (github.io answers for /robots.txt and /favicon.ico, not the site)
}

// The home page's download, for the reader's system (Windows first: what a phone or an unknown system is offered).
@(rodata)
SITE_DOWNLOADS := [?]tk_site.Download{
	{os = "windows", label = "Windows", href = "https://github.com/sachahjkl/papier/releases/download/v{{version}}/papier-{{version}}-windows-x64.zip", detail = "v{{version}} · Windows 10 / 11 · x64 · .zip"},
	{os = "linux", label = "Linux", href = "https://github.com/sachahjkl/papier/releases/download/v{{version}}/papier-{{version}}-linux-x64.tar.gz", detail = "v{{version}} · x64 · .tar.gz · Wayland"},
}

SITE_LD :: [?][2]string{
	{"applicationCategory", "UtilitiesApplication"},
	{"operatingSystem", "Windows, Linux"},
	{"license", "https://opensource.org/license/mit"},
}

site_meta :: proc() -> tk_site.Meta {
	m := SITE_META
	@(static) ld := SITE_LD
	m.ld_fields = ld[:]   // (static: the site command keeps the Meta as long as the tool runs)
	return m
}

// The shop: papier's licence (src/licence), sold through Paddle by the toolkit's licence Worker. Its pages (pricing,
// thanks, terms, refunds, privacy, imprint) are the toolkit's templates, filled at each `site build`. What is empty is
// the maintainer's to give once the shop is set up (docs/licence.md, "What the maintainer does at the end"): until the
// client token, the price id and the Worker are there, the button says "Coming soon".
SHOP :: tk_site.Shop{
	name           = "papier",
	icon           = "../img/logo.png",
	product_title  = "papier licence",
	price          = "15&nbsp;&euro;",
	price_note     = "",
	environment    = "sandbox",
	edition        = "supporter",
	price_id       = "",
	thanks         = "https://papier.froment.software/thanks/",
	help           = "https://github.com/sachahjkl/papier/issues",
	register       = "Open papier's settings (Ctrl+,), the <b>General</b> page, <b>Licence</b>: paste the key, or choose the file.",
	extension      = ".papierlicence",
	seller         = "Froment Software",
	seller_url     = "https://froment.software",
	code_licence   = "MIT",
	stylesheet     = "../style.css",
	home           = "../",
	updated        = "2026-11-13",
}

// The site's own command, with the shop's pages written after the toolkit's build.
site_command :: proc() -> toolbox.Command {
	inner := tk_site.command({meta = site_meta(), pages = {version_mark = VERSION_MARK, downloads = SITE_DOWNLOADS[:]}})
	return {name = inner.name, usage = inner.usage, run_with = site_run, user = new_clone(inner)}
}

@(private = "file")
site_run :: proc(args: []string, user: rawptr) -> int {
	inner := (^toolbox.Command)(user)
	code := inner.run_with(args, inner.user)
	if code != toolbox.EXIT_DONE || len(args) != 3 || args[0] != "build" { return code }
	for page in tk_site.licence_pages(SHOP) {
		path := fmt.tprintf("%s/%s", args[2], page.path)
		_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
		if os.write_entire_file(path, transmute([]u8)page.text) != nil { fmt.eprintfln("papiertool site: %s cannot be written", path); return toolbox.EXIT_FAILED }
	}
	return toolbox.EXIT_DONE
}
