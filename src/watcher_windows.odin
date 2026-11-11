#+build windows
package papier

// The watcher on Windows (watcher.odin): the system keeps the history; the watcher reads it (history.system_refresh)
// when the system says it changed and when the window shows (the system answers the program in the foreground only),
// and asks the system for what the window wants (copy, remove, clear). Its thread is the Windows Runtime's (a
// single-threaded apartment: the clipboard's statics refuse the other) and the instance's (its message window): it sleeps
// in MsgWaitForMultipleObjects on an event (the window's commands, the system's change) and its messages, which it pumps
// as an apartment of that kind must. 0 % CPU at rest.

import "core:fmt"
import "core:sync"
import win "core:sys/windows"
import "core:thread"
import config "gt:config"
import instance "gt:instance"
import "gt:platform"
import "history"

Watcher_System :: struct {
	wake:     win.HANDLE,   // an event: a command is queued, the system's history changed, the stop
	stale:    bool,         // atomic: the system's history changed since it was read
	refused:  bool,         // the last read was refused (the window was not in the foreground): read at the next show
}

watcher_start :: proc(wt: ^Watcher, owner: instance.Owner, window: ^platform.Window, prefs: ^config.Prefs) -> bool {
	wt.owner = owner
	wt.window = window
	wt.settings = prefs_read(prefs)
	wt.wake = win.CreateEventW(nil, false, false, nil)
	if wt.wake == nil { return false }
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
	win.CloseHandle(wt.wake)
	watcher_free(wt)
}

watcher_poke :: proc(wt: ^Watcher) { win.SetEvent(wt.wake) }

@(private = "file")
watcher_main :: proc(wt: ^Watcher) {
	if err := history.system_start(classify, watcher_system_changed, wt); err != .None {
		wt.error = fmt.aprintf("papier: %s", history.SYSTEM_ERROR_TEXT[err])
		errln(wt.error)
		watcher_request(wt, .Quit)
		return
	}
	defer history.system_stop()
	if !instance.owner_start(&wt.owner, watcher_message, wt) { errln("papier: the command window cannot be made") }
	defer instance.owner_stop(&wt.owner)
	watcher_refresh(wt)

	for !sync.atomic_load(&wt.stop) {
		handles := [1]win.HANDLE{wt.wake}
		win.MsgWaitForMultipleObjects(1, &handles[0], false, win.INFINITE, win.QS_ALLINPUT)
		instance.pump_messages()   // (the instance's window: commands of other processes)
		for c in watcher_take_queue(wt) {
			watcher_apply(wt, c)
			delete(c.text)
		}
		if sync.atomic_exchange(&wt.stale, false) { watcher_refresh(wt) }
		free_all(context.temp_allocator)
	}
	instance.owner_closing(&wt.owner)
}

// The system's history changed (on a thread of the system's): read at the next turn of the loop.
@(private = "file")
watcher_system_changed :: proc(user: rawptr) {
	wt := (^Watcher)(user)
	sync.atomic_store(&wt.stale, true)
	watcher_poke(wt)
}

// Reads the system's history; the window reads the snapshot again when it moved.
@(private = "file")
watcher_refresh :: proc(wt: ^Watcher) {
	changed, err := history.system_refresh()
	wt.refused = err == .Access_Denied
	if err != .None && err != .Access_Denied { errf("papier: %s", history.SYSTEM_ERROR_TEXT[err]) }
	if changed { watcher_changed(wt) }
}

// A command from another process (the instance's window), on this thread.
@(private = "file")
watcher_message :: proc(user: rawptr, message: []byte) {
	wt := (^Watcher)(user)
	if c, ok := command_parse(string(message)); ok { watcher_apply(wt, c) }
}

@(private = "file")
watcher_apply :: proc(wt: ^Watcher, c: Command) {
	switch c.verb {
	case .Ping:
	case .Show:   watcher_token(wt, c.token); watcher_request(wt, .Show)
	case .Hide:   watcher_request(wt, .Hide)
	case .Toggle: watcher_token(wt, c.token); watcher_request(wt, .Toggle)
	case .Quit:   watcher_request(wt, .Quit)
	case .Setup:  watcher_token(wt, c.token); watcher_request(wt, .Setup)
	case .Refresh: watcher_refresh(wt)
	case .Copy:
		if !history.system_copy(c.id) { errf("papier: entry %d cannot be put on the clipboard", c.id); break }
		if c.paste { watcher_request(wt, .Paste) }
	case .Copy_Plain:
		if text, ok := entry_text(c.id); ok && put_text(wt, text) && c.paste { watcher_request(wt, .Paste) }
	case .Add_Text:
		if put_text(wt, c.text) && c.paste { watcher_request(wt, .Paste) }
	case .Replace_Text:
		// (the system's entries cannot change: the new text is a copy, and the old entry goes)
		if put_text(wt, c.text) { history.system_delete(c.id) }
	case .Pin, .Unpin:   // (the system does not let a program pin)
	case .Delete: history.system_delete(c.id)
	case .Clear:  history.system_clear()
	case .Reload:
		prefs: config.Prefs
		prefs_open(&prefs, nil)
		settings_free(&wt.settings)
		wt.settings = prefs_read(&prefs)
		config.prefs_destroy(&prefs)
		watcher_request(wt, .Reload)
	}
	// (each change comes back as the system's HistoryChanged, which reads the history again)
}

// A text on the clipboard, through the window (the Win32 clipboard wants a window to own it): the system records it.
@(private = "file")
put_text :: proc(wt: ^Watcher, text: string) -> bool {
	if platform.clipboard_set(wt.window, {text = text}) { return true }
	errln("papier: the clipboard cannot be written")
	return false
}

// The text of the entry `id`, from the snapshot.
@(private = "file")
entry_text :: proc(id: u64) -> (text: string, ok: bool) {
	s: history.Store
	history.open(&s, "")
	defer history.close(&s)
	at := history.find(&s, id)
	if at < 0 { return }
	e := s.entries[at]
	r := history.rep_find(e, TEXT_MIME)
	if r < 0 { return }
	data := history.blob_read(&s, e.reps[r].hash, context.temp_allocator)
	return string(data), data != nil
}
