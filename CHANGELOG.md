# Changelog

All notable changes to papier are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

### Added
- **The clipboard's history on Wayland**: every copy is recorded through the data-control protocol
  (`ext-data-control-v1`, or `zwlr-data-control-unstable-v1`), with no window and no focus: text, rich text (HTML), images
  (PNG, JPEG, WebP, GIF, BMP, SVG) and files copied in a file manager.
- **One process for the session**: papier lives in the notification area and its window comes up in a few milliseconds.
  A second `papier` hands it `show`; `papier toggle` is for a key binding.
- **The window**: an integrated title bar with the search and the filters (All, Text, Images, Files, Pinned), a dense list
  that builds only the rows in view, the selected entry in full beside it (text in a monospace face, images, files), a
  splitter, a status bar with the keys. Its size, its place (X11) and the list's width are remembered.
- **The keyboard**: typing filters, Up / Down / Page Up / Page Down move, Enter or a double click puts an entry back on the
  clipboard, Alt+1..9 the first nine, Ctrl+P pins, Shift+Delete removes, Tab switches the filter, Escape clears or hides.
- **Pinned entries** stay whatever the limits.
- **Secrets are left out**: what a password manager marks with `x-kde-passwordManagerHint` is not recorded.
- **The clipboard kept**: when the program that owned it quits and empties it, the last entry goes back.
- **The history on the disk**: content-addressed blobs (a copy of the same bytes is one file) and an index written
  atomically; the same copy twice is one entry, moved to the top.
- **Preferences** (`papier prefs`, `papier set`, `--pref`): history limits, what to record, the size limit, types to
  ignore, the primary selection, the theme (papier, papier light, or any of gui_toolkit's palettes), the window's size and
  text size.
- **The command line**: `list`, `get`, `copy`, `pin`, `unpin`, `delete`, `clear`, `show`, `hide`, `toggle`, `quit`.
- **The desktop**: `papier install` adds a launcher with its icons, `~/.local/bin/papier` and the start with the session;
  `uninstall` and `status`.
- **papiertool**: `build`, `test`, `check`, `live` (the real program in a headless sway), `shots`, `logo`, `package`,
  `notes`, `ship`, `site`.
