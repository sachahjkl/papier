package papiertool

// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release. The steps are the
// toolkit's (gt:site, its `site` command: build <site> <out>, check, card); this file says what this site is: its address,
// names and colours. {{version}} in the home page is the last version: its download link names the file of that release.

import tk_site "gt:site"

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
