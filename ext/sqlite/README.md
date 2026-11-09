# SQLite 3.54.1

The amalgamation of SQLite (`sqlite3.c`, `sqlite3.h`), as published: papier's history database. `papiertool build`
compiles it into `build/sqlite/libsqlite3.a` (`build_sqlite` in `tools/papiertool/build.odin` has the flags), and
`src/sqlite` links it.

- Source: https://sqlite.org/2026/sqlite-amalgamation-3540100.zip
- SHA3-256 of the archive: `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30` (as sqlite.org gives it)
- SHA-256 of `sqlite3.c`: `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52`
- SHA-256 of `sqlite3.h`: `d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c`
- License: public domain (https://sqlite.org/copyright.html)

To move to another version, replace the two files with those of its amalgamation and update this file.
