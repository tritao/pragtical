#!/bin/bash
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Pragtical."; exit 1
fi

source scripts/common.sh

show_help() {
  echo
  echo "Usage: $0 <OPTIONS>"
  echo
  echo "Available options:"
  echo
  echo "-b --builddir DIRNAME         Sets the name of the build directory (not path)."
  echo "                              Default: '$(get_default_build_dir)'."
  echo "   --debug                    Debug this script."
  echo "-f --forcefallback            Force to build dependencies statically."
  echo "   --sqlite BACKEND            Select SQLite backend: auto, system, bundled, or disabled."
  echo "-h --help                     Show this help and exit."
  echo "-p --prefix PREFIX            Install directory prefix. Default: '/'."
  echo "   --reconfigure              Reconfigure an existing build directory."
  echo "                              Existing options are preserved when reusing it."
  echo "-w --wipe/--clean             Delete and recreate the build directory."
  echo "-B --bundle                   Create an App bundle (macOS only)"
  echo "   --plugins LIST             Bundle comma-separated Lua plugins from the plugins repository."
  echo "   --native-plugins LIST      Build comma-separated native plugins from submodules."
  echo "-P --portable                 Create a portable binary package."
  echo "-O --pgo                      Use profile guided optimizations (pgo)."
  echo "-L --lto                      Enables Link-Time Optimization (LTO)."
  echo "-r --release                  Compile in release mode."
  echo "   --cross-platform PLATFORM  Cross compile for this platform."
  echo "                              The script will find the appropriate"
  echo "                              cross file in 'resources/cross'."
  echo "   --cross-arch ARCH          Cross compile for this architecture."
  echo "                              The script will find the appropriate"
  echo "                              cross file in 'resources/cross'."
  echo "   --cross-file CROSS_FILE    Cross compile with the given cross file."
  echo
}

main() {
  local platform="$(get_platform_name)"
  local arch="$(get_platform_arch)"
  local build_dir="$(get_default_build_dir)"
  local build_type="debugoptimized"
  local prefix=/
  local wrap_mode="--wrap-mode=default"
  local sqlite=""
  local reconfigure=false
  local wipe=false
  local bundle=""
  local portable=""
  local pgo=""
  local lto=""
  local lua_plugins=""
  local native_plugins=""
  local cross=""
  local cross_platform=""
  local cross_arch=""
  local cross_file_path=""
  local -a cross_file_args=()

  local lua_subproject_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -b|--builddir)
        if [[ $# -lt 2 || "$2" == -* ]]; then
          echo "Error: $1 requires a build directory name."
          exit 1
        fi
        build_dir="$2"
        shift 2
        ;;
      --debug)
        set -x
        shift
        ;;
      -f|--forcefallback)
        wrap_mode="--wrap-mode=forcefallback"
        shift
        ;;
      --sqlite)
        if [[ $# -lt 2 || "$2" == -* ]]; then
          echo "Error: $1 requires one of: auto, system, bundled, disabled."
          exit 1
        fi
        case "$2" in
          auto|system|bundled|disabled)
            sqlite="-Dsqlite=$2"
            ;;
          *)
            echo "Error: invalid SQLite backend: $2"
            exit 1
            ;;
        esac
        shift 2
        ;;
      -p|--prefix)
        if [[ $# -lt 2 || "$2" == -* ]]; then
          echo "Error: $1 requires an install prefix."
          exit 1
        fi
        prefix="$2"
        shift 2
        ;;
      --reconfigure)
        reconfigure=true
        shift
        ;;
      -w|--wipe|--clean)
        wipe=true
        shift
        ;;
      -B|--bundle)
        if [[ "$platform" != "macos" ]]; then
          echo "Warning: ignoring --bundle option, works only under macOS."
        else
          bundle="-Dbundle=true"
        fi
        shift
        ;;
      --plugins|--lua-plugins)
        if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
          echo "Error: $1 requires a comma-separated plugin list."
          exit 1
        fi
        lua_plugins="-Dlua_plugins=$2"
        shift 2
        ;;
      --native-plugins)
        if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
          echo "Error: $1 requires a comma-separated native plugin list."
          exit 1
        fi
        native_plugins="-Dnative_plugins=$2"
        shift 2
        ;;
      -P|--portable)
        portable="-Dportable=true"
        shift
        ;;
      -O|--pgo)
        pgo="-Db_pgo=generate"
        shift
        ;;
      -L|--lto)
        lto="-Db_lto=true"
        shift
        ;;
      --cross-arch)
        if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
          echo "Error: $1 requires an architecture."
          exit 1
        fi
        cross="true"
        cross_arch="$2"
        shift 2
        ;;
      --cross-platform)
        if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
          echo "Error: $1 requires a platform."
          exit 1
        fi
        cross="true"
        cross_platform="$2"
        shift 2
        ;;
      --cross-file)
        if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
          echo "Error: $1 requires a Meson cross file."
          exit 1
        fi
        cross="true"
        cross_file_path="$2"
        shift 2
        ;;
      -r|--release)
        build_type="release"
        shift
        ;;
      *)
        echo "Error: unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done

  if [[ $platform == "macos" && -n $bundle && -n $portable ]]; then
      echo "Warning: \"bundle\" and \"portable\" specified; excluding portable package."
      portable=""
  fi

  # if CROSS_ARCH is used, it will be picked up
  cross="${cross:-${CROSS_ARCH:-}}"
  if [[ -n "$cross" ]]; then
    if [[ -n "$cross_file_path" ]] && ([[ -z "$cross_arch" ]] || [[ -z "$cross_platform" ]]); then
      echo "Warning: --cross-platform or --cross-platform not set; guessing it from the filename."
      # remove file extensions and directories from the path
      cross_file_name="${cross_file_path##*/}"
      cross_file_name="${cross_file_name%%.*}"
      # cross_platform is the string before encountering the first hyphen
      if [[ -z "$cross_platform" ]]; then
        cross_platform="${cross_file_name%%-*}"
        echo "Warning: Guessing --cross-platform $cross_platform"
      fi
      # cross_arch is the string after encountering the first hyphen
      if [[ -z "$cross_arch" ]]; then
        cross_arch="${cross_file_name#*-}"
        echo "Warning: Guessing --cross-arch $cross_arch"
      fi
    fi
    platform="${cross_platform:-$platform}"
    arch="${cross_arch:-$arch}"
    cross_file_args=("--cross-file" "${cross_file_path:-resources/cross/$platform-$arch.ini}")
    # reload build_dir because platform and arch might change
    build_dir="$(get_default_build_dir "$platform" "$arch")"
  fi

  # arch and platform specific stuff
  if [[ "$platform" == "macos" ]]; then
    macos_version_min="10.11"
    if [[ "$arch" == "arm64" ]]; then
      macos_version_min="11.0"
    fi
    export MACOSX_DEPLOYMENT_TARGET="$macos_version_min"
    export MIN_SUPPORTED_MACOSX_DEPLOYMENT_TARGET="$macos_version_min"
    export CFLAGS="-mmacosx-version-min=$macos_version_min"
    export CXXFLAGS="-mmacosx-version-min=$macos_version_min"
    export LDFLAGS="-mmacosx-version-min=$macos_version_min"
  fi

  build_dir_configured=false
  if [[ -f "${build_dir}/meson-private/coredata.dat" ]]; then
    build_dir_configured=true
  fi

  if [[ $wipe == true ]]; then
    echo "Wiping build directory: ${build_dir}"
    rm -rf -- "${build_dir}"
    build_dir_configured=false
  fi

  # Enable ppm only for windows 32 Bits which binary download is not available
  local ppm="-Dppm=false"
  if [[ $platform == "windows" && $arch == "i686" ]]; then
    ppm="-Dppm=true"
  fi

  if [[ $build_dir_configured == false || $reconfigure == true ]]; then
    if [[ $build_dir_configured == true ]]; then
      echo "Reconfiguring build directory: ${build_dir}"
      setup_mode="--reconfigure"
    else
      setup_mode=""
    fi

    CFLAGS="${CFLAGS:-}" LDFLAGS="${LDFLAGS:-}" meson setup \
      "${build_dir}" \
      $setup_mode \
      --buildtype=$build_type \
      --prefix "$prefix" \
      $ppm \
      "${cross_file_args[@]}" \
      $wrap_mode \
      $bundle \
      $portable \
      $pgo \
      $lto \
      $lua_plugins \
      $native_plugins \
      $sqlite \
      -Doptimization=3
  else
    echo "Reusing existing build directory: ${build_dir}"
  fi

  meson compile -C "${build_dir}"

  if [[ $pgo != "" ]]; then
    echo "Generating Profiler Guided Optimizations data..."
    export SDL_VIDEO_DRIVER="dummy"
    if [[ $platform == "macos" ]]; then
      gtimeout 120s ./scripts/run-local -debug "${build_dir}" run -n scripts/lua/pgo.lua || true
    else
      timeout 120s ./scripts/run-local -debug "${build_dir}" run -n scripts/lua/pgo.lua || true
    fi
    # in case of clang handle the profile data appropriately
    if ls scripts/lua | grep default ; then
      if [[ $platform == "macos" ]]; then
        xcrun llvm-profdata merge -output="${build_dir}"/default.profdata scripts/lua/default_* "${build_dir}"/default_*
      else
        if command -v llvm-profdata-14 ; then
          llvm-profdata-14 merge -output="${build_dir}"/default.profdata scripts/lua/default_* "${build_dir}"/default_*
        else
          llvm-profdata merge -output="${build_dir}"/default.profdata scripts/lua/default_* "${build_dir}"/default_*
        fi
      fi
    fi
    meson configure -Db_pgo=use "${build_dir}"
    meson compile -C "${build_dir}"
  fi
}

main "$@"
