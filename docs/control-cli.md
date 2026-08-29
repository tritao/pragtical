# Control CLI

Pragtical installs `pragtical-ctl` beside the editor. It is the same
multicall executable as `pragtical`, but enters a headless Lua control path
before SDL, the renderer, plugins, or the editor are initialized.

The portable spelling is:

```sh
pragtical --ctl status
```

`pragtical-ctl` and `pragtical --ctl` accept the same commands and options.

## Commands

```sh
pragtical-ctl list
pragtical-ctl status
pragtical-ctl focus
pragtical-ctl open README.md src/main.c
pragtical-ctl documents
pragtical-ctl save
pragtical-ctl project add /work/project
pragtical-ctl project change /work/project
pragtical-ctl call control.ping '{}'
```

Use `--instance ID` to select a specific running editor, or `--project PATH`
to select an instance whose project contains a path. Without either option,
the oldest discovered instance is selected when more than one is running.

`--timeout` accepts seconds by default and an explicit `ms` or `s` suffix, for
example `--timeout 750ms` or `--timeout 10s`. The default is five seconds.

## JSON output

Pass `--output json` for one JSON value per command. Successful output is the
control method result; `open` wraps its per-path results in `opened`, while
`save` returns saved documents in `documents`.

Failures use this stable shape:

```json
{"error":{"code":"not_found","message":"...","retryable":false}}
```

Exit codes are stable: `2` means usage, `3` discovery or selection failure,
`4` connection or timeout, `5` a remote control error, `6` protocol failure,
and `7` an internal CLI failure.

`call` is intended for diagnostics and protocol development. Stable commands
should be preferred for scripts because they are independent of individual
RPC parameter details.
