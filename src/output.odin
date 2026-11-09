package papier

// What papier writes for the person or the script that ran it. On Windows papier is a program of the windows subsystem
// (no console of its own, none flashes at a start with the session): its text goes to the standard outputs the parent
// gave, or else to the parent's console (gt:process).

import "core:fmt"
import "gt:process"

outf  :: proc(format: string, args: ..any) { process.console_write(fmt.tprintfln(format, ..args)) }
outln :: proc(text: string) { process.console_write(fmt.tprintln(text)) }
outs  :: proc(text: string) { process.console_write(text) }
errf  :: proc(format: string, args: ..any) { process.console_error(fmt.tprintfln(format, ..args)) }
errln :: proc(text: string) { process.console_error(fmt.tprintln(text)) }
errs  :: proc(text: string) { process.console_error(text) }
