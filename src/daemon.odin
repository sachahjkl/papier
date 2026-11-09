package papier

// The daemon: the one process that watches the clipboard, writes the history and serves what goes back on the
// clipboard. It owns the instance name DAEMON_NAME; the picker and the command line send it their commands (commands.odin)
// over the instance socket. Its loop sleeps in one poll on the Wayland connection and that socket: 0 % CPU at rest.

import "core:fmt"
import "core:sys/posix"
import "core:time"
import config "gt:config"
import instance "gt:instance"
import "history"
import "wlclip"

DAEMON_NAME :: "papier.daemon"
// How long a copy's bytes are waited for, per representation.
RECEIVE_WAIT_MS :: 1500

Daemon :: struct {
	prefs:    config.Prefs,
	settings: Settings,
	store:    history.Store,
	client:   wlclip.Client,
	owner:    instance.Owner,
	quit:     bool,
}

now_ms :: proc() -> i64 { return time.to_unix_nanoseconds(time.now()) / 1e6 }

daemon_run :: proc(args: []string) -> int {
	d := new(Daemon)
	defer free(d)
	_, problems := prefs_open(&d.prefs, args)
	for p in problems { fmt.eprintfln("papier: %s", p) }
	d.settings = prefs_read(&d.prefs)
	defer { settings_free(&d.settings); config.prefs_destroy(&d.prefs) }

	outcome, owner := instance.acquire({name = DAEMON_NAME, wait_ms = 500}, transmute([]u8)string("ping"))
	switch outcome {
	case .First:
	case .Forwarded, .Other_Instance:
		fmt.eprintln("papier: the daemon already runs")
		return 0
	case .Unresponsive:
		fmt.eprintln("papier: another daemon holds the name and does not answer")
		return 1
	}
	d.owner = owner
	defer instance.owner_stop(&d.owner)

	history.open(&d.store, history_dir(d.settings.persist))
	defer history.close(&d.store)
	daemon_trim(d)

	if ok, why := wlclip.connect(&d.client); !ok {
		fmt.eprintfln("papier: %s", why)
		return 1
	}
	defer wlclip.disconnect(&d.client)
	if !instance.owner_start(&d.owner, daemon_message, d) {
		fmt.eprintln("papier: the command socket cannot be opened")
		return 1
	}
	fmt.printfln("papier: watching the clipboard (%v), history in %s, %d entries", d.client.protocol, d.store.dir, len(d.store.entries))

	for !d.quit {
		if !wlclip.poll_begin(&d.client) { break }
		pfd := [2]posix.pollfd{{fd = wlclip.fd(&d.client), events = {.IN}}, {fd = posix.FD(d.owner.listen), events = {.IN}}}
		n := posix.poll(&pfd[0], 2, -1)
		if !wlclip.poll_end(&d.client, n > 0 && .IN in pfd[0].revents) {
			fmt.eprintln("papier: the compositor closed the connection")
			return 1
		}
		if n > 0 && .IN in pfd[1].revents { instance.pump_messages() }
		daemon_selection(d, .Clipboard)
		if d.settings.primary { daemon_selection(d, .Primary) }
		free_all(context.temp_allocator)
	}
	instance.owner_closing(&d.owner)
	return 0
}

// A selection that changed: recorded, unless it is papier's own or not worth it; put back when it went empty.
daemon_selection :: proc(d: ^Daemon, w: wlclip.Which) {
	offer, mimes, own, changed := wlclip.take(&d.client, w)
	if !changed || own { return }
	if offer == nil {
		if w == .Clipboard && d.settings.keep && len(d.store.entries) > 0 { daemon_serve(d, d.store.entries[0].id, false) }
		return
	}
	plan := plan_capture(mimes, d.settings.capture)
	if plan.skip != .None { return }
	reps := make([dynamic]history.Rep_Data, context.temp_allocator)
	for want in plan.wanted[:plan.count] {
		data, err := wlclip.receive(&d.client, offer, want.read, d.settings.max_bytes, RECEIVE_WAIT_MS, context.temp_allocator)
		if err != .None { continue }
		append(&reps, history.Rep_Data{want.store, data})
	}
	kind, main, preview, ok := classify(reps[:])
	if !ok { return }
	if _, added := history.add(&d.store, reps[:], main, kind, preview, now_ms()); !added {
		fmt.eprintln("papier: the history cannot be written")
		return
	}
	daemon_trim(d)
	history.save(&d.store)
}

daemon_trim :: proc(d: ^Daemon) {
	max_age := i64(d.settings.max_age_days) * 24 * 3600 * 1000
	if history.trim(&d.store, d.settings.max_entries, max_age, now_ms()) > 0 {
		history.collect(&d.store)
		history.save(&d.store)
	}
}

// Puts the entry `id` on the clipboard (`to_top`: and first in the history). False when it is gone.
daemon_serve :: proc(d: ^Daemon, id: u64, to_top: bool) -> bool {
	at := history.find(&d.store, id)
	if at < 0 { return false }
	e := d.store.entries[at]
	served := make([dynamic]wlclip.Served, context.temp_allocator)
	for r in e.reps {
		data := history.blob_read(&d.store, r.hash, context.temp_allocator)
		if data == nil { continue }
		append(&served, wlclip.Served{r.mime, data})
		for alias in served_mimes(r.mime) { if alias != r.mime { append(&served, wlclip.Served{alias, data}) } }
	}
	if !wlclip.set_selection(&d.client, served[:]) { return false }
	if to_top {
		history.touch(&d.store, id, now_ms())
		history.save(&d.store)
	}
	return true
}

// A command from the picker or the command line (commands.odin), on the loop's thread.
daemon_message :: proc(user: rawptr, message: []byte) {
	d := (^Daemon)(user)
	cmd, ok := command_parse(string(message))
	if !ok { return }
	switch cmd.verb {
	case .Ping:
	case .Copy:   daemon_serve(d, cmd.id, true)
	case .Pin:    if history.set_pinned(&d.store, cmd.id, true) { history.save(&d.store) }
	case .Unpin:  if history.set_pinned(&d.store, cmd.id, false) { history.save(&d.store) }
	case .Delete:
		if history.remove(&d.store, cmd.id) { history.collect(&d.store); history.save(&d.store) }
	case .Clear:
		history.clear_all(&d.store)
		history.collect(&d.store)
		history.save(&d.store)
	case .Reload:
		settings_free(&d.settings)
		config.prefs_destroy(&d.prefs)
		prefs_open(&d.prefs, nil)
		d.settings = prefs_read(&d.prefs)
		daemon_trim(d)
	case .Quit:   d.quit = true
	}
}
