package papier

// papier on the user's desktop (gt:desktop): a launcher in the application menu with its icons, the program on the PATH
// (Windows: with papier.com beside papier.exe, its console launcher: the toolkit's build makes and embeds it; Linux: a
// link in ~/.local/bin), and the start with the session, hidden in the notification area. The install puts them in
// place for the installed copy (setup_view.odin: its dialog, the settings' Installation page, papier --install).

import desktop "gt:desktop"
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
		name = "Papier", key = "Papier", slug = APP_NAME,
		description = "The clipboard's history: text, rich text, images and files, searched and put back in a keystroke.",
		vendor = "Froment Software",
		entry_marker = "X-Papier-Integration", registry_mark = "PapierIntegration", vendor_key = "FromentSoftware",
		manifest_name = "papier_install.txt",
		generic_name = "Clipboard Manager", categories = "Utility;", keywords = "clipboard;history;copy;paste;",
		env_prefix = "PAPIER_DESKTOP_",
		uninstall_arguments = "--setup",   // (Settings > Apps: the install's dialog, its Uninstall)
	}
}

// papier's own parts of an install: the start with the session (hidden, in the notification area), papier on the PATH,
// and on Windows papier.com beside it. The places of a test (PAPIER_DESKTOP_*) come from the environment: a test's
// install never reaches the person's desktop.
papier_parts :: proc(o: ^desktop.Integration_Options) {
	o.add_to_path = true
	o.autostart = true
	o.autostart_arguments = "--hidden"
	desktop.roots_from_env(o, proc(name: string) -> string { return os.get_env(name, context.temp_allocator) })
}

// Whether a papier runs and answers.
daemon_running :: proc() -> bool { return command_send({verb = .Ping}) }
