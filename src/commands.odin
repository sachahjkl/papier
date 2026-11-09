package papier

// What the picker and the command line ask the daemon: one line of text, "<verb> [id]", over the instance socket. Only the
// daemon writes the history; the others read it and ask.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import instance "gt:instance"

Verb :: enum u8 { Ping, Copy, Pin, Unpin, Delete, Clear, Reload, Quit }

COMMAND_NAMES := [Verb]string{.Ping = "ping", .Copy = "copy", .Pin = "pin", .Unpin = "unpin", .Delete = "delete", .Clear = "clear", .Reload = "reload", .Quit = "quit"}

// The verbs that name an entry.
VERBS_WITH_ID :: bit_set[Verb]{.Copy, .Pin, .Unpin, .Delete}

Command :: struct {
	verb: Verb,
	id:   u64,
}

command_format :: proc(c: Command, allocator := context.temp_allocator) -> string {
	if c.verb in VERBS_WITH_ID { return fmt.aprintf("%s %d", COMMAND_NAMES[c.verb], c.id, allocator = allocator) }
	return strings.clone(COMMAND_NAMES[c.verb], allocator)
}

command_parse :: proc(text: string) -> (c: Command, ok: bool) {
	f := strings.fields(text, context.temp_allocator)
	if len(f) == 0 { return }
	for name, v in COMMAND_NAMES {
		if name != f[0] { continue }
		c.verb = v
		if v in VERBS_WITH_ID {
			if len(f) != 2 { return }
			c.id = strconv.parse_u64(f[1]) or_return
		} else if len(f) != 1 {
			return
		}
		return c, true
	}
	return
}

// How long a start of the daemon is waited for before a command is given up.
DAEMON_START_WAIT_MS :: 3000
DAEMON_RETRY_MS      :: 50
SEND_WAIT_MS         :: 1000

// Sends `c` to the daemon. `start`: a daemon that does not run is started first (detached), and waited for.
command_send :: proc(c: Command, start := false) -> bool {
	msg := transmute([]u8)command_format(c)
	if instance.send({name = DAEMON_NAME, wait_ms = SEND_WAIT_MS}, msg) == .Forwarded { return true }
	if !start || !daemon_spawn() { return false }
	deadline := time.tick_add(time.tick_now(), DAEMON_START_WAIT_MS * time.Millisecond)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		time.sleep(DAEMON_RETRY_MS * time.Millisecond)
		if instance.send({name = DAEMON_NAME, wait_ms = SEND_WAIT_MS}, msg) == .Forwarded { return true }
	}
	return false
}

// Whether a daemon answers.
daemon_running :: proc() -> bool {
	return instance.send({name = DAEMON_NAME, wait_ms = 200}, transmute([]u8)string("ping")) == .Forwarded
}

// Starts `papier daemon` as a process of its own (it outlives this one).
daemon_spawn :: proc() -> bool {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return false }
	_, perr := os.process_start({command = {exe, "daemon"}})
	if perr != nil { return false }
	return true
}
