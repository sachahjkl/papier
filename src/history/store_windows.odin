#+build windows
package history

// The history on Windows: the system's clipboard history (the one Win+V shows), read and changed through the Windows
// Runtime (Windows.ApplicationModel.DataTransfer.Clipboard). papier stores nothing of its own: the system records each
// copy, keeps its last 25 and its pins (which it does not tell).
//
// The watcher's thread reads it (system_refresh) into a snapshot: the entries, and the bytes of each type of each, by
// their hash. The window and the decoder read the snapshot (reload, blob_read), whatever their thread. The system
// answers only a program in the foreground: the watcher reads it again each time the window shows, and when the system
// says it changed (an access refused then keeps the snapshot as it was).
//
// An entry of the system is read once: its bytes do not change. Its id here is papier's own, given at its first read.

import "core:slice"
import "core:strings"
import "core:sync"
import "gt:platform"
import winrt "gt:winrt"

Store :: struct {
	dir:     string,           // "" (the decoder's asks name it; the system has one history)
	entries: [dynamic]Entry,   // newest first
	version: u64,              // the snapshot's version they were read at
}

// What makes an entry of the bytes of an item (capture.odin's classify): its kind, the representation that makes its
// key, its preview. ok = false: nothing papier shows.
Classify :: proc(reps: []Rep_Data, allocator := context.temp_allocator) -> (kind: Kind, main: int, preview: string, ok: bool)

@(private = "file")
Snapshot :: struct {
	mutex:   sync.Mutex,
	entries: [dynamic]Entry,   // owned
	blobs:   map[u64][]u8,     // owned
	version: u64,
}

// The watcher thread's own: the statics, the items as the system gives them, the ids given.
@(private = "file")
System :: struct {
	statics:  rawptr,              // IClipboardStatics2
	token:    i64,                 // the HistoryChanged handler's
	items:    map[u64]rawptr,      // IClipboardHistoryItem, by entry id
	ids:      map[string]u64,      // entry id, by the system's id of the item (keys owned)
	next_id:  u64,
	classify: Classify,
	failure:  winrt.HRESULT,       // what the last call that failed answered (system_failure)
	changed:  proc(user: rawptr),  // system_start's: the system's history changed
	changed_user: rawptr,
}

@(private = "file") snapshot: Snapshot
@(private = "file") system: System

////////////////////////////////
// The window's side: the snapshot

// Reads the snapshot (`dir`: unused, the system has one history). It is empty until the watcher, or system_read_once,
// read the system.
open :: proc(s: ^Store, dir: string) -> (ok: bool, why: string) {
	reload(s)
	return true, ""
}

close :: proc(s: ^Store) {
	clear_entries(s)
	delete(s.entries)
	s^ = {}
}

// Reads the snapshot again.
reload :: proc(s: ^Store) {
	clear_entries(s)
	sync.guard(&snapshot.mutex)
	for e in snapshot.entries { append(&s.entries, entry_clone(e)) }
	s.version = snapshot.version
}

// The bytes of a representation (nil when they are gone).
blob_read :: proc(s: ^Store, hash: u64, allocator := context.allocator) -> []u8 { return blob_read_in("", hash, allocator) }

// The same, from any thread.
blob_read_in :: proc(dir: string, hash: u64, allocator := context.allocator) -> []u8 {
	sync.guard(&snapshot.mutex)
	data, found := snapshot.blobs[hash]
	if !found { return nil }
	return slice.clone(data, allocator)
}

// The system's history has no index of its own: the window searches the previews (used = false).
search :: proc(s: ^Store, words: []string, allocator := context.temp_allocator) -> (ids: map[u64]bool, used: bool) {
	return make(map[u64]bool, allocator), false
}

@(private = "file")
entry_clone :: proc(e: Entry) -> Entry {
	out := e
	out.preview = strings.clone(e.preview)
	out.reps = make([]Rep, len(e.reps))
	for r, i in e.reps { out.reps[i] = {strings.clone(r.mime), r.hash, r.size} }
	return out
}

////////////////////////////////
// The watcher's side: the system

// Why the system did not answer.
System_Error :: enum u8 { None, No_Runtime, Disabled, Access_Denied, Failed }

SYSTEM_ERROR_TEXT := [System_Error]string{
	.None          = "",
	.No_Runtime    = "the Windows Runtime's clipboard is not there (Windows 10 1809 or later has it)",
	.Disabled      = "the clipboard history is off (Settings > System > Clipboard > Clipboard history)",
	.Access_Denied = "Windows lets only the program in the foreground read the clipboard history",
	.Failed        = "the clipboard history cannot be read",
}

// Joins the system's history, on the thread that will call the other system_* procedures: `changed(user)` runs (on a
// thread of the system's) each time the system's history changes. `classify` makes the entries.
system_start :: proc(classify: Classify, changed: proc(user: rawptr), user: rawptr) -> System_Error {
	// (the clipboard's statics refuse the multithreaded apartment: RO_E_UNSUPPORTED_FROM_MTA)
	if hr := winrt.init(.Single); !winrt.ok(hr) { system.failure = hr; return .No_Runtime }
	system.classify = classify
	hr: winrt.HRESULT
	system.statics, hr = winrt.factory(CLASS_CLIPBOARD, IID_IClipboardStatics2)
	if !winrt.ok(hr) || system.statics == nil { system.failure = hr; return .No_Runtime }
	if changed != nil {
		system.changed, system.changed_user = changed, user
		on_change :: proc(user: rawptr, sender: rawptr, args: rawptr) { system.changed(system.changed_user) }
		h := winrt.event_handler_make(winrt.event_handler_iid(SIG_HISTORY_CHANGED_ARGS), on_change, nil)
		statics(system.statics).add_HistoryChanged(system.statics, h, &system.token)
		winrt.release(h)   // (the system keeps its own reference until the remove)
	}
	return .None
}

system_stop :: proc() {
	if system.statics != nil {
		if system.token != 0 { statics(system.statics).remove_HistoryChanged(system.statics, system.token) }
		winrt.release(system.statics)
	}
	for _, item in system.items { winrt.release(item) }
	delete(system.items)
	for k in system.ids { delete(k) }
	delete(system.ids)
	system = {}
	sync.guard(&snapshot.mutex)
	snapshot_clear()
	delete(snapshot.entries)
	delete(snapshot.blobs)
	snapshot.entries, snapshot.blobs = nil, nil
	winrt.uninit()
}

// The HRESULT of the last call to the system that failed (for a message: 0x%08x).
system_failure :: proc() -> u32 { return u32(system.failure) }

// Whether the user turned the history on (Settings > System > Clipboard).
system_enabled :: proc() -> bool {
	on: b8
	if system.statics == nil || !winrt.ok(statics(system.statics).IsHistoryEnabled(system.statics, &on)) { return false }
	return bool(on)
}

// Reads the system's history into the snapshot. The entries already read keep their bytes; a refusal keeps the
// snapshot as it was. changed: the snapshot moved (another version).
system_refresh :: proc() -> (changed: bool, err: System_Error) {
	if system.statics == nil { return false, .No_Runtime }
	op: rawptr
	if hr := statics(system.statics).GetHistoryItemsAsync(system.statics, &op); !winrt.ok(hr) { system.failure = hr; return false, .Failed }
	result: rawptr
	if hr := winrt.await(op, handler_iid_items(), &result); !winrt.ok(hr) { system.failure = hr; return false, .Failed }
	defer winrt.release(result)
	rv := winrt.vtable(result, IClipboardHistoryItemsResult_Vtbl)
	status: i32
	rv.get_Status(result, &status)
	switch status {
	case ITEMS_ACCESS_DENIED: return false, .Access_Denied
	case ITEMS_DISABLED:      return false, .Disabled
	}
	list: rawptr
	if !winrt.ok(rv.get_Items(result, &list)) { return false, .Failed }
	defer winrt.release(list)

	entries := make([dynamic]Entry)
	blobs := make(map[u64][]u8)
	items := make(map[u64]rawptr)
	// the bytes already read, by entry id (an item's bytes do not change)
	known := make(map[u64]int, context.temp_allocator)
	{
		sync.guard(&snapshot.mutex)
		for e, i in snapshot.entries { known[e.id] = i }
	}
	for i in 0 ..< winrt.vector_size(list) {
		item: rawptr
		if !winrt.ok(winrt.vector_at(list, i, &item)) || item == nil { continue }
		iv := winrt.vtable(item, IClipboardHistoryItem_Vtbl)
		hid: winrt.HSTRING
		iv.get_Id(item, &hid)
		key := winrt.string_read(hid, context.temp_allocator)
		winrt.string_delete(hid)
		id, seen := system.ids[key]
		if !seen {
			system.next_id += 1
			id = system.next_id
			system.ids[strings.clone(key)] = id
		}
		if at, ok := known[id]; ok {
			sync.guard(&snapshot.mutex)
			e := snapshot.entries[at]
			for r in e.reps { if r.hash not_in blobs { blobs[r.hash] = slice.clone(snapshot.blobs[r.hash]) } }
			append(&entries, entry_clone(e))
		} else if e, read := item_read(item, id, &blobs); read {
			append(&entries, e)
		} else {
			winrt.release(item)
			continue
		}
		items[id] = item
	}
	slice.sort_by(entries[:], proc(a, b: Entry) -> bool { return a.time_ms > b.time_ms || (a.time_ms == b.time_ms && a.id > b.id) })

	for _, item in system.items { winrt.release(item) }
	delete(system.items)
	system.items = items
	sync.guard(&snapshot.mutex)
	changed = !same_entries(snapshot.entries[:], entries[:])
	snapshot_clear()
	delete(snapshot.entries)
	delete(snapshot.blobs)
	snapshot.entries, snapshot.blobs = entries, blobs
	if changed { snapshot.version += 1 }
	return changed, .None
}

// The snapshot's version: it moves when system_refresh reads another list.
system_version :: proc() -> u64 {
	sync.guard(&snapshot.mutex)
	return snapshot.version
}

// Puts the entry `id` on the clipboard, as Win+V does (the system moves it to the top). False when it is gone.
system_copy :: proc(id: u64) -> bool {
	item, ok := system.items[id]
	if !ok || system.statics == nil { return false }
	status: i32
	if !winrt.ok(statics(system.statics).SetHistoryItemAsContent(system.statics, item, &status)) { return false }
	return status == 0   // (SetHistoryItemAsContentStatus.Success)
}

// Removes the entry `id` from the system's history.
system_delete :: proc(id: u64) -> bool {
	item, ok := system.items[id]
	if !ok || system.statics == nil { return false }
	done: b8
	return winrt.ok(statics(system.statics).DeleteItemFromHistory(system.statics, item, &done)) && bool(done)
}

// Removes every entry the user did not pin in the system's history.
system_clear :: proc() -> bool {
	if system.statics == nil { return false }
	done: b8
	return winrt.ok(statics(system.statics).ClearHistory(system.statics, &done)) && bool(done)
}

// For a process with no watcher (`papier list`, `papier get`): the system's history read once, on this thread.
system_read_once :: proc(classify: Classify) -> System_Error {
	if err := system_start(classify, nil, nil); err != .None { return err }
	_, err := system_refresh()
	return err
}

@(private = "file")
snapshot_clear :: proc() {
	for &e in snapshot.entries { entry_free(&e) }
	clear(&snapshot.entries)
	for _, b in snapshot.blobs { delete(b) }
	clear(&snapshot.blobs)
}

@(private = "file")
same_entries :: proc(a, b: []Entry) -> bool {
	if len(a) != len(b) { return false }
	for e, i in a { if e.id != b[i].id || e.time_ms != b[i].time_ms { return false } }
	return true
}

// An item's entry: its types read (text, HTML, a picture, files), classified. Its bytes go in `blobs`.
@(private = "file")
item_read :: proc(item: rawptr, id: u64, blobs: ^map[u64][]u8) -> (e: Entry, ok: bool) {
	iv := winrt.vtable(item, IClipboardHistoryItem_Vtbl)
	stamp: i64
	iv.get_Timestamp(item, &stamp)
	view: rawptr
	if !winrt.ok(iv.get_Content(item, &view)) || view == nil { return }
	defer winrt.release(view)
	dv := winrt.vtable(view, IDataPackageView_Vtbl)

	formats := make(map[string]bool, context.temp_allocator)
	if list: rawptr; winrt.ok(dv.get_AvailableFormats(view, &list)) {
		for i in 0 ..< winrt.vector_size(list) {
			h: winrt.HSTRING
			if winrt.ok(winrt.vector_at(list, i, &h)) { formats[winrt.string_read(h, context.temp_allocator)] = true; winrt.string_delete(h) }
		}
		winrt.release(list)
	}
	reps := make([dynamic]Rep_Data, context.temp_allocator)
	_, string_handler := winrt.async_iids(winrt.SIG_STRING)
	if formats[FORMAT_TEXT] {
		op: rawptr
		h: winrt.HSTRING
		if winrt.ok(dv.GetTextAsync(view, &op)) && winrt.ok(winrt.await(op, string_handler, &h)) {
			append(&reps, Rep_Data{"text/plain;charset=utf-8", transmute([]u8)winrt.string_read(h, context.temp_allocator)})
			winrt.string_delete(h)
		}
	}
	if formats[FORMAT_HTML] {
		op: rawptr
		h: winrt.HSTRING
		if winrt.ok(dv.GetHtmlFormatAsync(view, &op)) && winrt.ok(winrt.await(op, string_handler, &h)) {
			block := winrt.string_read(h, context.temp_allocator)
			append(&reps, Rep_Data{"text/html", transmute([]u8)platform.html_format_fragment(block)})
			winrt.string_delete(h)
		}
	}
	if formats[FORMAT_BITMAP] {
		if data := bitmap_read(view); data != nil { append(&reps, Rep_Data{image_mime(data), data}) }
	}
	if formats[FORMAT_STORAGE_ITEMS] {
		if list := storage_paths(view); list != "" { append(&reps, Rep_Data{"text/uri-list", transmute([]u8)list}) }
	}
	if len(reps) == 0 || system.classify == nil { return }
	kind, main, preview, classified := system.classify(reps[:])
	if !classified { return }
	out := make([]Rep, len(reps))
	for r, i in reps {
		h := hash_bytes(r.data)
		if h not_in blobs^ { blobs[h] = slice.clone(r.data) }
		out[i] = {strings.clone(r.mime), h, len(r.data)}
	}
	return Entry{
		id = id, time_ms = (stamp - WINDOWS_TO_UNIX_100NS) / 10_000, kind = kind, key = out[main].hash,
		preview = strings.clone(clip_preview(preview)), reps = out,
	}, true
}

// The picture of a view: its stream, read whole (a PNG or a BMP, as the program that copied it gave it).
@(private = "file")
bitmap_read :: proc(view: rawptr) -> []u8 {
	op: rawptr
	if !winrt.ok(winrt.vtable(view, IDataPackageView_Vtbl).GetBitmapAsync(view, &op)) { return nil }
	ref: rawptr
	if !winrt.ok(winrt.await(op, handler_iid_stream_reference(), &ref)) || ref == nil { return nil }
	defer winrt.release(ref)
	op = nil
	if !winrt.ok(winrt.vtable(ref, IRandomAccessStreamReference_Vtbl).OpenReadAsync(ref, &op)) { return nil }
	stream: rawptr
	if !winrt.ok(winrt.await(op, handler_iid_stream(), &stream)) || stream == nil { return nil }
	defer winrt.release(stream)
	return stream_read_all(stream)
}

// The bytes of a Windows Runtime stream, through the COM stream over it (CreateStreamOverRandomAccessStream).
@(private = "file")
stream_read_all :: proc(stream: rawptr) -> []u8 {
	iid := IID_IStream
	com: rawptr
	if !winrt.ok(CreateStreamOverRandomAccessStream(stream, &iid, &com)) || com == nil { return nil }
	defer winrt.release(com)
	out := make([dynamic]u8, context.temp_allocator)
	buf: [64 * 1024]u8
	for {
		n: u32
		hr := (^^IStream_Vtbl)(com)^.Read(com, &buf[0], len(buf), &n)
		if n > 0 { append(&out, ..buf[:n]) }
		if !winrt.ok(hr) || n == 0 || hr == S_FALSE { break }
	}
	return out[:]
}

// The paths of the files of a view, as a text/uri-list.
@(private = "file")
storage_paths :: proc(view: rawptr) -> string {
	op: rawptr
	if !winrt.ok(winrt.vtable(view, IDataPackageView_Vtbl).GetStorageItemsAsync(view, &op)) { return "" }
	list: rawptr
	if !winrt.ok(winrt.await(op, handler_iid_storage_items(), &list)) || list == nil { return "" }
	defer winrt.release(list)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< winrt.vector_size(list) {
		item: rawptr
		if !winrt.ok(winrt.vector_at(list, i, &item)) || item == nil { continue }
		h: winrt.HSTRING
		if winrt.ok(winrt.vtable(item, IStorageItem_Vtbl).get_Path(item, &h)) {
			path, _ := strings.replace_all(winrt.string_read(h, context.temp_allocator), "\\", "/", context.temp_allocator)
			if path != "" {
				strings.write_string(&b, platform.file_uri(strings.concatenate({"/", path}, context.temp_allocator)))
				strings.write_string(&b, "\r\n")
			}
			winrt.string_delete(h)
		}
		winrt.release(item)
	}
	return strings.to_string(b)
}

// A picture's type by its first bytes.
@(private = "file")
image_mime :: proc(b: []u8) -> string {
	switch {
	case len(b) >= 8 && string(b[:8]) == "\x89PNG\r\n\x1a\n": return "image/png"
	case len(b) >= 3 && string(b[:3]) == "\xff\xd8\xff":       return "image/jpeg"
	case len(b) >= 2 && string(b[:2]) == "BM":                 return "image/bmp"
	case len(b) >= 6 && string(b[:6]) == "GIF89a":             return "image/gif"
	}
	return "image/png"
}

////////////////////////////////
// The interfaces (windows.applicationmodel.datatransfer.h, windows.storage.h, windows.storage.streams.h, objidl.h)

@(private = "file") CLASS_CLIPBOARD :: "Windows.ApplicationModel.DataTransfer.Clipboard"

@(private = "file") FORMAT_TEXT          :: "Text"
@(private = "file") FORMAT_HTML          :: "HTML Format"
@(private = "file") FORMAT_BITMAP        :: "Bitmap"
@(private = "file") FORMAT_STORAGE_ITEMS :: "Shell IDList Array"

// ClipboardHistoryItemsResultStatus
@(private = "file") ITEMS_ACCESS_DENIED :: 1
@(private = "file") ITEMS_DISABLED      :: 2

// From 1601-01-01 (DateTime's start) to 1970-01-01, in 100 ns.
@(private = "file") WINDOWS_TO_UNIX_100NS :: 116_444_736_000_000_000

@(private = "file") S_FALSE :: winrt.HRESULT(1)

@(private = "file") IID_IClipboardStatics2           :: winrt.GUID{0xd2ac1b6a, 0xd29f, 0x554b, {0xb3, 0x03, 0xf0, 0x45, 0x23, 0x45, 0xfe, 0x02}}
@(private = "file") IID_IClipboardHistoryItemsResult :: winrt.GUID{0xe6dfdee6, 0x0ee2, 0x52e3, {0x85, 0x2b, 0xf2, 0x95, 0xdb, 0x65, 0x93, 0x9a}}
@(private = "file") IID_IClipboardHistoryChangedEventArgs :: winrt.GUID{0xc0be453f, 0x8ea2, 0x53ce, {0x9a, 0xba, 0x8d, 0x22, 0x12, 0x57, 0x34, 0x52}}
@(private = "file") IID_IRandomAccessStreamReference :: winrt.GUID{0x33ee3134, 0x1dd6, 0x4e3a, {0x80, 0x67, 0xd1, 0xc1, 0x62, 0xe8, 0x64, 0x2b}}
@(private = "file") IID_IRandomAccessStreamWithContentType :: winrt.GUID{0xcc254827, 0x4b3d, 0x438f, {0x92, 0x32, 0x10, 0xc7, 0x6b, 0xc7, 0xe0, 0x38}}
@(private = "file") IID_IStorageItem                 :: winrt.GUID{0x4207a996, 0xca2f, 0x42f7, {0xbd, 0xe8, 0x8b, 0x10, 0x45, 0x7a, 0x7f, 0x30}}
@(private = "file") IID_IStream                      :: winrt.GUID{0x0000000c, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}

@(private = "file") SIG_HISTORY_CHANGED_ARGS :: "rc(Windows.ApplicationModel.DataTransfer.ClipboardHistoryChangedEventArgs;{c0be453f-8ea2-53ce-9aba-8d2212573452})"

// The completion handlers' IDs: AsyncOperationCompletedHandler<ClipboardHistoryItemsResult>,
// <RandomAccessStreamReference>, <IRandomAccessStreamWithContentType>, <IVectorView<IStorageItem>>.
@(private = "file")
handler_iid_items :: proc() -> winrt.GUID {
	_, h := winrt.async_iids(winrt.sig_class("Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult", IID_IClipboardHistoryItemsResult))
	return h
}
@(private = "file")
handler_iid_stream_reference :: proc() -> winrt.GUID {
	_, h := winrt.async_iids(winrt.sig_class("Windows.Storage.Streams.RandomAccessStreamReference", IID_IRandomAccessStreamReference))
	return h
}
@(private = "file")
handler_iid_stream :: proc() -> winrt.GUID {
	_, h := winrt.async_iids(winrt.sig_interface(IID_IRandomAccessStreamWithContentType))
	return h
}
@(private = "file")
handler_iid_storage_items :: proc() -> winrt.GUID {
	_, h := winrt.async_iids(winrt.sig_generic(winrt.PIID_IVectorView, winrt.sig_interface(IID_IStorageItem)))
	return h
}

@(private = "file")
IClipboardStatics2_Vtbl :: struct {
	using base:              winrt.IInspectable_Vtbl,
	GetHistoryItemsAsync:    proc "system" (this: rawptr, operation: ^rawptr) -> winrt.HRESULT,
	ClearHistory:            proc "system" (this: rawptr, done: ^b8) -> winrt.HRESULT,
	DeleteItemFromHistory:   proc "system" (this: rawptr, item: rawptr, done: ^b8) -> winrt.HRESULT,
	SetHistoryItemAsContent: proc "system" (this: rawptr, item: rawptr, status: ^i32) -> winrt.HRESULT,
	IsHistoryEnabled:        proc "system" (this: rawptr, on: ^b8) -> winrt.HRESULT,
	IsRoamingEnabled:        rawptr,
	SetContentWithOptions:   rawptr,
	add_HistoryChanged:      proc "system" (this: rawptr, handler: rawptr, token: ^i64) -> winrt.HRESULT,
	remove_HistoryChanged:   proc "system" (this: rawptr, token: i64) -> winrt.HRESULT,
	add_RoamingEnabledChanged:    rawptr,
	remove_RoamingEnabledChanged: rawptr,
	add_HistoryEnabledChanged:    rawptr,
	remove_HistoryEnabledChanged: rawptr,
}

@(private = "file")
statics :: #force_inline proc(s: rawptr) -> ^IClipboardStatics2_Vtbl { return winrt.vtable(s, IClipboardStatics2_Vtbl) }

@(private = "file")
IClipboardHistoryItemsResult_Vtbl :: struct {
	using base: winrt.IInspectable_Vtbl,
	get_Status: proc "system" (this: rawptr, status: ^i32) -> winrt.HRESULT,
	get_Items:  proc "system" (this: rawptr, items: ^rawptr) -> winrt.HRESULT,
}

@(private = "file")
IClipboardHistoryItem_Vtbl :: struct {
	using base:    winrt.IInspectable_Vtbl,
	get_Id:        proc "system" (this: rawptr, id: ^winrt.HSTRING) -> winrt.HRESULT,
	get_Timestamp: proc "system" (this: rawptr, stamp: ^i64) -> winrt.HRESULT,
	get_Content:   proc "system" (this: rawptr, view: ^rawptr) -> winrt.HRESULT,
}

@(private = "file")
IDataPackageView_Vtbl :: struct {
	using base:               winrt.IInspectable_Vtbl,
	get_Properties:           rawptr,
	get_RequestedOperation:   rawptr,
	ReportOperationCompleted: rawptr,
	get_AvailableFormats:     proc "system" (this: rawptr, formats: ^rawptr) -> winrt.HRESULT,
	Contains:                 rawptr,
	GetDataAsync:             rawptr,
	GetTextAsync:             proc "system" (this: rawptr, operation: ^rawptr) -> winrt.HRESULT,
	GetCustomTextAsync:       rawptr,
	GetUriAsync:              rawptr,
	GetHtmlFormatAsync:       proc "system" (this: rawptr, operation: ^rawptr) -> winrt.HRESULT,
	GetResourceMapAsync:      rawptr,
	GetRtfAsync:              rawptr,
	GetBitmapAsync:           proc "system" (this: rawptr, operation: ^rawptr) -> winrt.HRESULT,
	GetStorageItemsAsync:     proc "system" (this: rawptr, operation: ^rawptr) -> winrt.HRESULT,
}

@(private = "file")
IRandomAccessStreamReference_Vtbl :: struct {
	using base:    winrt.IInspectable_Vtbl,
	OpenReadAsync: proc "system" (this: rawptr, operation: ^rawptr) -> winrt.HRESULT,
}

@(private = "file")
IStorageItem_Vtbl :: struct {
	using base:              winrt.IInspectable_Vtbl,
	RenameAsyncOverloadDefaultOptions: rawptr,
	RenameAsync:             rawptr,
	DeleteAsyncOverloadDefaultOptions: rawptr,
	DeleteAsync:             rawptr,
	GetBasicPropertiesAsync: rawptr,
	get_Name:                rawptr,
	get_Path:                proc "system" (this: rawptr, path: ^winrt.HSTRING) -> winrt.HRESULT,
}

// ISequentialStream's Read, the third method after IUnknown's.
@(private = "file")
IStream_Vtbl :: struct {
	QueryInterface: rawptr,
	AddRef:         rawptr,
	Release:        rawptr,
	Read:           proc "system" (this: rawptr, buffer: rawptr, size: u32, read: ^u32) -> winrt.HRESULT,
}

foreign import shcore "system:shcore.lib"

@(default_calling_convention = "system", private = "file")
foreign shcore {
	CreateStreamOverRandomAccessStream :: proc(stream: rawptr, riid: ^winrt.GUID, out: ^rawptr) -> winrt.HRESULT ---
}

