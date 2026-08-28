#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${1:-${ROOT_DIR}/dist/web}"
PORT="${2:-8000}"

[[ -f "${DIST_DIR}/index.html" ]] || {
  echo "serve-web: ${DIST_DIR}/index.html does not exist; run scripts/build-web.sh first" >&2
  exit 1
}

exec python3 -m http.server "${PORT}" --bind "${WEB_BIND:-127.0.0.1}" --directory "${DIST_DIR}"
