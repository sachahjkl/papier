package papier

// Updates: gui_toolkit's Updater (gt:update) checks papier's latest release a while after the start and then every day,
// downloads the program it names, checks it against its signed manifest (src/update: papier's product and key) and puts it
// in place of this one. Only the installed copy does it by itself (update.auto): a build, or a copy run where it was
// unzipped, is updated when the settings' Check now asks. Once a new papier is in place, this one gives way to it as soon as
// its window is hidden: the new one starts hidden, in the notification area. A copy from the Nix store is left to Nix.

import "core:fmt"
import process "gt:process"
import "gt:platform"
import prefs_page "gt:prefs_page"
import update "gt:update"
import papier_update "update"

// The folder of the latest release's files: its manifests (update-<platform>.json and .sig) and its programs.
UPDATE_FOLDER :: "https://github.com/sachahjkl/papier/releases/latest/download/"

// (whether this is the installed copy comes with the start's reading of the install: setup_follow applies update.auto)
app_updates_start :: proc(app: ^App) {
	// (update.base_url: read at the start)
	folder, _ := prefs_page.update_source(&app.prefs)
	app.updater = update.updater_start({
		product = papier_update.PRODUCT, folder = folder != "" ? folder : UPDATE_FOLDER, current = APP_VERSION,
		exe = process.executable_path(), user_agent = fmt.tprintf("papier/%s", APP_VERSION),
		// (the updater's thread: the loop wakes, and app_updates_follow reads the state)
		news = proc(user: rawptr) { platform.wake((^App)(user).main.win) }, user = app,
	})
	app_updates_auto(app)
}

// update.auto, read again when the preferences change.
app_updates_auto :: proc(app: ^App) {
	auto := app.settings.update_auto && app.installed_copy
	update.set_auto(app.updater, auto ? .Install : .Off)
}

// At each turn of the loop: what changed is said, and an update in place takes over once the window is hidden.
app_updates_follow :: proc(app: ^App) {
	st := update.status(app.updater)
	if st.serial != app.update_serial {
		app.update_serial = st.serial
		app.main.settle = max(app.main.settle, FRAMES_AFTER_INPUT)   // (the settings show the state)
		// (said when asked, or when there is something to know: not each check that found nothing)
		if app.visible && (st.asked || st.phase == .Installed || st.phase == .Available) { say(app, "%s", update.status_words(st)) }
		// (the installed copy: its manifest and Settings > Apps say the new version)
		if st.phase == .Installed { reader_job(&app.reader, {kind = .Setup_Updated, text = st.version}) }
	}
	if st.phase == .Installed && !app.visible && !app.quit { app_restart(app) }
}

// The program starts again once this one has ended (it holds the single instance until then): an update put in place,
// or Restart asked. `hidden`: in the notification area (an update, while the window was hidden).
app_restart :: proc(app: ^App, hidden := true) {
	delete(app.launch_after)
	app.launch_after = fmt.aprintf("%s", process.executable_path())
	app.launch_hidden = hidden
	app.quit = true
}

// "Check for updates" (the palette): asked, its answer said in the status bar whatever it is.
update_check_asked :: proc(app: ^App) { update.check_now(app.updater) }
