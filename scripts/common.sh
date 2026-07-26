#!/bin/bash

set -e

# Keep the source wrap and published PPM binaries on the same reproducible
# release instead of following the moving continuous channel.
PPM_VERSION="v1.6.0"

ppm_sha256() {
  case "$1" in
    ppm.aarch64-android) echo "5b935cb12cf7422dd04ad9d09002f5b1ed0852bfa83138ab8ca420787a674ba5" ;;
    ppm.aarch64-darwin) echo "1b8ef0a0897837b323a388e5f7bb3bace4530912fc69374b7f672716f8499c84" ;;
    ppm.aarch64-linux) echo "669e85ce04d19f9034b9e96c2e1feb40142871526e798e3c93e52a0a5cb85224" ;;
    ppm.arm-android) echo "78082b3eb95da98f4238f4005acf3a7248fa178b04506b7c68edab17e7cf2f7e" ;;
    ppm.riscv64-linux) echo "1059d8c34e1ed07afe9f3ef8ab1d29996023594aa3c96568cff1fa00686ec11e" ;;
    ppm.x86-android) echo "419155f2447c46bddb6187eec91c7bdec5bbeee3483d554e870a8024454d981b" ;;
    ppm.x86_64-android) echo "2b4a4f6cf75f382075f0a8f05a467ca8bbf237c1db7d5a344097a8d470d880b2" ;;
    ppm.x86_64-darwin) echo "2b802eba03fd4f3bc8b02b83447aa0ae0d3bbe8d78285eefe8addbaed186cb06" ;;
    ppm.x86_64-linux) echo "6563f09b65694f99764574b3ec00bf3bfb3df3269e947458d2fed441dafc148f" ;;
    ppm.x86_64-windows.exe) echo "ca0eec1c5562ec0d1d3e5d62edad80126dea70793abe6e7ff771a8c6e57fadf2" ;;
    *) return 1 ;;
  esac
}

sha256_file() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl > /dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 1
  fi
}

verify_ppm_binary() {
  local file="$1"
  local expected
  expected="$(ppm_sha256 "$(basename "$file")")" || {
    echo "No PPM checksum is registered for '$(basename "$file")'."
    return 1
  }
  local actual
  actual="$(sha256_file "$file")" || {
    echo "Could not calculate the PPM checksum for '$file'."
    return 1
  }
  if [[ "$actual" != "$expected" ]]; then
    echo "PPM checksum mismatch for '$file'."
    return 1
  fi
}

addons_download() {
  local build_dir="$1"

  if [[ -d "${build_dir}/third/data/plugins" ]]; then
    echo "Warning: found previous addons installation, skipping."
    echo "  addons path: ${build_dir}/third/data/plugins"
    return 0
  fi

  mkdir -p "${build_dir}/third/data/plugins"

  # Downlaod thirdparty plugins
  curl --insecure \
    -L "https://github.com/pragtical/plugins/archive/master.zip" \
    -o "${build_dir}/plugins.zip"

  unzip "${build_dir}/plugins.zip" -d "${build_dir}"
  mv "${build_dir}/plugins-master/plugins" "${build_dir}/third/data"
  rm -rf "${build_dir}/plugins-master"
}

# Addons installation: some distributions forbid external downloads
# so make it as optional module.
addons_install() {
  local build_dir="$1"
  local data_dir="$2"

  # Disabled since pragtical can load binary files without crashing
  # Plugins
  # mkdir -p "${data_dir}/plugins"

  # for plugin_name in open_ext; do
  #   cp -r "${build_dir}/third/data/plugins/${plugin_name}.lua" \
  #     "${data_dir}/plugins/"
  # done
}

get_platform_name() {
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    echo "windows"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  elif [[ "$OSTYPE" == "linux"* || "$OSTYPE" == "freebsd"* ]]; then
    echo "linux"
  else
    echo "UNSUPPORTED-OS"
  fi
}

get_platform_arch() {
  platform=$(get_platform_name)
  arch=${CROSS_ARCH:-$(uname -m)}
  if [[ ${MSYSTEM:-} != "" ]]; then
    case "${MSYSTEM:-}" in
      MINGW64|UCRT64|CLANG64)
      arch=x86_64
      ;;
      MINGW32|CLANG32)
      arch=i686
      ;;
      CLANGARM64)
      arch=aarch64
      ;;
    esac
  fi
  echo "$arch"
}

get_default_build_dir() {
  platform="${1:-$(get_platform_name)}"
  arch="${2:-$(get_platform_arch)}"
  echo "build-$platform-$arch"
}

polyfill_glibc() {
  if [[ true ]]; then # Disable polyfill for now since giving issues with linenoise
    return
  fi

  local platform
  platform=$(get_platform_name)

  if [[ "$platform" != "linux" ]]; then
    return 0
  fi

  local arch
  arch=$(get_platform_arch)

  local target_glibc
  target_glibc=2.17

  if [ ! -e "polyfill-glibc" ]; then
    if ! wget -O "polyfill-glibc" "https://github.com/pragtical/polyfill-glibc/releases/download/binaries/polyfill-glibc.${arch}" ; then
      echo "Could not download polyfill-glibc for the arch '${arch}'."
      exit 1
    else
      chmod 0755 "polyfill-glibc"
    fi
  fi

  local rename_symbols=""
  if [[ "$arch" == "aarch64" ]]; then
    local symbols="aarch_symbols_rename.txt"
    echo "__isoc23_strtol@GLIBC_2.38 strtol" > $symbols
    echo "__isoc23_strtoll@GLIBC_2.38 strtoll" >> $symbols
    echo "__isoc23_strtoul@GLIBC_2.38 strtoul" >> $symbols
    echo "__isoc23_strtoull@GLIBC_2.38 strtoull" >> $symbols
    rename_symbols="--rename-dynamic-symbols=${symbols}"

    # because of posix_spawn_file_actions_addchdir_np we need to target newer
    target_glibc=2.29
  fi

  local binary_path="$1"
  echo "======================================================================="
  echo "Polyfill GLIBC on: ${binary_path}"
  echo "======================================================================="
  ./polyfill-glibc --target-glibc=$target_glibc $rename_symbols "$binary_path"
}

if [[ $(get_platform_name) == "UNSUPPORTED-OS" ]]; then
  echo "Error: unknown OS type: \"$OSTYPE\""
  exit 1
fi
