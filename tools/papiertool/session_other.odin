#+build !linux
package papiertool

// `live` and `shots` run papier in a sway nobody sees (session.odin): Linux only. On Windows, `check` runs the tests of
// the system's clipboard history (src/history).

import "core:fmt"

run_live :: proc(args: []string) -> int { fmt.eprintln("papiertool live: Linux only (a sway nobody sees)"); return 1 }
run_shots :: proc(args: []string) -> int { fmt.eprintln("papiertool shots: Linux only (a sway nobody sees)"); return 1 }
