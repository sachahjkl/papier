package papier

// The watcher: a thread of its own that watches the clipboard, writes the history, serves what goes back on the
// clipboard, and takes the commands of other processes (the instance socket) and of the window (a queue). It sleeps in
// one poll on the Wayland connection, the socket and an eventfd: 0 % CPU at rest. It is the history's only writer; the
// window reads the index again when `version` moves.
//
// What the window must do (show, hide, quit) goes back to it through `asked`, in order, and a wake of its window.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import "core:time"
import config "gt:config"
import instance "gt:instance"
import "gt:platform"
import "history"
import "wlclip"

DAEMON_NAME :: "papier.daemon"
// How long a copy's bytes are waited for, per representation.
RECEIVE_WAIT_MS :: 1500

// What the watcher asks of the window (a bit set, atomic).
Request :: enum u8 { Show, Hide, Toggle, Quit, Reload }

Watcher :: struct {
	settings:  Settings,             // the watcher's own copy
	store:     history.Store,
	client:    wlclip.Client,
	owner:     instance.Owner,
	window:    ^platform.Window,     // woken when there is something for it (platform.wake is thread-safe)
	thread:    ^thread.Thread,
	wake_fd:   posix.FD,             // eventfd: the window's commands are queued
	mutex:     sync.Mutex,
	queue:     [dynamic]Command,     // guarded by `mutex`
	asked:     [dynamic]Request,     // for the window, in the order they came (a hide then a show ends shown); guarded by `mutex`
	version:   u64,                  // atomic: bumped after each change of the index on the disk
	stop:      bool,                 // atomic
	error:     string,               // why it stopped, when it did by itself (read after the thread ended)
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
	for c in wt.queue { delete(c.text) }
	delete(wt.queue)
	delete(wt.asked)
	settings_free(&wt.settings)
	delete(wt.error)
}

// A command of the window, run by the watcher's thread.
watcher_send :: proc(wt: ^Watcher, c: Command) {
	sync.guard(&wt.mutex)
	q := c
	q.text = strings.clone(c.text)   // (the watcher's thread frees it once applied)
	append(&wt.queue, q)
	watcher_poke(wt)
}

// The requests for the window since the last call, in the order they came (temp allocator).
watcher_take_requests :: proc(wt: ^Watcher) -> []Request {
	sync.guard(&wt.mutex)
	out := make([]Request, len(wt.asked), context.temp_allocator)
	copy(out, wt.asked[:])
	clear(&wt.asked)
	return out
}

@(private = "file")
watcher_poke :: proc(wt: ^Watcher) {
	one: u64 = 1
	posix.write(wt.wake_fd, ([^]u8)(&one), size_of(one))
}

@(private = "file")
watcher_request :: proc(wt: ^Watcher, r: Request) {
	sync.mutex_lock(&wt.mutex)
	append(&wt.asked, r)
	sync.mutex_unlock(&wt.mutex)
	platform.wake(wt.window)
}

@(private = "file")
watcher_main :: proc(wt: ^Watcher) {
	if ok, why := wlclip.connect(&wt.client); !ok {
		wt.error = fmt.aprintf("papier: %s", why)
		fmt.eprintln(wt.error)
		return
	}
	defer wlclip.disconnect(&wt.client)
	history.open(&wt.store, history_dir(wt.settings.persist))
	defer history.close(&wt.store)
	watcher_trim(wt)
	if !instance.owner_start(&wt.owner, watcher_message, wt) { fmt.eprintln("papier: the command socket cannot be opened") }
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
	sync.mutex_lock(&wt.mutex)
	cmds := make([]Command, len(wt.queue), context.temp_allocator)
	copy(cmds, wt.queue[:])
	clear(&wt.queue)
	sync.mutex_unlock(&wt.mutex)
	for c in cmds {
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
	case .Ping:
	case .Show:   watcher_request(wt, .Show)
	case .Hide:   watcher_request(wt, .Hide)
	case .Toggle: watcher_request(wt, .Toggle)
	case .Quit:   watcher_request(wt, .Quit)
	case .Copy:   changed = watcher_serve(wt, c.id, true)
	case .Copy_Plain: changed = watcher_serve(wt, c.id, true, plain = true)
	case .Add_Text:
		// an edited text, copied: a new entry at the top, on the clipboard
		id, ok := history.add(&wt.store, text_reps(c.text), 0, .Text, c.text, now_ms())
		if !ok { fmt.eprintln("papier: the history cannot be written"); break }
		watcher_serve(wt, id, false)
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
		prefs_open(&prefs, nil)
		settings_free(&wt.settings)
		wt.settings = prefs_read(&prefs)
		config.prefs_destroy(&prefs)
		changed = watcher_trim(wt)
		watcher_request(wt, .Reload)
	}
	if changed { watcher_saved(wt) }
}

@(private = "file")
watcher_saved :: proc(wt: ^Watcher) {
	if !history.save(&wt.store) { fmt.eprintln("papier: the history cannot be written"); return }
	sync.atomic_add(&wt.version, 1)
	platform.wake(wt.window)
}

// A selection that changed: recorded, unless it is papier's own or not worth it; put back when it went empty.
@(private = "file")
watcher_selection :: proc(wt: ^Watcher, w: wlclip.Which) {
	offer, mimes, own, changed := wlclip.take(&wt.client, w)
	if !changed || own { return }
	if offer == nil {
		if w == .Clipboard && wt.settings.keep && len(wt.store.entries) > 0 { watcher_serve(wt, wt.store.entries[0].id, false) }
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
		fmt.eprintln("papier: the history cannot be written")
		return
	}
	watcher_trim(wt)
	watcher_saved(wt)
}

@(private = "file")
watcher_trim :: proc(wt: ^Watcher) -> bool {
	max_age := i64(wt.settings.max_age_days) * 24 * 3600 * 1000
	if history.trim(&wt.store, wt.settings.max_entries, max_age, now_ms()) == 0 { return false }
	history.collect(&wt.store)
	watcher_saved(wt)
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
// text). False when it is gone or nothing changed.
@(private = "file")
watcher_serve :: proc(wt: ^Watcher, id: u64, to_top: bool, plain := false) -> bool {
	at := history.find(&wt.store, id)
	if at < 0 { return false }
	e := wt.store.entries[at]
	served := make([dynamic]wlclip.Served, context.temp_allocator)
	for r in e.reps {
		if plain && r.mime != TEXT_MIME { continue }
		data := history.blob_read(&wt.store, r.hash, context.temp_allocator)
		if data == nil { continue }
		append(&served, wlclip.Served{r.mime, data})
		for alias in served_mimes(r.mime) { if alias != r.mime { append(&served, wlclip.Served{alias, data}) } }
	}
	if !wlclip.set_selection(&wt.client, served[:]) { return false }
	return to_top && history.touch(&wt.store, id, now_ms())
}

now_ms :: proc() -> i64 { return time.to_unix_nanoseconds(time.now()) / 1e6 }

// The version of the index on the disk: it moves after each change the watcher saved.
watcher_version :: proc(wt: ^Watcher) -> u64 { return sync.atomic_load(&wt.version) }
