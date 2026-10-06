#!/bin/sh
# Usage: all-wsl.sh local|remote   (run inside WSL, repository root or anywhere)
cd "$(dirname "$0")/../.." || exit 1
for f in lxs-test lxs-fs-test lxs-integration-test lxs-use-package-test; do
  echo "=== $1 $f"
  timeout 280 sh emacs/test/run-wsl.sh "$1" "emacs/test/$f.el" 2>&1 | grep -E '^ +(FAILED|skipped)|^Ran' | cut -c1-200
done
