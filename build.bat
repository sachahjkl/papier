@echo off
rem Shortcut: build.bat [debug|release] is papiertool build.
rem Every other step: odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -- <command> (help lists them).
cd /d "%~dp0"
if not exist build mkdir build
odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -keep-executable -- build %*
