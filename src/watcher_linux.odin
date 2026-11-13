#+build !windows
package papier

// The watcher on Linux (watcher.odin): it watches the clipboard, writes the history, serves what goes back on the
// clipboard, and takes the commands of other processes (the instance socket) and of the window (a queue). It sleeps in
// one poll on the Wayland connection, the socket and an eventfd: 0 % CPU at rest. It is the history's only writer.

import "core:fmt"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import config "gt:config"
import instance "gt:instance"
import "gt:platform"
import "history"
import "wlclip"

// How long a copy's bytes are waited for, per representation.
RECEIVE_WAIT_MS :: 1500

Watcher_System :: struct {
	store:   history.Store,
	client:  wlclip.Client,
	wake_fd: posix.FD,   // eventfd: the window's commands are queued
}

watcher_start :: proc(wt: ^Watcher, owner: instance.Owner, window: ^platform.Window, prefs: ^config.Prefs) -> bool {
	wt.owner = owner
	wt.window = window
	wt.settings = prefs_read(prefs)
	fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE { return false }
	wt.wake_fd = posix.FD(fd)
	wt.thread = thread.create_and_start_with_poly_data(wt, watcher_main)
	return wt.thread != nil
}

// Stops the thread and waits for it.
watcher_stop :: proc(wt: ^Watcher) {
	sync.atomic_store(&wt.stop, true)
	watcher_poke(wt)
	if wt.thread != nil {
		thread.join(wt.thread)
		thread.destroy(wt.thread)
		wt.thread = nil
	}
	posix.close(wt.wake_fd)
	watcher_free(wt)
}

watcher_poke :: proc(wt: ^Watcher) {
	one: u64 = 1
	posix.write(wt.wake_fd, ([^]u8)(&one), size_of(one))
}

@(private = "file")
watcher_main :: proc(wt: ^Watcher) {
	if ok, why := wlclip.connect(&wt.client); !ok {
		wt.error = fmt.aprintf("papier: %s", why)
		errln(wt.error)
		return
	}
	defer wlclip.disconnect(&wt.client)
	if ok, why := history.open(&wt.store, history_dir(wt.settings.persist)); !ok {
		wt.error = fmt.aprintf("papier: the history cannot be opened: %s", why)
		errln(wt.error)
		watcher_request(wt, .Quit)
		return
	}
	defer history.close(&wt.store)
	watcher_trim(wt)
	if !instance.owner_start(&wt.owner, watcher_message, wt) { errln("papier: the command socket cannot be opened") }
	defer instance.owner_stop(&wt.owner)

	for !sync.atomic_load(&wt.stop) {
		if !wlclip.poll_begin(&wt.client) { break }
		pfd := [3]posix.pollfd{
			{fd = wlclip.fd(&wt.client), events = {.IN}},
			{fd = posix.FD(wt.owner.listen), events = {.IN}},
			{fd = wt.wake_fd, events = {.IN}},
		}
		n := posix.poll(&pfd[0], 3, -1)
		if !wlclip.poll_end(&wt.client, n > 0 && .IN in pfd[0].revents) {
			wt.error = fmt.aprintf("papier: the compositor closed the clipboard connection")
			watcher_request(wt, .Quit)
			break
		}
		if n > 0 && .IN in pfd[1].revents { instance.pump_messages() }
		if n > 0 && .IN in pfd[2].revents {
			buf: u64
			posix.read(wt.wake_fd, ([^]u8)(&buf), size_of(buf))
			watcher_drain(wt)
		}
		watcher_selection(wt, .Clipboard)
		if wt.settings.primary { watcher_selection(wt, .Primary) }
		free_all(context.temp_allocator)
	}
	instance.owner_closing(&wt.owner)
}

// The window's commands, in the order they came.
@(private = "file")
watcher_drain :: proc(wt: ^Watcher) {
	if watcher_take_settings(wt) { watcher_trim(wt) }   // (a smaller history.max_entries applies at once)
	for c in watcher_take_queue(wt) {
		watcher_apply(wt, c)
		delete(c.text)
	}
}

// A command from another process (the instance socket), on this thread.
@(private = "file")
watcher_message :: proc(user: rawptr, message: []byte) {
	wt := (^Watcher)(user)
	if c, ok := command_parse(string(message)); ok { watcher_apply(wt, c) }
}

@(private = "file")
watcher_apply :: proc(wt: ^Watcher, c: Command) {
	changed := false
	switch c.verb {
	case .Ping, .Refresh:   // (the history is papier's own: always up to date)
	case .Show:   watcher_token(wt, c.token); watcher_request(wt, .Show)
	case .Hide:   watcher_request(wt, .Hide)
	case .Toggle: watcher_token(wt, c.token); watcher_request(wt, .Toggle)
	case .Quit:   watcher_request(wt, .Quit)
	case .Setup:  watcher_token(wt, c.token); watcher_request(wt, .Setup)
	case .Copy, .Copy_Plain:
		served, moved := watcher_serve(wt, c.id, true, plain = c.verb == .Copy_Plain)
		changed = moved
		if served && c.paste { watcher_request(wt, .Paste) }
	case .Add_Text:
		// an edited text, copied: a new entry at the top, on the clipboard
		id, ok := history.add(&wt.store, text_reps(c.text), 0, .Text, c.text, now_ms())
		if !ok { errln("papier: the history cannot be written"); break }
		if served, _ := watcher_serve(wt, id, false); served && c.paste { watcher_request(wt, .Paste) }
		changed = true
	case .Replace_Text:
		changed = history.replace(&wt.store, c.id, text_reps(c.text), 0, .Text, c.text)
		if changed { history.collect(&wt.store) }
	case .Pin:    changed = history.set_pinned(&wt.store, c.id, true)
	case .Unpin:  changed = history.set_pinned(&wt.store, c.id, false)
	case .Delete:
		changed = history.remove(&wt.store, c.id)
		if changed { history.collect(&wt.store) }
	case .Clear:
		changed = history.clear_all(&wt.store) > 0
		history.collect(&wt.store)
	case .Reload:
		prefs: config.Prefs
		prefs_open(&prefs, nil, context.temp_allocator)
		settings_free(&wt.settings)
		wt.settings = prefs_read(&prefs)
		config.prefs_destroy(&prefs)
		changed = watcher_trim(wt)
		watcher_request(wt, .Reload)
	}
	if changed { watcher_changed(wt) }
}

@(private = "file")
// The window reads the list again.
watcher_changed :: proc(wt: ^Watcher) {
	sync.atomic_add(&wt.version, 1)
	platform.wake(wt.window)
}

// A selection that changed: recorded, unless it is papier's own or not worth it; put back when it went empty.
@(private = "file")
watcher_selection :: proc(wt: ^Watcher, w: wlclip.Which) {
	offer, mimes, own, changed := wlclip.take(&wt.client, w)
	if !changed || own { return }
	if offer == nil {
		if w == .Clipboard && wt.settings.keep && len(wt.store.entries) > 0 { _, _ = watcher_serve(wt, wt.store.entries[0].id, false) }
		return
	}
	plan := plan_capture(mimes, wt.settings.capture)
	if plan.skip != .None { return }
	reps := make([dynamic]history.Rep_Data, context.temp_allocator)
	for want in plan.wanted[:plan.count] {
		data, err := wlclip.receive(&wt.client, offer, want.read, wt.settings.max_bytes, RECEIVE_WAIT_MS, context.temp_allocator)
		if err != .None { continue }
		append(&reps, history.Rep_Data{want.store, data})
	}
	kind, main, preview, ok := classify(reps[:])
	if !ok { return }
	if _, added := history.add(&wt.store, reps[:], main, kind, preview, now_ms()); !added {
		errln("papier: the history cannot be written")
		return
	}
	watcher_trim(wt)
	watcher_changed(wt)
}

@(private = "file")
watcher_trim :: proc(wt: ^Watcher) -> bool {
	max_age := i64(wt.settings.max_age_days) * 24 * 3600 * 1000
	if history.trim(&wt.store, wt.settings.max_entries, max_age, now_ms()) == 0 { return false }
	history.collect(&wt.store)
	watcher_changed(wt)
	return true
}

// One text, as the history stores it.
@(private = "file")
text_reps :: proc(text: string) -> []history.Rep_Data {
	r := make([]history.Rep_Data, 1, context.temp_allocator)
	r[0] = {TEXT_MIME, transmute([]u8)text}
	return r
}

// Puts the entry `id` on the clipboard (`to_top`: and first in the history; `plain`: its text only, without its rich
// text). served: it is on the clipboard; moved: it went to the top.
@(private = "file")
watcher_serve :: proc(wt: ^Watcher, id: u64, to_top: bool, plain := false) -> (served, moved: bool) {
	at := history.find(&wt.store, id)
	if at < 0 { return false, false }
	e := wt.store.entries[at]
	reps := make([dynamic]wlclip.Served, context.temp_allocator)
	for r in e.reps {
		if plain && r.mime != TEXT_MIME { continue }
		data := history.blob_read(&wt.store, r.hash, context.temp_allocator)
		if data == nil { continue }
		append(&reps, wlclip.Served{r.mime, data})
		for alias in served_mimes(r.mime) { if alias != r.mime { append(&reps, wlclip.Served{alias, data}) } }
	}
	if !wlclip.set_selection(&wt.client, reps[:]) { return false, false }
	return true, to_top && history.touch(&wt.store, id, now_ms())
}

