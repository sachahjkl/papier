# papier

A clipboard manager for Linux, written in [Odin](https://odin-lang.org) with [gui_toolkit](https://github.com/sachahjkl/gui_toolkit).

## Features

- **Cross-type history**: captures plain text, HTML fragments, images, and file lists.
- **Live monitoring**: follows clipboard changes and records new entries.
- **Configurable**: limits, deduplication, persistence, and which types to capture.
- **Fast UI**: native immediate-mode interface, keyboard navigation, search, and image preview.

## Build

Linux, with the pinned Odin from `nix develop`:

```sh
nix develop
odin run tools/papiertool -collection:gt=ext/gui_toolkit/src -out:build/papiertool -- build
./build/papier
```

`./build.sh` is the shortcut for `papiertool build`.

The `ext/gui_toolkit` submodule must be present:

```sh
git submodule update --init --recursive
```

## Configuration

Settings are stored in the user's config directory under `papier/`. The application exposes capture and history limits in its interface.

## License

MIT. See [LICENSE](LICENSE).
