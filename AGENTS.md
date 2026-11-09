# papier

A clipboard manager for Linux, in Odin, using the `ext/gui_toolkit` submodule (collection `gt`).

Read first: [README.md](README.md).

## Build and test

Every step is a command of `tools/papiertool` (`help` lists them):

```sh
odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -- <command>
```

- `build [debug|release]` builds the program (`build.sh` / `build.bat` are shortcuts).
- `check` runs `odin check` on the application and the tool.
- Linux: `nix develop` first (`flake.nix`).

## Rules

- What more than one program needs goes in gui_toolkit, generic and configurable.
- Platform code goes in files with a system suffix when needed.
- Preferences use `gt:config`.
- Automation is a command of `tools/papiertool`, never a shell, batch, PowerShell, Python, or Node script.
- Comments and commit messages are in English. Comments say why.
- Commits: author and committer `sachahjkl <sacha@sacha.house>`, no attribution trailer, no session link.
