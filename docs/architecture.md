# Architecture

Papier is one program in [Odin](https://odin-lang.org) on [gui_toolkit](https://github.com/sachahjkl/gui_toolkit) (the
`ext/gui_toolkit` submodule, the collection `gt`). This page says how its parts fit, and why.

## One process, three threads

```
papier --hidden ─┬─ the window's thread (app.odin, view.odin)
                 │     the window, hidden or shown; the tray icon; the history as it reads it
                 │
                 ├─ the watcher thread (watcher.odin)
                 │     the clipboard (wlclip), the history it writes (history), the instance socket
                 │
                 └─ the decoder thread (decoder.odin)
                       the picture of the selected image, decoded for the preview
```

- **The watcher** sleeps in one `poll` on three descriptors: the Wayland connection of the data-control protocol, the
  instance socket (commands of other processes), an eventfd (commands of the window). It is the only writer of the
  history. Each change is one transaction of the database; then it bumps a version, and the window reads the list again
  when the version moves.
- **The window** sleeps in the toolkit's wait: its own Wayland connection, its wake, the session bus (the tray). It asks
  the watcher by a queue (copy, pin, delete, clear) and the watcher asks it by another (show, hide, toggle, reload, quit),
  in order: a hide then a show that come between two steps of the loop end shown.

At rest both threads sleep: 0 % CPU, hidden or shown (the caret's blink aside).

## Why one process

A clipboard manager on Wayland must hold a data-control connection for the whole session, and its window must come fast.
A window that hides instead of closing keeps the GPU device, the fonts and the history in memory: `papier toggle` shows it
in a few milliseconds (a new surface and its first configure, then a frame). gui_toolkit's `host_hide` / `host_show` do
this: on Wayland the surface and its role go at the hide and new ones come at the show, so no state of the last frames
waits in the compositor.

A second `papier` takes the instance name (`gt:instance`: a lock file and a Unix socket in `$XDG_RUNTIME_DIR`), finds it
taken, sends its command (`show`, `toggle`, `copy 42`…) and ends.

## The clipboard (src/wlclip)

A Wayland client hears of the clipboard only while one of its windows has the focus. A manager uses data-control instead:
`ext-data-control-v1`, or `zwlr-data-control-unstable-v1` where only that one is offered (both have the same requests).
`wlclip` opens libwayland-client with `dlopen`, builds the protocol's tables by hand, binds the manager and a device on the
seat, and reports each new selection with its MIME types. It reads a type over a pipe while it keeps serving the
connection, and it can own the selection: it then answers each `send` with the bytes it holds.

A selection that comes from papier's own source is not recorded again. When the selection goes empty (its owner quit),
the watcher puts the last entry back.

## What a copy becomes (src/capture.odin)

`plan_capture` picks the types to read from those offered: one text type (stored as `text/plain;charset=utf-8`), the HTML,
one image type, one file list; a secret or an ignored type stops it. `classify` makes the entry: its kind (files, then
text or rich text, then image), its key (the hash of its main type) and its preview. These two procedures are pure and
tested.

## The history (src/history)

One SQLite database, `history.db`, in WAL mode. SQLite is linked into papier: its amalgamation is in `ext/sqlite`, and
`papiertool build` compiles it (with FTS5).

- **entries**: an entry's id, the time of its last copy, its pin, its kind, its key and its preview.
- **reps**: its types, in order: the MIME type, the hash of the bytes, their size.
- **blobs**: the bytes, by their 64-bit XXH3 hash. The same bytes are stored once.
- **texts**: the whole text of each entry, in a full-text index (FTS5, trigrams): the search finds a word past the
  preview.
- **Transactions**: each change (a copy, an edit, a removal, a trim) is one transaction: another connection sees the old
  list or the new one. The image decoder reads the bytes through a connection of its own.
- **Keys**: a copy whose key is already there moves that entry to the top.
- **Import**: at open, the history of papier 0.4 (a text index and a directory of blobs) goes into the database in one
  transaction, then its files are deleted (src/history/import.odin).
- **Limits**: `trim` drops the entries past the count or the age, pinned ones aside; `collect` deletes the bytes that no
  entry names.

## The window (src/view.odin)

The interface is built again at each frame (immediate mode), and only when something changed. The list is the toolkit's
virtual list: it builds the rows in view, whatever the length of the history. The search looks for each word of three letters or more in
the whole text (the full-text index), and for a shorter word in a lower-case copy of the preview. An image is decoded on a thread of its own (src/decoder.odin) when its
entry is selected: the newest selection wins, and the window makes one texture of the picture when the decoder wakes it. The
same thread makes the list's thumbnails (src/thumbs.odin): at each build the window says which image rows in view still
want one, in place of what it said before, and the thread shrinks each picture to 72 pixels on its shorter side; the
window keeps 300 of their textures, the least lately shown going first.

## Updates (src/updates.odin)

gui_toolkit's `update.Updater` runs on a thread of its own: the installed copy checks the manifest of the latest release
20 seconds after its start and then once a day, downloads the program it names, checks its size and SHA-256 against the
manifest, whose Ed25519 signature it checked first, and puts it in place of the running program. The thread wakes the
loop; the loop reads the state at each turn. Once the new program is in place, papier ends as soon as its window is
hidden, and the new one starts hidden (`--hidden`). Settings > Updates shows the state (`prefs_page`'s update line).

## Tests

- Unit tests: `src` (capture, commands, window state), `src/history`, `tools/papiertool` (versions, the changelog).
- `papiertool live`: the real program in a sway with no screen; copies of each kind through wl-clipboard, a secret, a
  copy again, an entry put back byte for byte, the clipboard emptied, the window read, searched, hidden and shown over
  the DevTools protocol.
- gui_toolkit's own desktop tests cover the hide and the show of a window with its renderer, and the loop's rest.
