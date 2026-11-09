package papier

// The watcher: a thread of its own that keeps the history up to date and runs the window's commands (a queue) and those
// of other processes (the instance). The window reads the history again when `version` moves. What the window must do
// (show, hide, quit) goes back to it through `asked`, in order, and a wake of its window.
//
//   Linux    it watches the clipboard (Wayland's data control), writes papier's own history, serves what goes back on
//            the clipboard (watcher_linux.odin).
//   Windows  it reads the system's clipboard history and asks the system for its changes (watcher_windows.odin).

import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import instance "gt:instance"
import "gt:platform"

DAEMON_NAME :: "papier.daemon"

// What the watcher asks of the window.
Request :: enum u8 {
	Show, Hide, Toggle, Quit, Reload, Setup,
	Paste,   // an entry is on the clipboard: paste it into the program the window was called from (app_paste)
}

Watcher :: struct {
	using system: Watcher_System,   // what the system's side keeps (watcher_linux.odin, watcher_windows.odin)
	settings:  Settings,             // the watcher's own copy
	owner:     instance.Owner,
	window:    ^platform.Window,     // woken when there is something for it (platform.wake is thread-safe)
	thread:    ^thread.Thread,
	mutex:     sync.Mutex,
	queue:     [dynamic]Command,     // guarded by `mutex`
	asked:     [dynamic]Request,     // for the window, in the order they came (a hide then a show ends shown); guarded by `mutex`
	version:   u64,                  // atomic: bumped after each change of the history
	stop:      bool,                 // atomic
	error:     string,               // why it stopped, when it did by itself (read after the thread ended)
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

watcher_request :: proc(wt: ^Watcher, r: Request) {
	sync.mutex_lock(&wt.mutex)
	append(&wt.asked, r)
	sync.mutex_unlock(&wt.mutex)
	platform.wake(wt.window)
}

// The window's commands, in the order they came (watcher_apply runs each).
watcher_take_queue :: proc(wt: ^Watcher) -> []Command {
	sync.guard(&wt.mutex)
	out := make([]Command, len(wt.queue), context.temp_allocator)
	copy(out, wt.queue[:])
	clear(&wt.queue)
	return out
}

// The window reads the history again.
watcher_changed :: proc(wt: ^Watcher) {
	sync.atomic_add(&wt.version, 1)
	platform.wake(wt.window)
}

// The history's version: it moves after each change.
watcher_version :: proc(wt: ^Watcher) -> u64 { return sync.atomic_load(&wt.version) }

// What the common part frees at the end (watcher_stop of each system).
watcher_free :: proc(wt: ^Watcher) {
	for c in wt.queue { delete(c.text) }
	delete(wt.queue)
	delete(wt.asked)
	settings_free(&wt.settings)
	delete(wt.error)
}

now_ms :: proc() -> i64 { return time.to_unix_nanoseconds(time.now()) / 1e6 }
