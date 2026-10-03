#!/bin/sh
# Build the buffer engine as a Lua module (ASAN+UBSAN by default) and run the tests.
# Usage: tests/buffer_remote/run.sh [test.lua ...]     (run from anywhere, POSIX/WSL)
#   SAN=0          build without sanitizers
#   LUA_SRC=<dir>  Lua source dir (default: build/_deps/lua-src/src from the cmake build)
#   OUT=<dir>      build dir (default: /tmp/buffer_remote_build)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LUA_SRC=${LUA_SRC:-$ROOT/build/_deps/lua-src/src}
OUT=${OUT:-/tmp/buffer_remote_build}
SAN=${SAN:-1}
mkdir -p "$OUT"
FLAGS="-g -O1 -fno-omit-frame-pointer -Wall"
if [ "$SAN" = 1 ]; then FLAGS="$FLAGS -fsanitize=address,undefined -fno-sanitize-recover=undefined"; fi
if [ ! -x "$OUT/lua" ] || [ "$SAN" != "$(cat "$OUT/.san" 2>/dev/null)" ]; then
  rm -f "$OUT"/*.o
  for f in "$LUA_SRC"/*.c; do
    case $(basename "$f") in luac.c) continue;; esac
    gcc $FLAGS -w -DLUA_USE_LINUX -c "$f" -o "$OUT/lua_$(basename "$f" .c).o"
  done
  gcc $FLAGS -o "$OUT/lua" "$OUT"/lua_*.o -lm -ldl -Wl,-E
  echo "$SAN" > "$OUT/.san"
fi
gcc $FLAGS -shared -fPIC -I"$LUA_SRC" -o "$OUT/buffer.so" "$ROOT/src/api/buffer.c"
export LUA_CPATH="$OUT/?.so"
export ASAN_OPTIONS=detect_leaks=1:abort_on_error=0
export UBSAN_OPTIONS=print_stacktrace=1
cd "$HERE"
if [ $# -eq 0 ]; then set -- test_basic.lua test_remote.lua test_fuzz.lua; fi
for t in "$@"; do echo "== $t"; "$OUT/lua" "$t"; done
echo "ALL OK"
