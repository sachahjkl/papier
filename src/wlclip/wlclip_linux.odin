#+build linux
// Package wlclip: the Wayland clipboard as a clipboard manager sees it, with no window and no keyboard focus.
//
// A normal client hears of the clipboard only while one of its windows has the focus (wl_data_device). A manager
// uses the data-control protocol instead: ext-data-control-v1 (the standard one), or zwlr-data-control-unstable-v1
// where only that one is offered. Both have the same requests and events; only the names differ. Through it the
// manager is told of every new selection, reads any of its MIME types over a pipe, and can set the selection itself
// (it then serves the bytes until another client takes the selection).
//
// libwayland-client is opened with dlopen (no link at build time), as the toolkit does. The protocol tables are built
// here by hand: the protocol is not in libwayland.
//
// The client is driven by the caller's loop: `poll_begin`, a poll on `fd` (with any other descriptor of the caller),
// `poll_end`. Events update `clipboard` / `primary`; the caller reads them with `take`, then `receive`s what it wants.
package wlclip

import "base:runtime"
import "core:strings"
import "core:sys/posix"
import "core:time"

Interface :: struct {
	name:         cstring,
	version:      i32,
	method_count: i32,
	methods:      [^]Message,
	event_count:  i32,
	events:       [^]Message,
}

Message :: struct {
	name:      cstring,
	signature: cstring,
	types:     [^]^Interface,
}

Proxy :: distinct rawptr
Display :: distinct rawptr

@(private) MARSHAL_FLAG_DESTROY :: 1

// The entry points of libwayland-client this package calls.
@(private)
Lib :: struct {
	handle:                   posix.Symbol_Table,
	display_connect:          proc "c" (name: cstring) -> Display,
	display_disconnect:       proc "c" (d: Display),
	display_get_fd:           proc "c" (d: Display) -> i32,
	display_dispatch_pending: proc "c" (d: Display) -> i32,
	display_prepare_read:     proc "c" (d: Display) -> i32,
	display_read_events:      proc "c" (d: Display) -> i32,
	display_cancel_read:      proc "c" (d: Display),
	display_flush:            proc "c" (d: Display) -> i32,
	display_roundtrip:        proc "c" (d: Display) -> i32,
	display_get_error:        proc "c" (d: Display) -> i32,
	proxy_marshal_flags:      proc "c" (p: Proxy, opcode: u32, iface: ^Interface, version: u32, flags: u32, #c_vararg args: ..any) -> Proxy,
	proxy_add_listener:       proc "c" (p: Proxy, implementation: rawptr, data: rawptr) -> i32,
	proxy_get_version:        proc "c" (p: Proxy) -> u32,
	registry_interface:       ^Interface,
	seat_interface:           ^Interface,
}

@(private) lib: Lib

@(private)
lib_load :: proc() -> bool {
	if lib.handle != nil { return true }
	h := posix.dlopen("libwayland-client.so.0", posix.RTLD_LOCAL + {.NOW})
	if h == nil { h = posix.dlopen("libwayland-client.so", posix.RTLD_LOCAL + {.NOW}) }
	if h == nil { return false }
	sym :: proc(h: posix.Symbol_Table, name: cstring) -> rawptr { return posix.dlsym(h, name) }
	l := Lib{handle = h}
	l.display_connect = auto_cast sym(h, "wl_display_connect")
	l.display_disconnect = auto_cast sym(h, "wl_display_disconnect")
	l.display_get_fd = auto_cast sym(h, "wl_display_get_fd")
	l.display_dispatch_pending = auto_cast sym(h, "wl_display_dispatch_pending")
	l.display_prepare_read = auto_cast sym(h, "wl_display_prepare_read")
	l.display_read_events = auto_cast sym(h, "wl_display_read_events")
	l.display_cancel_read = auto_cast sym(h, "wl_display_cancel_read")
	l.display_flush = auto_cast sym(h, "wl_display_flush")
	l.display_roundtrip = auto_cast sym(h, "wl_display_roundtrip")
	l.display_get_error = auto_cast sym(h, "wl_display_get_error")
	l.proxy_marshal_flags = auto_cast sym(h, "wl_proxy_marshal_flags")
	l.proxy_add_listener = auto_cast sym(h, "wl_proxy_add_listener")
	l.proxy_get_version = auto_cast sym(h, "wl_proxy_get_version")
	l.registry_interface = auto_cast sym(h, "wl_registry_interface")
	l.seat_interface = auto_cast sym(h, "wl_seat_interface")
	if l.display_connect == nil || l.proxy_marshal_flags == nil || l.registry_interface == nil || l.seat_interface == nil {
		posix.dlclose(h)
		return false
	}
	lib = l
	return true
}

////////////////////////////////
// The protocol tables (ext-data-control-v1.xml, wlr-data-control-unstable-v1.xml)

Protocol :: enum u8 { None, Ext, Wlr }

// Requests (the order of the XML).
@(private) MANAGER_CREATE_DATA_SOURCE :: 0
@(private) MANAGER_GET_DATA_DEVICE    :: 1
@(private) DEVICE_SET_SELECTION       :: 0
@(private) DEVICE_SET_PRIMARY         :: 2
@(private) SOURCE_OFFER               :: 0
@(private) SOURCE_DESTROY             :: 1
@(private) OFFER_RECEIVE              :: 0
@(private) OFFER_DESTROY              :: 1
// The version of a device that has the primary selection.
@(private) PRIMARY_SINCE_WLR :: 2

@(private)
Tables :: struct {
	manager, device, source, offer: Interface,
	manager_m: [3]Message,
	device_m:  [3]Message,
	device_e:  [4]Message,
	source_m:  [2]Message,
	source_e:  [2]Message,
	offer_m:   [2]Message,
	offer_e:   [1]Message,
	t_source:  [1]^Interface,
	t_device:  [2]^Interface,
	t_offer:   [1]^Interface,
	t_none:    [2]^Interface,
}

@(private) tables: [Protocol]Tables

@(private)
tables_build :: proc(p: Protocol) {
	t := &tables[p]
	names := p == .Ext ? [4]cstring{"ext_data_control_manager_v1", "ext_data_control_device_v1", "ext_data_control_source_v1", "ext_data_control_offer_v1"} : [4]cstring{"zwlr_data_control_manager_v1", "zwlr_data_control_device_v1", "zwlr_data_control_source_v1", "zwlr_data_control_offer_v1"}
	version: i32 = p == .Ext ? 1 : 2
	since := p == .Ext ? cstring("?o") : cstring("2?o")
	t.t_source = {&t.source}
	t.t_device = {&t.device, lib.seat_interface}
	t.t_offer = {&t.offer}
	t.manager_m = {{"create_data_source", "n", &t.t_source[0]}, {"get_data_device", "no", &t.t_device[0]}, {"destroy", "", nil}}
	t.device_m = {{"set_selection", "?o", &t.t_source[0]}, {"destroy", "", nil}, {"set_primary_selection", since, &t.t_source[0]}}
	t.device_e = {{"data_offer", "n", &t.t_offer[0]}, {"selection", "?o", &t.t_offer[0]}, {"finished", "", nil}, {"primary_selection", since, &t.t_offer[0]}}
	t.source_m = {{"offer", "s", &t.t_none[0]}, {"destroy", "", nil}}
	t.source_e = {{"send", "sh", &t.t_none[0]}, {"cancelled", "", nil}}
	t.offer_m = {{"receive", "sh", &t.t_none[0]}, {"destroy", "", nil}}
	t.offer_e = {{"offer", "s", &t.t_none[0]}}
	t.manager = {names[0], version, 3, &t.manager_m[0], 0, nil}
	t.device = {names[1], version, 3, &t.device_m[0], 4, &t.device_e[0]}
	t.source = {names[2], version, 2, &t.source_m[0], 2, &t.source_e[0]}
	t.offer = {names[3], version, 2, &t.offer_m[0], 1, &t.offer_e[0]}
}

////////////////////////////////
// The client

Which :: enum u8 { Clipboard, Primary }

// A selection as the compositor last told it.
Selection :: struct {
	offer:   Proxy,   // nil: empty
	own:     bool,    // it is this client's own source
	changed: bool,    // since the last `take`
}

// What this client serves while its source holds a selection.
Served :: struct {
	mime: string,
	data: []u8,
}

Client :: struct {
	ctx:       runtime.Context,
	display:   Display,
	registry:  Proxy,
	seat:      Proxy,
	manager:   Proxy,
	device:    Proxy,
	protocol:  Protocol,
	globals:   [Protocol]struct { name, version: u32 },
	seat_name: u32,
	offers:    map[Proxy][dynamic]string,       // the MIME types of every offer alive
	sel:       [Which]Selection,
	source:    [Which]Proxy,
	served:    [Which][]Served,                   // owned
	finished:  bool,                              // the compositor ended the device: connect again
	write_ms:  int,                               // how long a reader is waited for while a selection is served
}

// How long a peer is waited for while bytes go to it or come from it.
WRITE_WAIT_MS_DEFAULT :: 2000
@(private) PIPE_CHUNK_BYTES :: 4096   // PIPE_BUF: a write of this size after POLLOUT does not block

// Connects to the compositor and binds data-control. `why` says what is missing when it fails.
connect :: proc(c: ^Client) -> (ok: bool, why: string) {
	c.ctx = context
	if c.write_ms == 0 { c.write_ms = WRITE_WAIT_MS_DEFAULT }
	if !lib_load() { return false, "libwayland-client cannot be opened" }
	// a reader that closes its end early must not kill the process
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	c.display = lib.display_connect(nil)
	if c.display == nil { return false, "no Wayland display ($WAYLAND_DISPLAY)" }
	c.registry = lib.proxy_marshal_flags(Proxy(c.display), 1 /* get_registry */, lib.registry_interface, lib.proxy_get_version(Proxy(c.display)), 0, nil)
	lib.proxy_add_listener(c.registry, &registry_listener, c)
	lib.display_roundtrip(c.display)
	switch {
	case c.globals[.Ext].name != 0: c.protocol = .Ext
	case c.globals[.Wlr].name != 0: c.protocol = .Wlr
	case:
		disconnect(c)
		return false, "the compositor offers no data-control protocol (ext-data-control-v1 or zwlr-data-control-unstable-v1)"
	}
	if c.seat_name == 0 { disconnect(c); return false, "the compositor has no seat" }
	tables_build(c.protocol)
	t := &tables[c.protocol]
	g := c.globals[c.protocol]
	version := min(g.version, u32(t.manager.version))
	c.seat = lib.proxy_marshal_flags(c.registry, 0, lib.seat_interface, 1, 0, c.seat_name, lib.seat_interface.name, u32(1), nil)
	c.manager = lib.proxy_marshal_flags(c.registry, 0, &t.manager, version, 0, g.name, t.manager.name, version, nil)
	c.device = lib.proxy_marshal_flags(c.manager, MANAGER_GET_DATA_DEVICE, &t.device, version, 0, nil, c.seat)
	lib.proxy_add_listener(c.device, &device_listener, c)
	lib.display_roundtrip(c.display)   // (the current selection arrives now)
	if lib.display_get_error(c.display) != 0 { disconnect(c); return false, "the compositor refused the data-control device" }
	return true, ""
}

disconnect :: proc(c: ^Client) {
	for w in Which { served_free(c, w) }
	for _, mimes in c.offers {
		for m in mimes { delete(m) }
		delete(mimes)
	}
	delete(c.offers)
	if c.display != nil { lib.display_disconnect(c.display) }   // (every proxy goes with the connection)
	c^ = {}
}

// Whether the version bound has the primary selection.
has_primary :: proc(c: ^Client) -> bool {
	return c.protocol == .Ext || (c.device != nil && lib.proxy_get_version(c.device) >= PRIMARY_SINCE_WLR)
}

fd :: proc(c: ^Client) -> posix.FD { return posix.FD(lib.display_get_fd(c.display)) }

// Before a poll: what is queued is dispatched, the requests are sent. False when the connection is gone.
poll_begin :: proc(c: ^Client) -> bool {
	for lib.display_prepare_read(c.display) != 0 {
		if lib.display_dispatch_pending(c.display) < 0 { return false }
	}
	lib.display_flush(c.display)
	return true
}

// After the poll: `readable` is whether `fd` was. The events read are dispatched. False when the connection is gone.
poll_end :: proc(c: ^Client, readable: bool) -> bool {
	if readable {
		if lib.display_read_events(c.display) < 0 { return false }
	} else {
		lib.display_cancel_read(c.display)
	}
	return lib.display_dispatch_pending(c.display) >= 0 && lib.display_get_error(c.display) == 0 && !c.finished
}

// The selection `w` if it changed since the last call: its offer and MIME types (valid until the next poll_end).
take :: proc(c: ^Client, w: Which) -> (offer: Proxy, mimes: []string, own, changed: bool) {
	s := &c.sel[w]
	if !s.changed { return }
	s.changed = false
	if s.offer != nil { mimes = c.offers[s.offer][:] }
	return s.offer, mimes, s.own, true
}

Receive_Error :: enum u8 { None, Failed, Too_Big, Timeout }

// Reads the bytes of `mime` of `offer`. The connection keeps being served meanwhile (the offer may be this client's
// own source, which must answer). Stops past `max_bytes` (0: no limit) or after `wait_ms` without a byte.
receive :: proc(c: ^Client, offer: Proxy, mime: string, max_bytes: int, wait_ms: int, allocator := context.allocator) -> (data: []u8, err: Receive_Error) {
	if offer == nil { return nil, .Failed }
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return nil, .Failed }
	read_fd, write_fd := fds[0], fds[1]
	defer posix.close(read_fd)
	cmime := strings.clone_to_cstring(mime, context.temp_allocator)
	lib.proxy_marshal_flags(offer, OFFER_RECEIVE, nil, lib.proxy_get_version(offer), 0, cmime, i32(write_fd))
	lib.display_flush(c.display)
	posix.close(write_fd)   // (the compositor has its own copy: ours must go for the read to see the end)
	buf := make([dynamic]u8, allocator)
	chunk: [64 * 1024]u8
	last := time.tick_now()
	for {
		if !poll_begin(c) { delete(buf); return nil, .Failed }
		pfd := [2]posix.pollfd{{fd = read_fd, events = {.IN}}, {fd = fd(c), events = {.IN}}}
		n := posix.poll(&pfd[0], 2, 100)
		if !poll_end(c, n > 0 && .IN in pfd[1].revents) { delete(buf); return nil, .Failed }
		if n < 0 { continue }
		if pfd[0].revents & {.IN, .HUP, .ERR} == {} {
			if time.duration_milliseconds(time.tick_since(last)) > f64(wait_ms) { delete(buf); return nil, .Timeout }
			continue
		}
		got := posix.read(read_fd, &chunk[0], len(chunk))
		if got < 0 { delete(buf); return nil, .Failed }
		if got == 0 { return buf[:], .None }
		if max_bytes > 0 && len(buf) + int(got) > max_bytes { delete(buf); return nil, .Too_Big }
		append(&buf, ..chunk[:got])
		last = time.tick_now()
	}
}

// Takes the selection `w` and serves `reps` (copied) until another client takes it. Several MIME types may name the
// same bytes (aliases): give each its own Served.
set_selection :: proc(c: ^Client, reps: []Served, w := Which.Clipboard) -> bool {
	if c.manager == nil || len(reps) == 0 { return false }
	if w == .Primary && !has_primary(c) { return false }
	t := &tables[c.protocol]
	served_free(c, w)
	src := lib.proxy_marshal_flags(c.manager, MANAGER_CREATE_DATA_SOURCE, &t.source, lib.proxy_get_version(c.manager), 0, nil)
	if src == nil { return false }
	lib.proxy_add_listener(src, &source_listener, c)
	out := make([]Served, len(reps))
	for r, i in reps {
		d := make([]u8, len(r.data))
		copy(d, r.data)
		out[i] = {strings.clone(r.mime), d}
		lib.proxy_marshal_flags(src, SOURCE_OFFER, nil, lib.proxy_get_version(src), 0, strings.clone_to_cstring(r.mime, context.temp_allocator))
	}
	c.source[w], c.served[w] = src, out
	lib.proxy_marshal_flags(c.device, w == .Clipboard ? DEVICE_SET_SELECTION : DEVICE_SET_PRIMARY, nil, lib.proxy_get_version(c.device), 0, src)
	lib.display_flush(c.display)
	return true
}

// Whether this client holds the selection `w` now.
holds :: proc(c: ^Client, w: Which) -> bool { return c.source[w] != nil }

@(private)
served_free :: proc(c: ^Client, w: Which) {
	if src := c.source[w]; src != nil {
		lib.proxy_marshal_flags(src, SOURCE_DESTROY, nil, lib.proxy_get_version(src), MARSHAL_FLAG_DESTROY)
		c.source[w] = nil
	}
	for r in c.served[w] { delete(r.mime); delete(r.data) }
	delete(c.served[w])
	c.served[w] = nil
}

////////////////////////////////
// Listeners

@(private)
Registry_Listener :: struct {
	global:        proc "c" (data: rawptr, r: Proxy, name: u32, iface: cstring, version: u32),
	global_remove: proc "c" (data: rawptr, r: Proxy, name: u32),
}
@(private) registry_listener := Registry_Listener{on_global, on_global_remove}

@(private)
on_global :: proc "c" (data: rawptr, r: Proxy, name: u32, iface: cstring, version: u32) {
	c := (^Client)(data)
	switch string(iface) {
	case "wl_seat":                      if c.seat_name == 0 { c.seat_name = name }
	case "ext_data_control_manager_v1":  c.globals[.Ext] = {name, version}
	case "zwlr_data_control_manager_v1": c.globals[.Wlr] = {name, version}
	}
}

@(private)
on_global_remove :: proc "c" (data: rawptr, r: Proxy, name: u32) {}

@(private)
Device_Listener :: struct {
	data_offer:        proc "c" (data: rawptr, d: Proxy, offer: Proxy),
	selection:         proc "c" (data: rawptr, d: Proxy, offer: Proxy),
	finished:          proc "c" (data: rawptr, d: Proxy),
	primary_selection: proc "c" (data: rawptr, d: Proxy, offer: Proxy),
}
@(private) device_listener := Device_Listener{on_data_offer, on_selection, on_finished, on_primary_selection}

@(private)
Offer_Listener :: struct {
	offer: proc "c" (data: rawptr, o: Proxy, mime: cstring),
}
@(private) offer_listener := Offer_Listener{on_offer_mime}

@(private)
Source_Listener :: struct {
	send:      proc "c" (data: rawptr, s: Proxy, mime: cstring, fd: i32),
	cancelled: proc "c" (data: rawptr, s: Proxy),
}
@(private) source_listener := Source_Listener{on_send, on_cancelled}

@(private)
on_data_offer :: proc "c" (data: rawptr, d: Proxy, offer: Proxy) {
	c := (^Client)(data)
	context = c.ctx
	lib.proxy_add_listener(offer, &offer_listener, c)
	c.offers[offer] = make([dynamic]string)
}

@(private)
on_offer_mime :: proc "c" (data: rawptr, o: Proxy, mime: cstring) {
	c := (^Client)(data)
	context = c.ctx
	if list, ok := &c.offers[o]; ok { append(list, strings.clone(string(mime))) }
}

@(private)
selection_set :: proc(c: ^Client, w: Which, offer: Proxy) {
	s := &c.sel[w]
	if s.offer != nil && s.offer != offer { offer_drop(c, s.offer) }
	// The compositor cancels the source it replaces before it names the new selection: a source still held now is
	// the one this offer comes from.
	s^ = {offer = offer, own = c.source[w] != nil, changed = true}
}

@(private)
offer_drop :: proc(c: ^Client, offer: Proxy) {
	if mimes, ok := c.offers[offer]; ok {
		for m in mimes { delete(m) }
		delete(mimes)
		delete_key(&c.offers, offer)
	}
	lib.proxy_marshal_flags(offer, OFFER_DESTROY, nil, lib.proxy_get_version(offer), MARSHAL_FLAG_DESTROY)
}

@(private)
on_selection :: proc "c" (data: rawptr, d: Proxy, offer: Proxy) {
	c := (^Client)(data)
	context = c.ctx
	selection_set(c, .Clipboard, offer)
}

@(private)
on_primary_selection :: proc "c" (data: rawptr, d: Proxy, offer: Proxy) {
	c := (^Client)(data)
	context = c.ctx
	selection_set(c, .Primary, offer)
}

@(private)
on_finished :: proc "c" (data: rawptr, d: Proxy) { (^Client)(data).finished = true }

@(private)
on_send :: proc "c" (data: rawptr, s: Proxy, mime: cstring, fd: i32) {
	c := (^Client)(data)
	context = c.ctx
	defer posix.close(posix.FD(fd))
	for w in Which {
		if c.source[w] != s { continue }
		for r in c.served[w] {
			if r.mime == string(mime) { write_all(posix.FD(fd), r.data, c.write_ms); return }
		}
	}
}

@(private)
on_cancelled :: proc "c" (data: rawptr, s: Proxy) {
	c := (^Client)(data)
	context = c.ctx
	for w in Which { if c.source[w] == s { served_free(c, w) } }
}

// Writes `data` to a pipe in chunks the pipe takes without blocking; gives up when the reader takes nothing for `wait_ms`.
@(private)
write_all :: proc(fd: posix.FD, data: []u8, wait_ms: int) {
	at := 0
	for at < len(data) {
		pfd := posix.pollfd{fd = fd, events = {.OUT}}
		if posix.poll(&pfd, 1, i32(wait_ms)) <= 0 || pfd.revents & {.ERR, .HUP} != {} { return }
		n := posix.write(fd, raw_data(data[at:]), uint(min(PIPE_CHUNK_BYTES, len(data) - at)))
		if n <= 0 { return }
		at += int(n)
	}
}
