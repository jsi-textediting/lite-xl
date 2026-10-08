#!/bin/sh
# Usage: run-wsl.sh local|remote [test-file] [ert selector]
# Runs the ERT tests inside WSL against the local build or the remote-box host.
cd "$(dirname "$0")/../.." || exit 1
case "$1" in
  remote) export THITHER_SERVER="${THITHER_SERVER:-/mnt/c/depot/scoop/apps/putty/current/PLINK.EXE -ssh -batch -T remote-box /home/user/thither/thither-server --stdio}" ;;
  *) export THITHER_SERVER="$HOME/thither-build/thither-server --datadir $PWD/thither/lua --stdio" ;;
esac
exec emacs -Q --batch -L emacs -l "${2:-emacs/test/thither-fs-test.el}" --eval "(setq ert-batch-backtrace-right-margin 150 ert-batch-print-length 8 ert-batch-print-level 4)" --eval "(ert-run-tests-batch-and-exit '${3:-t})"
