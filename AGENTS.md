# papier

A clipboard manager for Linux (Wayland), in Odin, on the `ext/gui_toolkit` submodule (collection `gt`).

Read first: [README.md](README.md), [docs/architecture.md](docs/architecture.md), [docs/development.md](docs/development.md).

## Build and test

Every step is a command of `tools/papiertool` (`help` lists them):

    odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -keep-executable -- <command>

- `build [release]` builds `build/papier` (`build.sh` / `build.bat` are shortcuts).
- `check`: `odin check -vet`, the unit tests, a release build. `live`: the real program in a headless sway (62 checks).
- `shots` makes the pictures, `package` the release archive, `ship <version>` a release, `site build` the site.
- Linux: `nix develop` first (`flake.nix`). `nix build` builds the package.

## Rules

- What more than one program needs goes in gui_toolkit, generic, with its docs, test and changelog fragment; papier then
  points to the toolkit's new tag.
- A preference is a `config.Def` in `src/settings.odin` with its line in `docs/configuration.md` (a test checks it).
- What changed goes under `## [Unreleased]` in `CHANGELOG.md`; `papiertool ship` releases it.
- Tests never read or write the person's clipboard or desktop: `live` and `shots` run in a sway of their own.
- Automation is a command of `tools/papiertool`, never a shell, batch, PowerShell, Python or Node script.
- Comments and commit messages are in English. Comments say why.
- Commits: author and committer `sachahjkl <sacha@sacha.house>`, no attribution trailer, no session link.
