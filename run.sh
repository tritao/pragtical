#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$script_dir/native/terminal/src/libterminal.c" ]]; then
  echo "The terminal submodule is not initialized; run: git submodule update --init" >&2
  exit 1
fi

source "$script_dir/scripts/common.sh"
build_dir="${PRAGTICAL_BUILD_DIR:-$script_dir/$(get_default_build_dir)}"

cd -- "$script_dir"

if [[ -f "$build_dir/meson-private/coredata.dat" ]]; then
  meson setup "$build_dir" --reconfigure -Dnative_plugins=terminal
  meson compile -C "$build_dir"
else
  "$script_dir/build.sh" --builddir "$build_dir"
fi

exec "$script_dir/scripts/run-local" "$build_dir" "$@"
