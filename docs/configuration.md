# Configuration

Every setting of papier is a preference: a name, a type, a default value and limits. Read them all with their values:

```sh
papier prefs
```

Change one. Papier saves it in `$XDG_CONFIG_HOME/papier/prefs`, and the running papier reads it again at once:

```sh
papier set history.max_entries 5000
papier set appearance.mode light
```

Set one for a single run: `papier --pref appearance.font_size=16`.

The settings page (Ctrl+,) shows them all, and exports them to JSON, TOML or INI, or to papier's own format, which it
imports back.

## The common settings

The look (`appearance.*`: the theme, light or dark, the finish, the glow, the text size, the zoom, the density...), the
text and fonts (`appearance.text.*`), the window (`window.system_title`, `window.toast_position`), the scrolling
(`scrolling.*`), the input (`input.*`), the delays and menus (`timing.*`), the rendering (`rendering.*`), the updates
(`update.auto`, `update.channel`, `update.base_url`) and the messages (`general.messages`, `general.language`) are the
settings that every program of gui_toolkit has. Its
[docs/settings.md](https://github.com/sachahjkl/gui_toolkit/blob/main/docs/settings.md) lists each with its default.
Papier's defaults: the theme `Papier`, the text size 14 px, its own title bar (`window.system_title` off).

`appearance.theme` is `Papier`, a theme of gui_toolkit by its name (Midnight, Graphite, Nord, Dracula, Gruvbox, Tokyo
Night, Catppuccin, Rosé Pine, Kanagawa, One Dark, Solarized…), or one of your own: Settings > Appearance links to
`$XDG_CONFIG_HOME/papier/themes.txt`, made with a commented guide at the first click and read again each time it is saved.

Papier reads `appearance.text.ui_font`, `appearance.text.mono_font` (the text of the entries) and
`appearance.text.emoji_font` at the start. `general.menu` and `general.autostart` are papier's Setup's and
`papier install`'s.

## Papier's own

On Windows, the system keeps the history (Settings > System > Clipboard): the `history.*`, `capture.*` and
`clipboard.*` preferences are Linux's, and `window.shortcut` and `window.follow` are Windows's.

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
| `capture.size_limit` | bytes, 1K to 2G | 64M | A representation larger than this is not recorded. Accepts `K`, `M`, `G`. |
| `capture.ignore_secrets` | boolean | true | Do not record what a password manager marks as secret (`x-kde-passwordManagerHint`). |
| `capture.ignore_mimes` | text | empty | MIME types, separated by commas: a copy that offers one of them is not recorded. |
| `clipboard.keep` | boolean | true | When the program that owned the clipboard quits and empties it, put the last entry back. |
| `paste.on_select` | boolean | true | An entry chosen (Enter, a double click, Alt+1…9) is pasted into the program papier was called from: the window hides and papier presses `paste.keys` there. |
| `paste.keys` | text | Ctrl+V | The keys papier presses to paste: Ctrl+V in most programs, Ctrl+Shift+V in a terminal, Shift+Insert in both on many systems. Ctrl, Shift, Alt, Win and a key, joined by `+`. |
| `window.close_on_copy` | boolean | true | Hide the window when an entry is copied. |
| `window.width` | integer, 320 to 4000 | 900 | The width of the window at its first start, in logical pixels. |
| `window.height` | integer, 240 to 4000 | 560 | The height of the window at its first start, in logical pixels. |
| `window.follow` | pointer, focus | pointer | Windows: the screen the window shows on. `pointer`: the one under the mouse pointer. `focus`: the one of the window in front. |
| `window.shortcut` | text | Ctrl+Shift+ù | Windows: the keys that show the history from any program. In the settings, click the field and press the keys. As text: Ctrl, Shift, Alt, Win and a key (a letter, a digit, F1 to F12, Space…, or the character a key types: ù), joined by `+`. Win+V stays the system's. |

After the first start, papier keeps the size that you give the window; `window.width` and `window.height` apply again
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
