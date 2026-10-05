#!/bin/bash
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Lite XL."; exit 1
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
  echo "-h --help                     Show this help and exit."
  echo "-m --mode MODE                Build type (plain,debug,debugoptimized,release,minsize)."
  echo "                              Default: release."
  echo "-p --prefix PREFIX            Install directory prefix. Default: '/'."
  echo "-B --bundle                   Create an App bundle (macOS only)"
  echo "-P --portable                 Create a portable binary package."
  echo "-r --reconfigure              Tries to reuse the CMake build directory, if possible."
  echo "                              Default: Deletes the build directory and recreates it."
  echo "-L --lto                      Enables Link-Time Optimization (LTO)."
  echo "   --server                   Also build lite-xl-server (POSIX only)."
  echo "   --toolchain-file FILE      Cross compile with the given CMake toolchain file."
  echo
}

main() {
  local platform="$(get_platform_name)"
  local build_dir
  local prefix=/
  local build_type="release"
  local cmake_build_type
  local bundle="OFF"
  local portable="OFF"
  local lto="OFF"
  local server="OFF"
  local toolchain
  local should_reconfigure
  local destdir="lite-xl"

  for i in "$@"; do
    case $i in
      -h|--help)
        show_help
        exit 0
        ;;
      -b|--builddir)
        build_dir="$2"
        shift
        shift
        ;;
      -m|--mode)
        build_type="$2"
        shift
        shift
        ;;
      -r|--reconfigure)
        should_reconfigure=true
        shift
        ;;
      --debug)
        set -x
        shift
        ;;
      -p|--prefix)
        prefix="$2"
        shift
        shift
        ;;
      -B|--bundle)
        if [[ "$platform" != "darwin" ]]; then
          echo "Warning: ignoring --bundle option, works only under macOS."
        else
          bundle="ON"
          destdir="Lite XL.app"
        fi
        shift
        ;;
      -P|--portable)
        portable="ON"
        shift
        ;;
      -L|--lto)
        lto="ON"
        shift
        ;;
      --server)
        server="ON"
        shift
        ;;
      --toolchain-file)
        toolchain="-DCMAKE_TOOLCHAIN_FILE=$2"
        shift
        shift
        ;;
      *)
        # unknown option
        ;;
    esac
  done

  if [[ -n $1 ]]; then
    show_help
    exit 1
  fi

  if [[ $platform == "darwin" && $bundle == "ON" && $portable == "ON" ]]; then
    echo "Warning: \"bundle\" and \"portable\" specified; excluding portable package."
    portable="OFF"
  fi

  [[ -z "$build_dir" ]] && build_dir="$(get_default_build_dir)"

  case "$build_type" in
    "debug") cmake_build_type="Debug";;
    "debugoptimized") cmake_build_type="RelWithDebInfo";;
    "minsize") cmake_build_type="MinSizeRel";;
    "plain") cmake_build_type="";;
    *) cmake_build_type="Release";;
  esac

  if [[ "$platform" == "darwin" ]]; then
    macos_version_min="10.11"
    if [[ "$(get_platform_arch)" == "arm64" ]]; then
      macos_version_min="11.0"
    fi
    export MACOSX_DEPLOYMENT_TARGET="$macos_version_min"
  fi

  if [[ $should_reconfigure != true ]] && [[ -d "${build_dir}" ]]; then
    rm -rf "${build_dir}"
  fi

  cmake -S . -B "${build_dir}" -G Ninja \
    -DCMAKE_BUILD_TYPE="$cmake_build_type" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="$lto" \
    -DLITE_BUNDLE="$bundle" \
    -DLITE_PORTABLE="$portable" \
    -DLITE_BUILD_SERVER="$server" \
    $toolchain

  cmake --build "${build_dir}"

  # the packaging scripts expect the install tree inside the build directory
  DESTDIR="$(pwd -P)/${build_dir}/${destdir}" cmake --install "${build_dir}"
}

main "$@"
