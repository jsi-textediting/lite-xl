#!/bin/sh
# Usage: t.sh local|remote test-file test-name... ; compact per-test results from WSL (90 s each)
where=$1; file=$2; shift; shift
for t in "$@"; do
  echo "== $t"
  wsl -d Ubuntu -- bash -lc "cd /mnt/c/depot/stone/third-party/lite-xl && timeout 90 sh emacs/test/run-wsl.sh $where $file $t 2>&1 | sed -n '/^Test.*condition:/,/FAILED/p;/^ *passed/p;/^ *skipped/p;/protocol error/p' | cut -c1-400 | head -18" 2>&1 | tr -d '\0'
done
