# Web compatibility

The web target is a static, single-threaded Emscripten build. It runs the same
editor and Lua core inside a browser sandbox; it does not provide unrestricted
access to the host operating system.

## Capability boundary

| Status | Capabilities |
| --- | --- |
| Supported | Editing, Lua core, syntax highlighting, themes, and compatible Lua plugins |
| Adapted | Browser-local persistence, clipboard, opening URLs, import/export, and browser dialogs |
| Disabled | Subprocesses, terminal, native plugins, shared memory, and native directory watching |
| Deferred | Networking, remote workspaces, collaboration, and remote terminal/build services |

The native-only APIs remain present where Lua compatibility requires them, but
web implementations return a descriptive error. `system.has_capability(name)`
lets plugins feature-detect an operation without comparing platform strings.
Commands that require a native file picker use the command view in the web
preview, and direct picker calls report an error.

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

Do not open `index.html` with `file://`: browsers block the WASM/data loader
without an HTTP origin.
