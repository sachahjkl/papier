# Changelog

All notable changes to papier are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

### Added
- **Windows**: papier shows the system's clipboard history (the one Win+V shows), searched and filtered as on Linux, at
  a shortcut of its own (`picker.shortcut`, Win+Shift+V by default). Enter puts an entry back on the clipboard; an
  entry can be copied as plain text, edited (the edit is a new copy), removed, and the history cleared. The system keeps
  the history and its pins (Settings > System > Clipboard). The release has a `papier-<version>-windows-x64.zip`.
  Its CI builds it and runs its tests on Windows, where the system answers papier's reads; the runner's session has the
  clipboard history off, so reading the entries, putting one back and removing it have not run on a real desktop yet.

### Changed
- Each archive of a release has its SHA-256 in a file beside it (`<archive>.sha256`), in place of `SHA256SUMS.txt`.

## [0.5.2] - 2026-11-09

### Fixed
- Settings: a change (a theme chosen, a switch) is saved when `~/.config/papier` does not exist yet. It was lost, and
  the preferences read back from no file put the old value back. It is gui_toolkit 0.123.0.

## [0.5.1] - 2026-11-09

### Fixed
- Settings: a number with a unit (Max age, in days) no longer makes its line as tall as the page. It is gui_toolkit
  0.122.0.

## [0.5.0] - 2026-11-09

### Changed
- The history is a SQLite database, `history.db`, with SQLite linked into papier. Each change is written at once, in
  one transaction. The history of papier 0.4 (`index` and `blobs/`) is imported at the first start, with its ids,
  times and pins, then deleted.
- The search finds a word anywhere in the text of a copy, not only in its first kilobyte. A word of one or two letters
  is still looked for in the preview.

## [0.4.0] - 2026-11-09

### Added
- **Settings** (Ctrl+, or the gear of the title bar): every preference on four pages (Appearance, Window, History,
  Capture), the search, a switch, a choice, a slider or a field for each, the themes as cards in their own colours.
  A change is saved and applied at once. It is gui_toolkit's `prefs_page` (0.120.0).

### Changed
- `capture.max_bytes` is `capture.size_limit`.

## [0.3.0] - 2026-11-09

### Added
- **The machined finish**, the default (`picker.finish`): bevelled buttons, the search as a sunken well with a ring of
  light when focused, the filters on a carved track. `flat`, `gradient` and `glass` are the others.
- **Themes with a dark and a light version** (gui_toolkit 0.117.0): `picker.theme` names Papier or one of the toolkit's
  25 themes; `picker.mode` shows the system's version and follows it when it changes, or the dark one, or the light one.
  `picker.glow` turns the halos off.

### Changed
- `picker.theme` no longer takes "papier light": the light version is `picker.mode light`.

## [0.2.0] - 2026-11-09

### Added
- **The menu of an entry**: a right click on a row, the Menu key or Shift+F10. Copy, Copy as plain text (rich text),
  Edit…, Open (an address in the browser, a file with its program, the rest as a file of its type), Open with (the
  applications the system knows for the type: gui_toolkit's `desktop.handlers_for_file`), Show in folder (files),
  Save as…, Pin, Remove. Ctrl+O opens, Ctrl+S saves as.
- **The edit view**: Ctrl+E or the pencil puts the text of an entry in an editor. Ctrl+Enter copies it as a new entry;
  Ctrl+S saves it in place of the entry (its place and its pin kept); Escape leaves.

### Fixed
- **The preview follows an edit**: it was kept by the entry's id, which an edit does not change.

## [0.1.6] - 2026-11-09

### Fixed
- **papier is in no task bar while hidden** (gui_toolkit 0.114.2): started with `--hidden`, its window was a toplevel
  with no picture, and ShojiWM's task bar listed it. The toplevel is now made when the window shows.

## [0.1.5] - 2026-11-09

### Fixed
- **No spin at the end of a wait** (gui_toolkit 0.114.1): on Wayland, a wait with less than a millisecond left returned at
  once, and the loop woke about 150 times before its deadline.

## [0.1.4] - 2026-11-09

### Fixed
- **The search field is one box**: the field drew its own square focus ring inside the rounded search box. The box is now
  the toolkit's `field_frame`: one surface and one rounded focus ring around the icon and the field.

## [0.1.3] - 2026-11-09

### Fixed
- **The grip is grey**: its lines asked the theme for a colour name it lacks, and got the violet that marks a missing
  name. They take the weak text's colour, finer and shorter.

## [0.1.2] - 2026-11-09

### Added
- **A grip in the title bar**: three faint lines between the search and the filters mark a place reserved to move the
  window.

## [0.1.1] - 2026-11-09

### Fixed
- **The window takes the keyboard when it shows**: papier asks the compositor for the focus (`xdg-activation`). ShojiWM's
  Windows 7 configuration did not focus it, so the arrows and the search did nothing until a click.
- **The tray icon shows**: panels that read the icon in one call (Quickshell, Waybar) showed the "missing icon" pattern.
- **The selection moves at once over images**: a picture is decoded on a thread of its own, and the newest selection
  wins. A 4K screenshot took about 180 ms to decode, and the window waited for it at each step.

## [0.1.0] - 2026-11-09

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
[0.1.0]: https://github.com/sachahjkl/papier/releases/tag/v0.1.0
[0.1.1]: https://github.com/sachahjkl/papier/releases/tag/v0.1.1
[0.1.2]: https://github.com/sachahjkl/papier/releases/tag/v0.1.2
[0.1.3]: https://github.com/sachahjkl/papier/releases/tag/v0.1.3
[0.1.4]: https://github.com/sachahjkl/papier/releases/tag/v0.1.4
[0.1.5]: https://github.com/sachahjkl/papier/releases/tag/v0.1.5
[0.1.6]: https://github.com/sachahjkl/papier/releases/tag/v0.1.6
[0.2.0]: https://github.com/sachahjkl/papier/releases/tag/v0.2.0
[0.3.0]: https://github.com/sachahjkl/papier/releases/tag/v0.3.0
[0.4.0]: https://github.com/sachahjkl/papier/releases/tag/v0.4.0
[0.5.0]: https://github.com/sachahjkl/papier/releases/tag/v0.5.0
[0.5.1]: https://github.com/sachahjkl/papier/releases/tag/v0.5.1
[0.5.2]: https://github.com/sachahjkl/papier/releases/tag/v0.5.2
