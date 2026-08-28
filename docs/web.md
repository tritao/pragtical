# Web compatibility

The web target is a static, single-threaded Emscripten build. It runs the same
editor and Lua core inside a browser sandbox; it does not provide unrestricted
access to the host operating system.

## Capability boundary

| Status | Capabilities |
| --- | --- |
| Supported | Editing, Lua core, syntax highlighting, themes, and compatible Lua plugins |
| Adapted | Browser-local persistence, clipboard, opening URLs, import/export, and browser dialogs |
| Disabled | Subprocesses, terminal, native plugins, native threads/channels, shared memory, and native directory watching |
| Deferred | Networking, remote workspaces, collaboration, and remote terminal/build services |

The native-only APIs remain present where Lua compatibility requires them, but
web implementations return a descriptive error. `system.has_capability(name)`
lets plugins feature-detect an operation without comparing platform strings.
Commands that require a native file picker use the command view in the web
preview, and direct picker calls report an error.

The current Find File and Project Search plugins are also disabled on the web
target because their indexing and search workers use native thread/channel
APIs. The regular file tree and command view remain available.

## Build and serve

The repository pins Emscripten in `.emscripten-version`. Install and activate
that SDK, then run:

```sh
source /path/to/emsdk/emsdk_env.sh
./scripts/build-web.sh
./scripts/serve-web.sh
```

Open <http://127.0.0.1:8000/>. The generated `dist/web/` contains the launch
page, JavaScript loader, WASM module, and preloaded application data. The
preview uses an in-memory browser filesystem; persistence and project
import/export are intentionally separate follow-up work.

`WEB_BUILD_DIR` and `WEB_DIST_DIR` may point to custom output directories. The
build script never recursively removes either configurable directory: existing
build trees are reconfigured in place, and only the known distribution files
are replaced.

Do not open `index.html` with `file://`: browsers block the WASM/data loader
without an HTTP origin.
