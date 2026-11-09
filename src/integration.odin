package papier

// papier on the user's desktop (gt:desktop): a launcher in the application menu with its icons, the program on the PATH
// (a link in ~/.local/bin), and the start with the session, hidden in the notification area. It integrates the running
// executable where it is: a build, a downloaded release, or a Nix profile's.
//
//   papier install [--no-autostart] [--no-path]
//   papier uninstall
//   papier status

import desktop "gt:desktop"
import "gt:process"
import "core:os"

ICON_PNGS := [?]desktop.Icon{
	{16, #load("../assets/logo_16.png")},
	{32, #load("../assets/logo_32.png")},
	{64, #load("../assets/logo_64.png")},
	{128, #load("../assets/logo_128.png")},
	{256, #load("../assets/logo_256.png")},
}

papier_identity :: proc() -> desktop.Identity {
	return desktop.Identity{
		name = "Papier", key = "Papier", slug = APP_NAME, aumid = "FromentSoftware.Papier",
		description = "The clipboard's history: text, rich text, images and files, searched and put back in a keystroke.",
		vendor = "Froment Software",
		entry_marker = "X-Papier-Integration", registry_mark = "PapierIntegration", vendor_key = "FromentSoftware",
		manifest_name = "papier_install.txt",
		generic_name = "Clipboard Manager", categories = "Utility;", keywords = "clipboard;history;copy;paste;",
		env_prefix = "PAPIER_DESKTOP_",
	}
}

@(private = "file")
integration_options :: proc(args: []string) -> desktop.Options {
	o := desktop.options_make(papier_identity())
	o.exe = process.executable_path()
	o.icons = ICON_PNGS[:]
	o.add_to_path = true
	o.autostart = true
	o.autostart_arguments = "--hidden"
	for a in args {
		switch a {
		case "--no-autostart": o.autostart = false
		case "--no-path":      o.add_to_path = false
		}
	}
	desktop.roots_from_env(&o, proc(name: string) -> string { return os.get_env(name, context.temp_allocator) })
	return o
}

cmd_install :: proc(args: []string) -> int {
	o := integration_options(args)
	if r := desktop.install(&o); r.error != .None {
		errf("papier: %s %s", desktop.error_text(r.error), r.detail)
		return 1
	}
	outf("papier: installed for %s (%s)", o.exe, desktop.targets(false))
	if o.autostart {
		when ODIN_OS == .Windows {
			outln("papier: it starts with the session, in the notification area; its shortcut shows it (picker.shortcut, Win+Shift+V)")
		} else {
			outln("papier: it starts with the session, in the notification area; bind `papier toggle` to a key to show it")
		}
	}
	return 0
}

cmd_uninstall :: proc(args: []string) -> int {
	o := integration_options(args)
	if r := desktop.remove(&o); r.error != .None {
		errf("papier: %s %s", desktop.error_text(r.error), r.detail)
		return 1
	}
	outln("papier: the launcher, the icons, the link and the start with the session are gone (the history stays)")
	return 0
}

cmd_status :: proc(args: []string) -> int {
	o := integration_options(args)
	s := desktop.status(&o)
	defer desktop.status_destroy(&s)
	outf("%s", desktop.describe(&s))
	for part in s.wanted {
		ps := s.parts[part]
		state := ps.present ? (ps.stale ? "points to another program" : ps.partial ? "incomplete" : "present") : "absent"
		outf("  %v: %s", part, state)
	}
	outf("  running: %v", daemon_running())
	return s.state == .Installed ? 0 : 1
}

// Whether a papier runs and answers.
daemon_running :: proc() -> bool { return command_send({verb = .Ping}) }
