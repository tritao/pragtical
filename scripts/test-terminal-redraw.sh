#!/bin/sh

set -eu

: "${PRAGTICAL_BIN:?set PRAGTICAL_BIN to the rebuilt Pragtical executable}"

command -v xvfb-run >/dev/null 2>&1 || {
  echo "terminal redraw benchmark: xvfb-run is required" >&2
  exit 1
}
command -v xdotool >/dev/null 2>&1 || {
  echo "terminal redraw benchmark: xdotool is required" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "terminal redraw benchmark: python3 is required" >&2
  exit 1
}

test_dir=$(mktemp -d /tmp/pragtical-terminal-redraw.XXXXXX)
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixture="$script_dir/lua/benchmarks/terminal_redraw.lua"

cleanup() {
  status=$?
  trap - EXIT
  rm -rf "$test_dir"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

xvfb-run -a -s '-screen 0 1280x800x24 -nolisten tcp' sh -c '
  set -eu
  test_dir=$1
  fixture=$2
  app_bin=$3

  PRAGTICAL_USERDIR="$test_dir/user"
  PRAGTICAL_PERF_STATS_PATH="$test_dir/stats"
  PRAGTICAL_PERF_START_PATH="$test_dir/start"
  export PRAGTICAL_USERDIR PRAGTICAL_PERF_STATS_PATH PRAGTICAL_PERF_START_PATH
  mkdir -p "$PRAGTICAL_USERDIR"

  SDL_VIDEO_DRIVER=x11
  SDL_VIDEODRIVER=x11
  SDL_RENDER_DRIVER=software
  LIBGL_ALWAYS_SOFTWARE=1
  export SDL_VIDEO_DRIVER SDL_VIDEODRIVER SDL_RENDER_DRIVER LIBGL_ALWAYS_SOFTWARE

  "$app_bin" run -n "$fixture" >"$test_dir/pragtical.log" 2>&1 &
  app_pid=$!
  cleanup_app() {
    status=$?
    trap - EXIT HUP INT TERM
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    exit "$status"
  }
  trap cleanup_app EXIT HUP INT TERM

  window=
  previous_window=
  for _ in $(seq 1 200); do
    candidate=$(xdotool search --class "dev.pragtical.Pragtical" 2>/dev/null \
      | head -n 1 || true)
    if [ "$candidate" != "" ] && [ "$candidate" = "$previous_window" ]; then
      window=$candidate
      break
    fi
    previous_window=$candidate
    if ! kill -0 "$app_pid" 2>/dev/null; then
      echo "terminal redraw benchmark: Pragtical exited before creating a window" >&2
      tail -n 40 "$test_dir/pragtical.log" >&2 || true
      exit 1
    fi
    sleep 0.1
  done
  if [ "$window" = "" ]; then
    echo "terminal redraw benchmark: Pragtical window was not created" >&2
    tail -n 40 "$test_dir/pragtical.log" >&2 || true
    exit 1
  fi

  # The SDL window starts hidden and normally gets mapped by a desktop WM.
  # Map and focus it explicitly so the benchmark renders under bare Xvfb.
  xdotool windowmap "$window" 2>/dev/null || true
  xdotool windowraise "$window" 2>/dev/null || true
  xdotool windowfocus "$window" 2>/dev/null || true
  sleep 0.3
  xdotool key --clearmodifiers --window "$window" shift+alt+t
  sleep 0.3
  xdotool mousemove --window "$window" 600 700
  xdotool click 1
  : > "$PRAGTICAL_PERF_START_PATH"

  for _ in $(seq 1 300); do
    if [ -f "$PRAGTICAL_PERF_STATS_PATH" ]; then break; fi
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [ ! -f "$PRAGTICAL_PERF_STATS_PATH" ]; then
    echo "terminal redraw benchmark: no frame statistics were produced" >&2
    tail -n 80 "$test_dir/pragtical.log" >&2 || true
    exit 1
  fi

  frames=$(sed -n "s/^frames=//p" "$PRAGTICAL_PERF_STATS_PATH")
  fps=$(sed -n "s/^fps=//p" "$PRAGTICAL_PERF_STATS_PATH")
  case "$frames" in
    ""|*[!0-9]*)
      echo "terminal redraw benchmark: invalid frame count: $frames" >&2
      exit 1
      ;;
  esac
  if [ "$frames" -lt 1 ]; then
    echo "terminal redraw benchmark: no redraws were measured" >&2
    exit 1
  fi

  min_fps=${PRAGTICAL_PERF_MIN_FPS:-}
  if [ "$min_fps" != "" ] && ! awk -v actual="$fps" -v minimum="$min_fps" \
      "BEGIN { exit !(actual >= minimum) }"; then
    echo "terminal redraw benchmark: ${fps} FPS is below ${min_fps} FPS" >&2
    cat "$PRAGTICAL_PERF_STATS_PATH" >&2
    exit 1
  fi

  cat "$PRAGTICAL_PERF_STATS_PATH"

  app_status=0
  for _ in $(seq 1 50); do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if kill -0 "$app_pid" 2>/dev/null; then
    echo "terminal redraw benchmark: Pragtical did not exit after the run" >&2
    exit 1
  fi
  wait "$app_pid" || app_status=$?
  if [ "$app_status" -ne 0 ]; then
    echo "terminal redraw benchmark: Pragtical exited with status $app_status" >&2
    tail -n 80 "$test_dir/pragtical.log" >&2 || true
    exit "$app_status"
  fi
' xvfb-terminal-redraw "$test_dir" "$fixture" "$PRAGTICAL_BIN"
