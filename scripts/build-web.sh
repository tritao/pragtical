#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/.emscripten-version"
EMSCRIPTEN_VERSION="${EMSCRIPTEN_VERSION:-$(tr -d '[:space:]' < "${VERSION_FILE}")}"
BUILD_DIR="${WEB_BUILD_DIR:-${ROOT_DIR}/build-web}"
DIST_DIR="${WEB_DIST_DIR:-${ROOT_DIR}/dist/web}"
STAGING_DIR="${ROOT_DIR}/.build-web-data"

die() {
  echo "build-web: $*" >&2
  exit 1
}

if [[ ! -f "${VERSION_FILE}" ]]; then
  die "missing ${VERSION_FILE}"
fi

if [[ -n "${EMCC:-}" ]]; then
  emcc_path="${EMCC}"
elif [[ -n "${EMSDK:-}" && -x "${EMSDK}/upstream/emscripten/emcc" ]]; then
  emcc_path="${EMSDK}/upstream/emscripten/emcc"
else
  emcc_path="$(command -v emcc || true)"
fi

[[ -n "${emcc_path}" && -x "${emcc_path}" ]] || die \
  "emcc was not found; install and activate Emscripten ${EMSCRIPTEN_VERSION} (see docs/web.md)"

# An SDK can be selected by EMSDK without its wrappers being sourced yet.
# Put the compiler directory first so Meson finds em++, emar, emcmake, and the
# other tools belonging to the same SDK.
export PATH="$(dirname -- "${emcc_path}"):${PATH}"

actual_version="$(${emcc_path} --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
[[ "${actual_version}" == "${EMSCRIPTEN_VERSION}" ]] || die \
  "Emscripten ${actual_version:-unknown} is active; expected ${EMSCRIPTEN_VERSION}"

command -v meson >/dev/null 2>&1 || die "Meson is required"
command -v ninja >/dev/null 2>&1 || die "Ninja is required"

cd "${ROOT_DIR}"

canonical_path() {
  local path
  path="$(realpath -m -- "$1")" || die "could not resolve path: $1"
  printf '%s\n' "${path}"
}

assert_safe_cleanup_path() {
  local path="$1"
  local label="$2"

  [[ "${path}" != "/" && "${path}" != "${ROOT_DIR}" ]] || die \
    "refusing to recursively remove ${label}=${path}"
  case "${path}" in
    "${ROOT_DIR}/.git"|"${ROOT_DIR}/.git/"*)
      die "refusing to recursively remove ${label} inside .git"
      ;;
  esac
}

prepare_build_dir() {
  local path="$1"

  assert_safe_cleanup_path "${path}" "WEB_BUILD_DIR"
  if [[ -e "${path}" && ! -d "${path}" ]]; then
    die "refusing WEB_BUILD_DIR=${path}; it is not a directory"
  fi
  mkdir -p -- "${path}"
}

prepare_dist_dir() {
  local path="$1"

  assert_safe_cleanup_path "${path}" "WEB_DIST_DIR"
  if [[ -e "${path}" && ! -d "${path}" ]]; then
    die "refusing WEB_DIST_DIR=${path}; it is not a directory"
  fi
  mkdir -p -- "${path}"
  # Only remove files this script owns. A configurable output directory may
  # contain unrelated user files, so never recursively delete it.
  rm -f -- "${path}/index.html" "${path}/pragtical.js" \
    "${path}/pragtical.wasm" "${path}/pragtical.data"
}

reset_staging_dir() {
  local marker="${STAGING_DIR}.pragtical-web-generated"

  assert_safe_cleanup_path "${STAGING_DIR}" "web staging directory"
  if [[ -e "${STAGING_DIR}" && ! -d "${STAGING_DIR}" ]]; then
    die "refusing web staging directory=${STAGING_DIR}; it is not a directory"
  fi
  if [[ -e "${marker}" && ! -f "${marker}" ]]; then
    die "refusing web staging directory=${STAGING_DIR}; its ownership marker is not a file"
  fi
  if [[ -e "${STAGING_DIR}" ]]; then
    [[ -f "${marker}" ]] || die \
      "refusing to remove web staging directory=${STAGING_DIR}; missing ${marker}"
    rm -rf -- "${STAGING_DIR}"
  fi
  mkdir -p -- "${STAGING_DIR}"
  : > "${marker}"
}

BUILD_DIR="$(canonical_path "${BUILD_DIR}")"
DIST_DIR="$(canonical_path "${DIST_DIR}")"
STAGING_DIR="$(canonical_path "${STAGING_DIR}")"

assert_safe_cleanup_path "${BUILD_DIR}" "WEB_BUILD_DIR"
assert_safe_cleanup_path "${DIST_DIR}" "WEB_DIST_DIR"
assert_safe_cleanup_path "${STAGING_DIR}" "web staging directory"

if [[ "${BUILD_DIR}" == "${DIST_DIR}" \
    || "${BUILD_DIR}" == "${DIST_DIR}"/* \
    || "${DIST_DIR}" == "${BUILD_DIR}"/* ]]; then
  die "WEB_BUILD_DIR and WEB_DIST_DIR must not overlap"
fi
if [[ "${BUILD_DIR}" == "${STAGING_DIR}" \
    || "${BUILD_DIR}" == "${STAGING_DIR}"/* \
    || "${STAGING_DIR}" == "${BUILD_DIR}"/* ]]; then
  die "WEB_BUILD_DIR and web staging directory must not overlap"
fi
if [[ "${DIST_DIR}" == "${STAGING_DIR}" \
    || "${DIST_DIR}" == "${STAGING_DIR}"/* \
    || "${STAGING_DIR}" == "${DIST_DIR}"/* ]]; then
  die "WEB_DIST_DIR and web staging directory must not overlap"
fi

prepare_build_dir "${BUILD_DIR}"
prepare_dist_dir "${DIST_DIR}"
reset_staging_dir
cp -a "${ROOT_DIR}/data/." "${STAGING_DIR}/"
: > "${BUILD_DIR}/.pragtical-web-data.stamp"

meson_setup=(meson setup)
if [[ -f "${BUILD_DIR}/meson-private/coredata.dat" ]]; then
  meson_setup+=(--reconfigure)
fi
"${meson_setup[@]}" "${BUILD_DIR}" \
  --cross-file resources/cross/unknown-wasm32.ini \
  --wrap-mode=forcefallback \
  --buildtype=release \
  --prefix=/ \
  -Dportable=true \
  -Djit=false \
  -Dnative_plugins=[] \
  -Dsqlite=disabled \
  -Dnet=false \
  -Dppm=false \
  -Drepl_history=false \
  -Ddirmonitor_backends=dummy \
  -Drenderer_backend=surface

cp "${BUILD_DIR}/start.lua" "${STAGING_DIR}/core/start.lua"
if [[ -d "${ROOT_DIR}/subprojects/widget" ]]; then
  mkdir -p "${STAGING_DIR}/widget"
  cp -a "${ROOT_DIR}/subprojects/widget/." "${STAGING_DIR}/widget/"
  rm -rf -- "${STAGING_DIR}/widget/.git"
  rm -f -- "${STAGING_DIR}/widget/.meson-subproject-wrap-hash.txt" \
    "${STAGING_DIR}/widget/meson.build" "${STAGING_DIR}/widget/meson_options.txt"
fi

meson compile -C "${BUILD_DIR}"

mkdir -p "${DIST_DIR}"
cp resources/shell.html "${DIST_DIR}/index.html"

copy_artifact() {
  local name="$1"
  local source
  source="$(find "${BUILD_DIR}" -maxdepth 4 -type f -name "${name}" -print -quit)"
  [[ -n "${source}" ]] || die "Meson did not produce ${name}"
  cp "${source}" "${DIST_DIR}/${name}"
}

copy_artifact pragtical.js
copy_artifact pragtical.wasm
copy_artifact pragtical.data

echo "Web distribution written to ${DIST_DIR}"
ls -lh "${DIST_DIR}"
