# The window: list, search, preview

The window's thread reads nothing itself. Every read is an ask to a worker, and every answer may come late or out of
date. These rules keep what the window shows consistent.

## The list and its view

- The reader keeps the list and computes from it what goes over the whole history: the search, the count of pinned
  entries, an entry by its id. It computes them when the list changes, not in a frame.
- A new list comes with its view, in one hold of the mailbox: the window never shows the view of one list with another.
- An entry the user removes leaves the reader's list at once, and the view comes again without it. The window does not
  wait for the watcher's transaction to see it go.
- A request to the reader never waits: the window takes the mailbox's mutex for a copy, never for a search.

## The search

- It looks for each word of three letters or more in the whole text (the full-text index, trigrams), and for a shorter
  word in a lower-case copy of the preview. A trigram index cannot find a word of one or two letters.
- Each query has a number. The window applies the view of the newest one only, and keeps a newer list aside until that
  view comes. Without this, a fast typist sees the results of an old query over a new list.

## The list beside the preview

The list is the toolkit's foldable side panel (`ui.Side_Panel`, gui_toolkit's `src/md/features/side-panels.md`), at
the left of the preview. `build_body` in `view.odin` builds it.

- **The rule is the toolkit's.** Open, the list is its remembered width (48 % of the window at first, 220 px at
  least). It folds to its rail when the preview would get less than 200 px. It opens again when the preview gets 1 em
  more. No window breakpoint of papier's own: the old splitter clamped the list, which then pushed the preview under
  its least in a narrow window.
- **A manual fold or opening holds until the next crossing** of that threshold, either way. The fold button and a pull
  of the rail's edge are the manual acts.
- **The fold button is in the title bar, after papier's icon.** The list has no row of its own above its entries: its
  first row is an entry, and it scrolls away. The title bar's start is above the list, at the same pixel open and
  folded. Refused: a header row over the list only for the button (a row of height for one icon); the status bar (the
  eye looks for a panel's button at its top).
- **The rail is the list itself, narrow.** It is the same `ui.vlist` with the same state (`app.vl`): the selection, the
  scroll, the keys, a click, a double click (copy), the menu and a drag out act as in the open list. Each row shows only
  its mark: its thumbnail, else its kind's icon, in the accent colour when pinned. The selected row is lit as in the
  list. Its tooltip is its first line. Up and Down move the selection there too: they are the search's keys
  (`move_keys`), and the search keeps the keyboard. Refused: a second list for the rail (a second scroll and selection
  that must follow the first), and a rail of the filters (they are in the title bar already).
- **The width and the fold are remembered** in the window's state (`state.odin`): `split <width>` and
  `fold <words>` (`ui.side_fold_format`). The build asks a write (`state_due`) when the room crosses the threshold, at
  the end of a pull and at a manual fold; the loop writes it after the frame, through the reader. A restart in a window
  of the same size keeps a manual choice; on the other side of the threshold the first build is a crossing.
- **The preview fits its width** (`.Fits_Width`): what it shows (a long line, a picture) asks the row for no width,
  so it never pushes the list's rule or the window's edge.

## The selected entry

- Its text, its code's language and its QR text come from the reader; the newest selection wins. The preview says
  "Loading…" until they come.
- An edit asked meanwhile begins when they come: the edit view needs the whole text, not the preview.
- An image is decoded by the decoder; the newest selection wins, and the window makes one texture when the decoder wakes
  it. The decoder reads the picture for a QR code too, and gives its text with the picture.
- A text, Markdown or code scrolls in a `scroll_y` box. What it holds is sized by its children (`children_sum`): papier's
  base style gives a box a control's height, and content cut to it never overflows the box, which then does not scroll.
- What a text is (plain, code, Markdown, a diff) is `syntax.guess`'s answer, given by the reader with the text. A text
  that is only a table (a header row of `|` cells, then a row of `---` cells, `:` for the alignment) is Markdown: the
  toolkit's guess knows that shape. A text with `|` and no such separator row stays plain: a pipe alone is no table.
- A Markdown doc is read on the reader's thread, once per answer. Each closed ```` ```mermaid ```` block is laid out
  there too (`diagrams_make`), for the light and the dark theme: a layout takes milliseconds, and a theme change then
  lays out nothing. The window only draws the picture of the theme shown. At most 32 diagrams are laid out per entry;
  the blocks after them show as code.
- The diagrams go through `markdown.View_Options.code`, the toolkit's hook for a fenced block: papier draws no Markdown
  of its own. The view finds a block's diagram by its number among the fenced blocks (`markdown.Code.fence`), not by its
  text. A block that is no diagram shows its code, with mermaid's reason above it.
- The keyboard stays in the search, so Page Up / Page Down move in the list and Shift with them scrolls the preview. A
  focusable preview was refused: a click on it would take the keyboard from the search, where typing must go.

## Several entries

The list's selection is the toolkit's `Item_Selection` (gui_toolkit's `src/md/features/selection.md`): clicks with
Ctrl, Shift and Ctrl+Shift, and the keys the search leaves to the list (`move_keys` in `view.odin`). Each key gives the
row it goes to; `item_selection_move` gives its modifiers their meaning.

- **The preview is the cursor's entry**, and so are Edit, Open, Save as, the QR code and the text of an image: they show
  or change one entry. Ctrl and the arrows move the cursor alone, so the preview can show an entry of the selection, or
  one outside it, without changing it.
- **Copy, Pin and Remove act on the selection.** Copy of several joins their texts in the list's order, a line between
  two, as a new entry put on the clipboard (the reader's `Join`). A copy of the first entry alone, or a choice of one,
  was refused: Copy on several selected would then drop what the person chose. Pin pins them all when one is not pinned.
- **Shift+Page Up and Down stay the preview's pages**, so Shift extends with the arrows and with Ctrl+Shift+Home and
  End only (Ctrl+Home is the list's Home: the search keeps Home).
- **Escape takes several entries back to the cursor's**, then clears the search, then hides: the toolkit's rule
  (`item_selection_escape`), read by papier because the search has the keyboard.
- After Copy of several or Remove, the cursor's row is selected alone: the next Enter copies what the cursor shows.

## Thumbnails

At each build the window says which image rows in view still want a thumbnail, in place of what it said before. A row
that scrolled away is no longer asked for. The decoder shrinks each picture to 72 pixels on its shorter side; the window
keeps 300 textures, the least lately shown going first. The system's thumbnails of copied files go to the slow worker,
because a system's thumbnailer can run 30 seconds.

## The text of an image (OCR)

OCR takes a second or more, so it runs on the slow worker: one reading at a time, the newest ask first. At its start the
slow worker asks whether the system can read text (`ocr.available` loads a library); the window offers the action only
once it says so.

## The overlay (`window.overlay`)

Off by default. On, the window is a layer surface (wlr-layer-shell, the toolkit's `open_overlay`) above every window,
as a launcher's (rofi, fuzzel): the desktop dimmed, the history in a panel at the centre, the keyboard the search's from
the showing. An ordinary window is placed by the compositor, which a tiling one tiles: a person had to write a rule of
their own to float it.

- **The surface covers the output; the panel is drawn in it.** A click on the dimmed part hides the window, as Escape
  does: the panel is `.Clickable` and `.Press_Stop` (the toolkit stops a press only on a clickable box), so a press on
  it, where no control is, is never one on the dim under it. Refused: a layer surface the
  panel's size. The click beside it would reach the window below and papier would stay on top of it, and nothing
  would show that the desktop waits.
- **The keyboard is exclusive** (`Overlay_Keyboard.Exclusive`): what is typed goes to the search with no click, and no
  other window gets a key until the window hides. On-demand was refused: the overlay would take the keyboard only once
  clicked, and the shortcut's first keys would go to the window below.
- **The output is the compositor's choice at each show** (the overlay's area is left zero): the one the person works on,
  not the one where papier first showed.
- **The panel is `window.width` by `window.height`**, within the output less 2 em on each side. An overlay has no place
  and its size is its output's: `window.placement` keeps the ordinary window's, untouched by the overlay.
- **Chosen at the start** (`restart`): the window's kind is fixed when it opens. A compositor without the layer shell
  (GNOME) gets the ordinary window, and the log says why.
- The overlay opens shown (`host_open`); papier hides it before its first frame, and it shows at `app_show` as the
  ordinary window does. A hide takes its layer surface away; a show makes a new one.
