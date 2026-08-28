# Lua Scripts

This directory contains lua scripts for running with Pragtical.

### Tests

Run the full Lua test suite:

```sh
SDL_VIDEO_DRIVER=dummy ./scripts/run-local build test scripts/lua/tests
```

Run a single Lua test file:

```sh
SDL_VIDEO_DRIVER=dummy ./scripts/run-local build test scripts/lua/tests/tokenizer.lua
```

### Build

**pgo.lua** This script is used to generate profiler data, for more details
check the instructions included inside the file.

### Benchmarks

**benchmarks/tokenizer.lua** Benchmarks the Lua and native tokenizer paths for
an input file.

```sh
./scripts/run-local build run scripts/lua/benchmarks/tokenizer.lua /path/to/file.ext
```

The terminal redraw benchmark launches a terminal view under Xvfb, feeds it
deterministic ANSI and Unicode output, and reports redraw timing:

```sh
PRAGTICAL_BIN=build-linux-x86_64/src/pragtical ./scripts/test-terminal-redraw.sh
```

Set `PRAGTICAL_PERF_MIN_FPS` to make the benchmark fail below a chosen FPS
threshold.
