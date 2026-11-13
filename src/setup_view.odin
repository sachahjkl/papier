package papier

// Setup: papier installs itself for the user from the copy that was downloaded (gui_toolkit's setup, through
// prefs_page.Install): the program in %LOCALAPPDATA%\Programs\papier (~/.local/share/papier on Linux), the Start menu, the
// start with the session, papier on the PATH with papier.com, the Settings > Apps entry (whose Uninstall runs
// `papier --setup`). A start of a copy that is not installed offers it, once per version unless the user keeps this copy
// standalone (Windows; on Linux Nix installs papier, or `papier --install`). The settings' Installation page shows the
// install and acts on it.
//
//   papier --setup        the install's dialog (the running papier shows it)
//   papier --install      this copy installed, without a window
//   papier --uninstall    the install taken away (the history stays)
//   papier --status       what is installed, and whether papier runs

import desktop "gt:desktop"
import i18n "gt:i18n"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:render"
import setup "gt:setup"

// What the setup knows of papier.
setup_options :: proc() -> setup.Setup_Options {
	return setup.Setup_Options{
		identity = papier_identity(), version = APP_VERSION, install_folder = APP_NAME, icons = ICON_PNGS[:],
		choices = SETUP_CHOICES[:], running = daemon_running,
		prepare = proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) {
			papier_parts(o)
			if len(choices) == len(SETUP_CHOICES) { o.autostart, o.add_to_path = choices[0], choices[1] }
		},
	}
}

// The boxes of the dialog, in the order prepare reads them (their labels in English: the dialog translates them).
@(private = "file")
SETUP_CHOICES := [?]setup.Choice{
	{label = i18n.later("Start with the session, in the notification area"), on = true},
	{label = i18n.later("papier in the terminal (on the PATH)"), on = true},
}

// Once the start's reading of the install came (prefs_page.install_offer): whether this is the installed copy, which
// updates itself (update.auto).
setup_follow :: proc(app: ^App) {
	if app.setup_known || !app.install.known { return }
	app.setup_known = true
	app.installed_copy = app.install.running_it
	app_updates_auto(app)
}

// The install's dialog, the window shown (--setup, Settings > Apps' Uninstall).
setup_open :: proc(app: ^App) {
	prefs_page.install_open(&app.install)
	app.main.settle = max(app.main.settle, FRAMES_AT_SHOW)
}

// The install's machinery each frame (its dialog while open); its logo made at its first show.
setup_build :: proc(app: ^App, em: f32) {
	if prefs_page.install_open_now(&app.install) && !app.logo_made { setup_logo(app) }
	setup_follow(app)
	if prefs_page.install_frame(&app.install, em) == .Launched { app.quit = true }   // (the installed copy starts at the end: app_run)
}

// The logo of the dialog, a texture of the window's renderer (made once, freed with the window).
@(private = "file")
setup_logo :: proc(app: ^App) {
	app.logo_made = true
	img, ok := platform.clipboard_image_decode("image/png", LOGO_PNG_LARGE, context.temp_allocator)
	if !ok { return }
	app.logo = render.create_texture_rgba(&app.shared.r, img.size.x, img.size.y)
	render.update_texture_rgba(&app.shared.r, app.logo, 0, 0, img.size.x, img.size.y, img.rgba)
	app.install.logo = setup.Logo{app.logo, {f32(LOGO_SIZE), f32(LOGO_SIZE)}}
}

LOGO_SIZE :: 128
LOGO_PNG_LARGE :: #load("../assets/logo_128.png")
