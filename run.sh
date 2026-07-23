#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$script_dir/subprojects/terminal/src/libterminal.c" ]]; then
  echo "The terminal submodule is not initialized; run: git submodule update --init" >&2
  exit 1
fi

source "$script_dir/scripts/common.sh"
build_dir="${PRAGTICAL_BUILD_DIR:-$script_dir/$(get_default_build_dir)}"

cd -- "$script_dir"

if [[ -f "$build_dir/meson-private/coredata.dat" ]]; then
  configured_native_plugins="$(meson configure "$build_dir" | awk '$1 == "native_plugins" { print $2; exit }')"
  if [[ "$configured_native_plugins" == *terminal* ]]; then
    meson compile -C "$build_dir"
  else
    echo "Configuring terminal plugin in existing build directory: ${build_dir}"
    "$script_dir/build.sh" --builddir "$build_dir" --reconfigure
  fi
else
  "$script_dir/build.sh" --builddir "$build_dir"
fi

if [[ -f "$build_dir/src/pragtical.exe" ]]; then
  executable="$build_dir/src/pragtical.exe"
else
  executable="$build_dir/src/pragtical"
fi

if [[ ! -f "$executable" ]]; then
  echo "Built Pragtical executable not found: ${executable}" >&2
  exit 1
fi

export PRAGTICAL_USERDIR="${PRAGTICAL_USERDIR:-$script_dir/.run/user}"
exec "$executable" "$@"
