# Papier on the desktop

## Windows

Windows 10 (1809) or later, with the clipboard history on (Settings > System > Clipboard > Clipboard history): papier
shows the system's history, the one Win+V shows. The system keeps it (its last 25 copies, and the ones you pin with
Win+V); papier reads it, puts an entry back, removes one, clears it.

Unzip the archive and start `papier.exe`: its Setup offers to install it for you. Install copies it to
`%LOCALAPPDATA%\Programs\papier` and writes a launcher in the Start menu, `papier` on your PATH, its start with the
session (the `Run` key of your user: `papier --hidden`, in the notification area) and the Settings > Apps entry. The
same dialog repairs, upgrades (start the newer `papier.exe`) or removes the install: `papier --setup`, or Settings >
Apps > Papier > Uninstall. Keep standalone runs the copy where it is, and the Setup does not ask again.

`papier install` integrates the copy where it is, with no Setup (`--no-autostart`, `--no-path`: leave a part out). With the PATH comes `papier.com` beside `papier.exe`:
papier has a window and no console of its own, so in cmd or PowerShell `papier` runs `papier.com`, which gives a command
(`papier list`, `papier set`…) its output and its exit code, and gives the prompt back at once for `papier` and
`papier toggle`. Win+Shift+V shows the window from any program
(`papier set picker.shortcut <keys>` for others). The system reads its history only for the program in the foreground:
papier reads it again each time its window shows.

What Windows does not let a program do: pin an entry (pin it in Win+V), or change an entry in place (an edit is a new
copy, and the old entry goes).

## Linux: requirements

- A Wayland compositor with a data-control protocol: `ext-data-control-v1` or `zwlr-data-control-unstable-v1`. Hyprland,
  Sway, KDE Plasma (6.2 and later), river, niri, labwc, Wayfire and the other wlroots compositors have one.
  **GNOME has none:** papier cannot watch the clipboard there.
- Vulkan (any driver, Mesa included), fontconfig, libxkbcommon.
- For the icon in the notification area: a StatusNotifierItem host (Waybar's `tray`, KDE's panel, …). Without one,
  papier works the same with no icon.

## Linux: install

`papier install` integrates the program where it is (a downloaded release, a build, a Nix profile):

- a launcher in the applications menu, with its icons;
- a link `~/.local/bin/papier`, so that `papier` works in a terminal and in a key binding;
- the start with the session: `~/.config/autostart/papier.desktop` runs `papier --hidden`.

```sh
tar -xzf papier-0.1.0-linux-x64.tar.gz
./papier-0.1.0-linux-x64/papier install          # --no-autostart, --no-path: leave a part out
papier status                                      # what is there, and whether papier runs
papier uninstall                                   # takes it all away; the history stays
```

A compositor that does not read `~/.config/autostart` (Hyprland, Sway) starts papier from its own configuration.

## Hyprland

Hyprland 0.55 and later (`hyprland.lua`):

```lua
hl.on("hyprland.start", function ()
  hl.exec_cmd("papier --hidden")
end)

hl.bind("SUPER + V", hl.dsp.exec_cmd("papier toggle"))

-- a window that floats over the others
hl.window_rule({
    name  = "papier",
    match = { class = "^papier$" },
    float = true,
    size  = "900 560",
})
```

Older versions (`hyprland.conf`):

```ini
exec-once = papier --hidden
bind = SUPER, V, exec, papier toggle
windowrulev2 = float, class:^(papier)$
windowrulev2 = size 900 560, class:^(papier)$
```

(The default configuration binds SUPER+V to "float the window": choose another key, or take that one.)

## Sway

```ini
# ~/.config/sway/config
exec papier --hidden
bindsym $mod+v exec papier toggle
for_window [app_id="papier"] floating enable, resize set 900 560, move position cursor
```

## KDE Plasma

`papier install` puts papier in the autostart list. Bind `papier toggle` in System Settings, Shortcuts, Add New, Command or
Script. Plasma's own clipboard (Klipper) runs beside it; turn its history off if you use papier's.

## NixOS and home-manager

The flake builds papier from source:

```nix
# flake.nix of your system
inputs.papier.url = "github:sachahjkl/papier";

# configuration.nix, or home.nix with home.packages
environment.systemPackages = [ inputs.papier.packages.x86_64-linux.default ];
```

Then start it from your compositor's configuration, as above.

## Another clipboard manager

Two managers that both put back the last entry when the clipboard empties can fight. Stop the other one's history
(cliphist, clipman, Klipper) or turn papier's off: `papier set clipboard.keep false`.
