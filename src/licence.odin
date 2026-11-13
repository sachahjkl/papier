package papier

// papier's licence (gt:licence, gui_toolkit docs/licence.md): a signed key, checked on this computer with no network. A
// licence changes nothing of what papier does: it says who supports it. The settings show it on the toolkit's Licence
// page (prefs_page.Licence): its state, Buy a licence, a key to paste, a file to choose, Remove. The store's file is
// touched only in the page's tasks, never on the window's thread.

import prefs_page "gt:prefs_page"
import papier_licence "licence"

// Where a licence is bought: the site's pricing page.
PRICING_URL :: "https://papier.froment.software/pricing/"

licence_init :: proc(app: ^App) {
	// (a debug build accepts the development pair: the tests and the pictures register with it)
	prefs_page.licence_init(&app.licence, &app.main.state, {
		store = {product = papier_licence.PRODUCT, program = APP_NAME, accept_dev = ODIN_DEBUG},
		name = "Papier", pricing_url = PRICING_URL, owner = app.main.win,
	})
}

// After the chores have stopped: no task holds the store any more.
licence_destroy :: proc(app: ^App) { prefs_page.licence_end(&app.licence) }
