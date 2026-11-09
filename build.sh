#!/usr/bin/env bash
# Shortcut: ./build.sh [debug|release] is papiertool build.
# Every other step: odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -- <command> (help lists them).
cd "$(dirname "$0")" && mkdir -p build && exec odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -keep-executable -- build "$@"
