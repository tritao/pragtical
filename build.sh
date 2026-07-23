#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$script_dir/native/terminal/src/libterminal.c" ]]; then
  echo "The terminal submodule is not initialized; run: git submodule update --init" >&2
  exit 1
fi

cd -- "$script_dir"

# Keep the terminal enabled for the convenience build. A later
# --native-plugins argument can override this default.
exec bash "$script_dir/scripts/build.sh" --native-plugins terminal "$@"
