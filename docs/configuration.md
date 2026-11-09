# Configuration

Every setting of papier is a preference: a name, a type, a default value and limits. Read them all with their values:

```sh
papier prefs
```

Change one. Papier saves it in `$XDG_CONFIG_HOME/papier/prefs`, and the running papier reads it again at once:

```sh
papier set history.max_entries 5000
papier set picker.mode light
```

Set one for a single run: `papier --pref picker.font_size=16`.

## The preferences

| Name | Type | Default | What it does |
|---|---|---|---|
| `history.max_entries` | integer, 0 to 1000000 | 1000 | How many entries the history keeps, pinned ones aside. 0: no limit. |
| `history.max_age_days` | integer, 0 to 36500 | 0 | Entries older than this many days go, pinned ones aside. 0: no limit. |
| `history.persist` | boolean | true | Keep the history on the disk across sessions. Off: it lives in `$XDG_RUNTIME_DIR` and goes at the end of the session. Read at the start. |
| `capture.text` | boolean | true | Record text. |
| `capture.html` | boolean | true | Record the HTML that comes with a copy from a browser or an editor. |
| `capture.image` | boolean | true | Record images. |
| `capture.files` | boolean | true | Record files copied in a file manager. |
| `capture.primary` | boolean | false | Also record the primary selection (the text selected with the mouse). |
| `capture.max_bytes` | bytes, 1K to 2G | 64M | A representation larger than this is not recorded. Accepts `K`, `M`, `G`. |
| `capture.ignore_secrets` | boolean | true | Do not record what a password manager marks as secret (`x-kde-passwordManagerHint`). |
| `capture.ignore_mimes` | text | empty | MIME types, separated by commas: a copy that offers one of them is not recorded. |
| `clipboard.keep` | boolean | true | When the program that owned the clipboard quits and empties it, put the last entry back. |
| `picker.close_on_copy` | boolean | true | Hide the window when an entry is copied. |
| `picker.theme` | text | Papier | The colours: `Papier`, or a theme of gui_toolkit by its name (Midnight, Graphite, Nord, Dracula, Gruvbox, Tokyo Night, Catppuccin, Rosé Pine, Kanagawa, One Dark, Solarized…). |
| `picker.mode` | system, dark, light | system | The theme's version. `system` follows the system's light or dark as it changes. |
| `picker.finish` | machined, flat, gradient, glass | machined | How surfaces are drawn. Machined: bevelled buttons, sunken fields, carved lines; a light version is flat. |
| `picker.glow` | on/off | on | The halos of the machined finish: the ring of light around a focused field. |
| `picker.width` | integer, 320 to 4000 | 900 | The width of the window at its first start, in logical pixels. |
| `picker.height` | integer, 240 to 4000 | 560 | The height of the window at its first start, in logical pixels. |
| `picker.font_size` | number, 8 to 40 | 14 | The size of the text, in logical pixels. |

After the first start, papier keeps the size that you give the window; `picker.width` and `picker.height` apply again
when `$XDG_STATE_HOME/papier/window` is deleted.

## Examples

Keep only text, for one week:

```sh
papier set capture.image false
papier set capture.files false
papier set history.max_age_days 7
```

Leave out what an application marks with its own type:

```sh
papier set capture.ignore_mimes "application/x-my-secret, x-special/private"
```

Keep nothing on the disk:

```sh
papier set history.persist false   # read at the next start: papier quit; papier --hidden
```
