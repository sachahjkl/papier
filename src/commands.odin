package papier

// What another process asks the running papier: one line of text, "<verb> [id]", over the instance socket. Only the
// running papier writes the history; the command line reads it and asks.

import "core:fmt"
import "core:strconv"
import "core:strings"
import instance "gt:instance"

Verb :: enum u8 { Ping, Show, Hide, Toggle, Quit, Copy, Pin, Unpin, Delete, Clear, Reload, Copy_Plain, Add_Text, Replace_Text }

COMMAND_NAMES := [Verb]string{
	.Ping = "ping", .Show = "show", .Hide = "hide", .Toggle = "toggle", .Quit = "quit",
	.Copy = "copy", .Pin = "pin", .Unpin = "unpin", .Delete = "delete", .Clear = "clear", .Reload = "reload",
	.Copy_Plain = "copy-plain", .Add_Text = "add-text", .Replace_Text = "replace-text",
}

// The verbs that name an entry.
VERBS_WITH_ID :: bit_set[Verb]{.Copy, .Pin, .Unpin, .Delete, .Copy_Plain, .Replace_Text}
// The verbs only the window sends (they carry a text, which a line of the socket does not).
WINDOW_VERBS :: bit_set[Verb]{.Add_Text, .Replace_Text}

Command :: struct {
	verb: Verb,
	id:   u64,
	text: string,   // Add_Text, Replace_Text: the text (the queue owns its copy: watcher_send)
}

command_format :: proc(c: Command, allocator := context.temp_allocator) -> string {
	if c.verb in VERBS_WITH_ID { return fmt.aprintf("%s %d", COMMAND_NAMES[c.verb], c.id, allocator = allocator) }
	return strings.clone(COMMAND_NAMES[c.verb], allocator)
}

command_parse :: proc(text: string) -> (c: Command, ok: bool) {
	f := strings.fields(text, context.temp_allocator)
	if len(f) == 0 { return }
	for name, v in COMMAND_NAMES {
		if name != f[0] || v in WINDOW_VERBS { continue }
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

SEND_WAIT_MS :: 1000

// Sends `c` to the running papier. False when none runs.
command_send :: proc(c: Command) -> bool {
	return instance.send({name = DAEMON_NAME, wait_ms = SEND_WAIT_MS}, transmute([]u8)command_format(c)) == .Forwarded
}
