#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd -- "$script_dir/../.." && pwd)"
build_dir="${1:?usage: $0 <build-directory> [tests-directory-or-file] }"
test_root="${2:-scripts/lua/tests}"
test_timeout="${PRAGTICAL_TEST_TIMEOUT:-120s}"

cd -- "$root_dir"

if ! command -v timeout >/dev/null 2>&1; then
  echo "The GNU timeout command is required to run CI tests." >&2
  exit 1
fi

if [[ ! -d "$test_root" && ! -f "$test_root" ]]; then
  echo "Test directory or file was not found: $test_root" >&2
  exit 1
fi
if [[ -f "$test_root" && "$test_root" != *.lua ]]; then
  echo "Test file is not a Lua file: $test_root" >&2
  exit 1
fi

run_args=()
test_count=0

while IFS= read -r -d '' test_file; do
  test_count=$((test_count + 1))
  echo "=== START TEST $test_file ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ==="

  set +e
  SDL_VIDEO_DRIVER=dummy timeout --kill-after=30s "$test_timeout" \
    ./scripts/run-local "${run_args[@]}" "$build_dir" test "$test_file"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
      echo "=== TIMEOUT TEST $test_file after $test_timeout ===" >&2
    else
      echo "=== FAIL TEST $test_file (exit $status) ===" >&2
    fi
    if command -v tasklist.exe >/dev/null 2>&1; then
      echo "=== PROCESS SNAPSHOT ===" >&2
      tasklist.exe //FI "IMAGENAME eq pragtical.exe" //FO LIST >&2 || true
    fi
    exit "$status"
  fi

  echo "=== PASS TEST $test_file ==="
  run_args=(-keep)
done < <(
  if [[ -f "$test_root" ]]; then
    printf '%s\0' "$test_root"
  else
    find "$test_root" -type f -name '*.lua' -print0 | sort -z
  fi
)

if [[ "$test_count" -eq 0 ]]; then
  echo "No Lua tests found under: $test_root" >&2
  exit 1
fi

echo "Completed $test_count Lua test files."
