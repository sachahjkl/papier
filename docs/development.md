# Development

## Setup

```sh
git clone --recurse-submodules https://github.com/sachahjkl/papier
cd papier
nix develop        # the pinned Odin with wgpu-native, Rust, sway and wl-clipboard for the live test, the git hooks
```

Without Nix: Odin `dev-2026-11a` (`odin.version`), clang and lld, cargo (the toolkit's text library), wgpu-native's static
library in Odin's `vendor/wgpu/lib` (`odin run ext/gui_toolkit/tools/tk -- fetch_wgpu`), fontconfig; sway and wl-clipboard
for `papiertool live`.

## papiertool

Every step is a command of `tools/papiertool`. `./build.sh` is its shortcut for `build`.

```sh
odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -keep-executable -- help
```

| Command | What it does |
|---|---|
| `build [release]` | the toolkit's text library (when its sources changed), then `build/papier` |
| `test` | the unit tests of `src` and `src/history` |
| `check` | `odin check -vet` of the program and the tool, the tests, a release build |
| `live [--keep]` | the real program in a headless sway, driven through wl-clipboard and the DevTools protocol |
| `shots [--out folder]` | the pictures of the README and the site, the program's own frames |
| `logo` | `assets/logo*.png`, drawn by the toolkit's paint package |
| `package [version]` | `build/dist`: the archive of a release build and its SHA-256, the program alone and, with `$UPDATE_SIGNING_KEY`, its signed update manifest |
| `update <...>` | papier's update key and manifests: `keygen`, `pubkey`, `manifest`, `verify` (gui_toolkit's `toolbox.update_command`) |
| `notes <version>` | the changelog's section of that version |
| `ship <version> [--dry-run]` | a release: see below |
| `site build <site> <out>`, `site check` | the site's pages, and their check in a real browser |

`GT=<folder>` builds against another checkout of gui_toolkit.

## Drive the window

A papier started with `TOOLKIT_DEVTOOLS=<port>` serves the Chrome DevTools Protocol: the toolkit's `tk cdp` reads its box
tree, clicks, types and takes pictures, and Chrome's DevTools inspect it.

```sh
TOOLKIT_DEVTOOLS=9222 build/papier
odin run ext/gui_toolkit/tools/tk -- cdp --port 9222 tree , shot window.png
```

## A change

- Comments and commit messages are in English. Comments say why.
- A setting is a `config.Def` in `src/settings.odin`, with its line in [configuration.md](configuration.md) (a test checks
  it).
- What another program could use goes in gui_toolkit, generic, with its documentation, its test and its changelog
  fragment; papier then points to the toolkit's new tag.
- Add what changed under `## [Unreleased]` in `CHANGELOG.md`.

## A release

```sh
odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -keep-executable -- ship 0.2.0
```

From a clean `master`: `[Unreleased]` becomes `[0.2.0]` with the date, `APP_VERSION` becomes `0.2.0`, `check` runs, then a
commit, the tag `v0.2.0` and the push. The release workflow (`.github/workflows/release.yml`) builds the archive on
Ubuntu, checks that the tag is the program's version, and publishes the GitHub release with the changelog's section. The
site (`.github/workflows/pages.yml`) follows: its download link names the new archive.

Each job also publishes its program alone (`papier-<version>-<platform>`, `.exe` on Windows) and its update manifest
(`update-<platform>.json` and `.sig`), signed with the repository's secret `UPDATE_SIGNING_KEY`. The installed copies
read the manifests of the latest release (src/updates.odin). The key's private half is also in `secrets/production.yaml`
(SOPS: `sops -d secrets/production.yaml`); its public half is `PRODUCT.public_key` in `src/update/product.odin`. A
release without the key fails: `papiertool package <version>` refuses to publish unsigned.
