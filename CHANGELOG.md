# Changelog

All notable changes to papier are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [0.20.2] - 2026-11-13

### Changed
- **One licence at one price, and a new pricing page**: the papier licence is now one edition at 15 €, paid once, taxes included; the Patron edition is gone. The pricing page shows papier's icon and name, one card with the price, what the licence gives as a list, one button, then "Before you buy". The licence is named "papier licence" on the site, at checkout and in the licence file.

## [0.20.1] - 2026-11-13

### Fixed
- **The Windows download is there again**: 0.20.0 had no Windows archive (its build stopped on a check that read the files with Windows line endings). This version has it.

## [0.20.0] - 2026-11-13

### Added
- **A menu in the edit view**: a right click in the text offers Undo, Redo, Cut, Copy, Paste, Delete and Select all, with their keys. Each menu is now as wide as its longest line.
- **A log and crash reports**: papier writes its errors to `papier.log` in the `logs` folder of its state folder (`~/.local/state/papier`, `%LOCALAPPDATA%\papier\state`). A crash writes a report in its `crashes` folder. At the next start, papier says that it stopped and where the report is. Nothing is sent anywhere.
- **Messages in the system's notifications**: what papier did (copied, saved, removed) is said by a notification of the system, or in the window where the system shows none. Settings > General > Messages chooses the system, the window, or nowhere. A failure is always said.
- **Diagrams and tables in Markdown entries**: the preview draws a ```mermaid block of a Markdown entry as its diagram, in the theme's colours. A block that is not a valid diagram shows its text, with the reason. A text that is only a table (a header row with its `|---|---|` separator under it) is shown as a table, not as raw text.
- **A licence to support papier**: Settings > General > Licence registers a licence key, pasted or read from its file, and says whom it is registered to. The key is checked on your computer, with no network. Papier stays free and does the same without a licence.
- **Export and import of the settings**: the settings' sidebar exports them to JSON, TOML, INI or papier's own format, and imports papier's own format back, to carry them to another computer.
- **Themes of your own**: Settings > Appearance links to a themes file. The first click makes it with a commented guide and opens it in your editor. Each theme that you write there shows with the others as soon as the file is saved.
- **Papier in French**: the window, the menus, the command palette, the messages, the settings, the setup dialog and the dates speak French. Settings > General > Language chooses System, English or Français; System follows the language of the system. The choice takes effect at the next start.

### Changed
- **Windows: the window's size is kept in the state folder** (`%LOCALAPPDATA%\papier\state\window`), beside the log, and no longer beside the preferences. Papier forgets the size of its window once.
- **The QR code dialog in the middle of the window**: Show as a QR code (Ctrl+Shift+Q) opens its dialog in the middle of the window, not near its top.
- **A faster command palette and keyboard shortcuts sheet**: the palette (Ctrl+K) sorts its actions and settings again only when you type or a setting changes, and the sheet of the keys (F1) builds only the lines in view.
- **Ages in one short unit**: the list, the preview and `papier list` say "now", "4m", "2h", "5d" or "1w".
- **A new settings page**: more settings, each on its page: zoom, density, rounding, animations, fonts and text rendering, scrolling, key and button repeats, tooltip and menu delays, rendering, where messages show, a place in the application menu and a start with the session. The technical ones are under a folded Advanced part of their page. The sidebar is resized with the mouse, and its foot opens the settings file. The settings have new names: the look is `appearance.theme`, `appearance.mode`, `appearance.finish`, `appearance.glow` (a level from 0 to 1) and `appearance.font_size`; the window's are `window.system_title`, `window.close_on_copy`, `window.width`, `window.height`, `window.shortcut` and `window.follow`. The `picker.*` names are gone: set again what you had changed.

### Fixed
- **Save as no longer freezes the window**: the system's file dialog no longer blocks the window. Papier saves the entry once you choose a name.

## [0.19.2] - 2026-11-13

### Fixed
- **Choosing an entry pastes it again** (Linux): papier pressed the paste keys as its window went, before the compositor gave the focus back to the other program (ShojiWM), so nothing was pasted. It now waits until another window has the focus, half a second at most. Also: the text read in an image and a QR code's content go on the clipboard with the window staying open (they were pasted, and the window closed); the preview says "Reading the text of the image…" with a moving bar while it reads; a right click on an image in the preview opens the entry's menu, the same as on its row, with "Copy the text of the image".

## [0.19.1] - 2026-11-12

### Changed
- **The machined finish in the light version too**: bevelled buttons, sunken fields and carved lines are drawn on the light themes as well, with light shadows and strong highlights, where they were drawn flat (gui_toolkit 0.229.0).

### Fixed
- **The settings say where the preferences file really is**: their foot showed `~/.config/papier/prefs` on Windows too, where the file is in `%APPDATA%\papier\prefs`.

## [0.19.0] - 2026-11-12

### Added
- **The preview shows what a text is**: Markdown is shown rendered (headings, lists, tables, code, links), with Ctrl+Shift+M or a button for its source; a diff shows its lines numbered and coloured; code is coloured in more languages (Java, C#, Kotlin, Swift, PHP, Ruby, Lua, Zig, Nix, YAML, TOML, HTML, XML, CSS and more), in the edit view too. The text is drawn in the system's monospace font (Cascadia Mono or Consolas on Windows), which reads better than the one papier carried, at 125 % above all.

## [0.18.1] - 2026-11-12

### Fixed
- **The window no longer freezes after a copy** (Linux, Wayland): with NVIDIA's driver, a compositor that held back its word that it showed the window's picture (ShojiWM, counting the window on the wrong screen) left the window without a new picture for good. Papier now presents in a way that never waits, waits for that word a quarter of a second at most, and draws at once after a key or a click (gui_toolkit 0.221.1).

## [0.18.0] - 2026-11-12

### Added
- **The text of a copied image, a QR code's content, and the thumbnails of copied files**: Ctrl+Shift+T (or the entry's menu, or the palette) copies the text read in an image, with the system's text recognition (on Linux, Tesseract). When a copied image holds a QR code, one click copies what it says. A copied file's row shows the system's thumbnail of it: a PDF's first page, a video's frame.

### Changed
- **The window never waits for the disk**: the search, the preview of the selected entry, saving or opening an entry, a drag and the settings are read and written on a thread of their own. Typing a search or moving through a long history stays smooth while the disk is slow or busy.

### Fixed
- **A dialog's Enter no longer opens the entry behind it**, and a paste into the search no longer waits for a slow program's clipboard. Also: each page of the settings restores its defaults with one button, and the command palette's last line is never cut in half (gui_toolkit 0.207.0).

## [0.17.7] - 2026-11-12

### Fixed
- **The window at rest uses no processor again** (Wayland): since 0.17.6 an open window drew a new picture at every refresh, and kept a core busy. Also: the scroll bars look like a thing to take, the dialogs' rounded corners are clean, and a menu's search edits as a field does (gui_toolkit 0.199.0).

## [0.17.6] - 2026-11-12

### Changed
- **Images are faster, and the palette's field follows its corners**: copied images and their thumbnails are read and written in half the time or less, and the command palette's darker field no longer shows a second, rounder corner inside the dialog's (gui_toolkit 0.196.2).

## [0.17.5] - 2026-11-11

### Changed
- **A clearer command palette**: a magnifier before the search and the number of results at the end of its line, a line under it, the selected command in a dark well with a bar of the accent, and what the search found readable, in the palette and in the list.

## [0.17.4] - 2026-11-11

### Changed
- **Square rows**: a selected row of a list, a table or a menu fills its whole width with square corners, and a table's tinted cell is square too. The Console theme is named Kernel (gui_toolkit 0.191.1).
- **The command palette's field stands out**: it keeps its place from edge to edge, on a darker background, so the place to type is clear.

## [0.17.3] - 2026-11-11

### Fixed
- **Escape closes the dialog, not the window**: with the Setup, the palette, the QR code or the sheet of the keys open,
  the keys are the dialog's (gui_toolkit: an open dialog holds the keys).

## [0.17.2] - 2026-11-11

### Fixed
- Linux: a desktop whose portal says "no preference" for light or dark follows its GTK theme again (dark here): the
  window showed its light version, and the machined finish flat (gui_toolkit's `platform.dark_mode_preferred`).

## [0.17.1] - 2026-11-11

### Fixed
- An image no longer shows too large for a moment when its entry is selected: it fits from its first frame
  (gui_toolkit's `ui.preview`).

## [0.17.0] - 2026-11-11

### Added
- The edged finish (`picker.finish edged`: the machined reliefs drawn crisp, square corners) and the Console theme
  (gui_toolkit 0.187.0).
- `picker.system_title`: the system's title bar in place of papier's own, switched at once (Windows, X11, KDE).

### Changed
- The Linux archive is built in Debian 12 (glibc 2.36): it starts on Debian 12, Ubuntu 22.04 and later. The checks run in
  the flake's shell, as on a developer's machine.
- Bold text in the window is the font's own bold, no longer a thickened regular (gui_toolkit 0.187.0).

## [0.16.0] - 2026-11-11

### Added
- The settings show papier's version at the bottom of their pages (gui_toolkit 0.185.0).
- An update shows in the status bar as a button: Install 0.x, Downloading…, then Restart to update, which restarts papier
  on the new version (gui_toolkit's `prefs_page.update_badge`).

### Fixed
- The machined finish at a small scale: the rings of a switch, a slider and a choice are clean in their curves, with no
  break nor change of grey (gui_toolkit 0.186.0).

## [0.15.0] - 2026-11-11

### Added
- The search lights its words in the list, the palette and the settings (gui_toolkit 0.184.0).
- Actions and settings have other words they are found by: "delete" finds Remove, "dark" the theme, "hotkey" the
  shortcut (gui_toolkit 0.183.0: tags).

## [0.14.0] - 2026-11-11

### Added
- The command palette finds the settings: one chosen opens the settings on it alone, its page underneath
  (gui_toolkit 0.182.0: `prefs_page.palette_commands`, `prefs_page.show`).
- Restart Papier and Quit Papier (Ctrl+Q), in the palette.

## [0.13.0] - 2026-11-11

### Added
- An image zooms and moves in the preview: the wheel zooms around the pointer, a drag moves it, a double click shows its
  pixels and fits it again; a bar in its corner shows the zoom and −, +, 1:1, Fit (gui_toolkit 0.180.3: `ui.preview`).

### Changed
- The window shown again shows the history, not the settings it was hidden on.
- The machined finish: a choice of the settings (Machined, Flat…) is a slot with a raised key; a switch's edges are
  clean; its labels are centred on their key (gui_toolkit 0.180.3).

## [0.12.0] - 2026-11-11

### Added
- Code in colours: a copied script, query or snippet (the shell, Python, SQL, Odin, Go, Rust, C, JavaScript, PowerShell,
  JSON) is shown in the theme's colours, its language found from the text and named in the entry's header; the edit
  view keeps the colours (gui_toolkit 0.176.0: `syntax.guess`, `ui.code_runs`).
- The command palette (Ctrl+K, Ctrl+Shift+P): every action, searched as you type; F1 shows every key. The palette, the
  menus, the tooltips and the keys come from one table of actions.
- Several entries at once: a Ctrl or Shift click marks entries, Ctrl+Shift+A marks all; Enter copies their texts as one
  new entry, Ctrl+P pins them, Shift+Delete removes them; the menu acts on them.
- An entry as a QR code (Ctrl+Shift+Q, the menu, the button beside the entry): text, an address, a path, for a phone.
- An entry dragged out of the list into another program: its text, its markup, its picture, its files.
- Middle-click autoscroll in the list, the preview and the settings (gui_toolkit 0.174.0).
- Linux (Wayland): `papier toggle` from a launcher hands its activation token to the running papier, whose window gets
  the keyboard even from a strict compositor.
- The search field and the editor have a menu on a right click: Undo, Redo, Cut, Copy, Paste, Delete, Select all
  (gui_toolkit 0.172.0).

## [0.11.0] - 2026-11-10

### Added
- An image's row shows a thumbnail of it, so a scroll through the list tells the images apart. Thumbnails are made beside
  the window for the rows in view only, the preview first (gui_toolkit 0.162.0: `paint.rgba_shrink`).

## [0.10.2] - 2026-11-10

### Changed
- Windows: the window shows on the screen under the mouse pointer, with no click needed there. `picker.follow focus`
  (Settings > Window) takes the screen of the window in front instead (gui_toolkit 0.157.0).

## [0.10.1] - 2026-11-10

### Fixed
- Windows: the window shows on the screen you work on (the one of the window in front, else the one under the pointer),
  at the same place of that screen, not on the screen it was last shown on.
- The site offers the download of your system (Windows or Linux), and the other one under it (gui_toolkit 0.151.0).
- The Setup's options are one per line: a long label wraps in its box instead of running past it (gui_toolkit 0.150.0).

## [0.10.0] - 2026-11-10

### Added
- Papier updates itself (Windows, and a Linux copy installed with `papier install`): the installed copy checks the latest
  release once a day, downloads the new program, checks it against its signed manifest and puts it in place, then gives
  way to it when its window is hidden. Settings > Updates says the state, checks now and installs; `update.auto` turns
  it off. A copy from Nix is left to Nix. (gui_toolkit 0.147.0: `update.Updater`, `gt:http`, `prefs_page`'s update line,
  `setup.updated`)
- A release publishes the programs alone and their update manifests, signed with papier's update key.

## [0.9.0] - 2026-11-10

### Changed
- Windows: the shortcut is **Ctrl+Shift+ù** by default, as on Linux. Win+Shift+V was Windows's own (it cycles through
  the notifications): the shortcut did nothing.
- Windows: the shortcut is recorded, not typed: in the settings, click the field and press the keys (gui_toolkit's
  `ui.hotkey_field`). A shortcut that cannot be used says why, under its line and in the status bar.

### Fixed
- Windows: papier.exe has its icon (the Start menu's shortcut, Settings > Apps, the window, the taskbar), its manifest
  and its version.
- Windows: after an install, the Setup no longer asks to repair it (an install in the default folder is recorded:
  gui_toolkit 0.143.0).

## [0.8.1] - 2026-11-10

### Fixed
- The window's panes join: the search's halo is no longer cut under the title bar, the rule under it has its lit line,
  and the list and the entry meet at the splitter's rule with no gap beside it (gui_toolkit 0.138.0).

## [0.8.0] - 2026-11-09

### Added
- **The entry chosen is pasted where you were** (`paste.on_select`, on): Enter, a double click or Alt+1…9 puts it on the
  clipboard, hides the window and presses Ctrl+V for the program that has the keyboard again (`paste.keys` for other
  keys: Ctrl+Shift+V in a terminal). On Wayland it needs a compositor that lets a program type for another
  (`zwp_virtual_keyboard_v1`: wlroots compositors, ShojiWM); on Windows it is SendInput. It is gui_toolkit 0.135.0's
  `send_hotkey`.
- Setup (Windows): the start with the session and papier on the PATH are boxes of the dialog.

## [0.7.2] - 2026-11-09

### Changed
- The icons are gui_toolkit's Lucide set (0.129.0): papier carries no copy of the font of its own.

## [0.7.1] - 2026-11-09

### Changed
- Windows: the Setup's dialog can be resized from its edges and its corner; what it says scrolls when it is small, its
  buttons stay under it. It is gui_toolkit 0.127.0.

## [0.7.0] - 2026-11-09

### Added
- **Windows: Setup.** A start of the downloaded `papier.exe` offers to install papier for you: the program in
  `%LOCALAPPDATA%\Programs\papier`, the Start menu, the start with the session, `papier` on the PATH with `papier.com`,
  and the Settings > Apps entry. The same dialog repairs, upgrades or removes the install (`papier --setup`; Settings >
  Apps > Papier > Uninstall opens it). It shows where everything is; a path is shown whole on hover and copied by its
  button. It is gui_toolkit's `setup`.
- **Windows**: `papier.com`, the console launcher, beside `papier.exe` (`papier install` writes it with the PATH entry).
  In cmd or PowerShell, `papier list`, `papier get`, `papier set`… give their output and their exit code; `papier`,
  `papier --hidden` and `papier toggle` give the prompt back. It is gui_toolkit's console launcher.

## [0.6.0] - 2026-11-09

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
[0.20.2]: https://github.com/sachahjkl/papier/releases/tag/v0.20.2
[0.20.1]: https://github.com/sachahjkl/papier/releases/tag/v0.20.1
[0.20.0]: https://github.com/sachahjkl/papier/releases/tag/v0.20.0
[0.19.2]: https://github.com/sachahjkl/papier/releases/tag/v0.19.2
[0.19.1]: https://github.com/sachahjkl/papier/releases/tag/v0.19.1
[0.19.0]: https://github.com/sachahjkl/papier/releases/tag/v0.19.0
[0.18.1]: https://github.com/sachahjkl/papier/releases/tag/v0.18.1
[0.18.0]: https://github.com/sachahjkl/papier/releases/tag/v0.18.0
[0.17.7]: https://github.com/sachahjkl/papier/releases/tag/v0.17.7
[0.17.6]: https://github.com/sachahjkl/papier/releases/tag/v0.17.6
[0.17.5]: https://github.com/sachahjkl/papier/releases/tag/v0.17.5
[0.17.4]: https://github.com/sachahjkl/papier/releases/tag/v0.17.4
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
[0.6.0]: https://github.com/sachahjkl/papier/releases/tag/v0.6.0
[0.7.0]: https://github.com/sachahjkl/papier/releases/tag/v0.7.0
[0.7.1]: https://github.com/sachahjkl/papier/releases/tag/v0.7.1
[0.7.2]: https://github.com/sachahjkl/papier/releases/tag/v0.7.2
[0.8.0]: https://github.com/sachahjkl/papier/releases/tag/v0.8.0
[0.8.1]: https://github.com/sachahjkl/papier/releases/tag/v0.8.1
[0.9.0]: https://github.com/sachahjkl/papier/releases/tag/v0.9.0
[0.10.0]: https://github.com/sachahjkl/papier/releases/tag/v0.10.0
[0.10.1]: https://github.com/sachahjkl/papier/releases/tag/v0.10.1
[0.10.2]: https://github.com/sachahjkl/papier/releases/tag/v0.10.2
[0.11.0]: https://github.com/sachahjkl/papier/releases/tag/v0.11.0
[0.12.0]: https://github.com/sachahjkl/papier/releases/tag/v0.12.0
[0.13.0]: https://github.com/sachahjkl/papier/releases/tag/v0.13.0
[0.14.0]: https://github.com/sachahjkl/papier/releases/tag/v0.14.0
[0.15.0]: https://github.com/sachahjkl/papier/releases/tag/v0.15.0
[0.16.0]: https://github.com/sachahjkl/papier/releases/tag/v0.16.0
[0.17.0]: https://github.com/sachahjkl/papier/releases/tag/v0.17.0
[0.17.1]: https://github.com/sachahjkl/papier/releases/tag/v0.17.1
[0.17.2]: https://github.com/sachahjkl/papier/releases/tag/v0.17.2
[0.17.3]: https://github.com/sachahjkl/papier/releases/tag/v0.17.3
