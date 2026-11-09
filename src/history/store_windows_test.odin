#+build windows
package history

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "gt:platform"

// The classification of the test: a text is a text, its preview its words.
@(private = "file")
classify_text :: proc(reps: []Rep_Data, allocator := context.temp_allocator) -> (kind: Kind, main: int, preview: string, ok: bool) {
	for r, i in reps { if strings.has_prefix(r.mime, "text/plain") { return .Text, i, string(r.data), true } }
	return .Other, -1, "", false
}

@(private = "file")
find_text :: proc(text: string) -> (id: u64, found: bool) {
	s: Store
	open(&s, "")
	defer close(&s)
	for e in s.entries { if e.preview == text { return e.id, true } }
	return
}

// A copy of the runner's comes in the snapshot with its text; it goes back on the clipboard; removed, it goes from the
// system's history. (The CI turns the history on: HKCU\Software\Microsoft\Clipboard\EnableClipboardHistory.)
@(test)
the_system_history_is_read_and_changed :: proc(t: ^testing.T) {
	changes: int
	err := system_start(classify_text, proc(user: rawptr) { sync.atomic_add((^int)(user), 1) }, &changes)
	testing.expectf(t, err == .None, "the system's history: %s (0x%08x)", SYSTEM_ERROR_TEXT[err], system_failure())
	if err != .None { return }
	defer system_stop()
	if !system_enabled() {
		// (a runner's session may not have the history: the read goes through all the same, and says so)
		_, rerr := system_refresh()
		testing.expectf(t, rerr == .Disabled || rerr == .Access_Denied, "the read of a history that is off: %s (0x%08x)", SYSTEM_ERROR_TEXT[rerr], system_failure())
		log.warnf("the clipboard history is off on this machine (the read said: %s): nothing more to test", SYSTEM_ERROR_TEXT[rerr])
		return
	}

	w := platform.open_window("papier history test", {200, 120})   // (never shown: it owns the clipboard's text)
	defer platform.destroy_window(w)
	text := fmt.tprintf("papier test %d %d", os.get_pid(), time.now()._nsec)
	testing.expect(t, platform.clipboard_set(w, {text = text}))

	id: u64
	found := false
	for _ in 0 ..< 40 {   // (the system records the copy a moment later)
		_, rerr := system_refresh()
		if rerr == .Access_Denied {
			log.warnf("the system refused the read: %s", SYSTEM_ERROR_TEXT[rerr])
			return
		}
		testing.expectf(t, rerr == .None, "read: %s (0x%08x)", SYSTEM_ERROR_TEXT[rerr], system_failure())
		if id, found = find_text(text); found { break }
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(t, found, "the copy is in the history")
	if !found { return }

	s: Store
	open(&s, "")
	at := find(&s, id)
	testing.expect_value(t, s.entries[at].kind, Kind.Text)
	testing.expect_value(t, string(blob_read(&s, s.entries[at].reps[0].hash, context.temp_allocator)), text)
	close(&s)

	testing.expect(t, system_copy(id), "it goes back on the clipboard")
	testing.expect(t, system_delete(id), "it is removed")
	gone := false
	for _ in 0 ..< 40 {
		system_refresh()
		if _, still := find_text(text); !still { gone = true; break }
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(t, gone, "it went from the history")
}
