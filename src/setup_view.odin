package papier

// Setup: papier installs itself for the user from the copy that was downloaded (gui_toolkit's setup): the program in
// %LOCALAPPDATA%\Programs\papier, the Start menu, the start with the session, papier on the PATH with papier.com, the
// Settings > Apps entry (whose Uninstall runs `papier --setup`). A start of a copy that is not installed offers it, once
// per version unless the user keeps this copy standalone (Windows; on Linux `papier install` integrates the copy where it
// is, and Nix installs it).
//
//   papier --setup        the dialog (the running papier shows it)

import desktop "gt:desktop"
import i18n "gt:i18n"
import "gt:platform"
import "gt:render"
import setup "gt:setup"
import "core:strings"

// What the setup knows of papier.
setup_config :: proc() -> setup.Config {
	return setup.Config{
		identity = papier_identity(), version = APP_VERSION, install_folder = APP_NAME, icons = ICON_PNGS[:],
		choices = SETUP_CHOICES[:],
		prepare = proc(o: ^desktop.Options, choices: []bool, user: rawptr) {
			papier_parts(o)
			if len(choices) == len(SETUP_CHOICES) { o.autostart, o.add_to_path = choices[0], choices[1] }
		},
	}
}

// The boxes of the dialog, in the order prepare reads them (their labels in the language in use: texts_translate).
@(private = "file")
SETUP_CHOICES := [?]setup.Choice{
	{label = i18n.later("Start with the session, in the notification area"), on = true},
	{label = i18n.later("papier in the terminal (on the PATH)"), on = true},
}

setup_choices_translate :: proc() {
	for &c in SETUP_CHOICES { c.label = i18n.tr(c.label) }
}

// What the reader found of the install (a Setup_Facts job, asked at the start): the dialog when there is something to do
// (Windows), unless the user answered for this version or kept this copy standalone.
setup_offer :: proc(app: ^App, d: ^Job_Done) {
	app.installed_copy = d.running_it
	app_updates_auto(app)
	if d.setup_wanted { setup_open(app) }
}

setup_open :: proc(app: ^App) {
	setup.open(&app.setup, setup_config())
	app.main.settle = max(app.main.settle, FRAMES_AT_SHOW)
}

// The dialog, over the page, while it is open; what the user answered is kept (state.odin).
setup_build :: proc(app: ^App, em: f32) {
	if !app.setup.open { return }
	if !app.logo_made { setup_logo(app) }
	logo: Maybe(setup.Logo)
	if app.logo_made { logo = setup.Logo{app.logo, {f32(LOGO_SIZE), f32(LOGO_SIZE)}} }
	switch setup.dialog(&app.setup, setup_config(), em, logo) {
	case .Installed:       setup_choice(app, setup.CHOICE_INSTALLED)
	case .Kept_Standalone: setup_choice(app, setup.CHOICE_STANDALONE)
	case .Dismissed:       setup_choice(app, setup.choice_dismissed(APP_VERSION))
	case .Launched:
		// (the installed copy starts once this one has let go of the instance: app_run's end)
		delete(app.launch_after)
		app.launch_after = strings.clone(app.setup.installed)
		app.quit = true
	case .Uninstalled, .None:
	}
}

@(private = "file")
setup_choice :: proc(app: ^App, choice: string) {
	delete(app.place.setup)
	app.place.setup = strings.clone(choice)
	state_write(app)
}

// The logo of the dialog, a texture of the window's renderer (made once, freed with the window).
@(private = "file")
setup_logo :: proc(app: ^App) {
	img, ok := platform.clipboard_image_decode("image/png", LOGO_PNG_LARGE, context.temp_allocator)
	if !ok { return }
	app.logo = render.create_texture_rgba(&app.shared.r, img.size.x, img.size.y)
	render.update_texture_rgba(&app.shared.r, app.logo, 0, 0, img.size.x, img.size.y, img.rgba)
	app.logo_made = true
}

LOGO_SIZE :: 128
LOGO_PNG_LARGE :: #load("../assets/logo_128.png")

