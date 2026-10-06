#!/bin/sh
# Usage: run-wsl.sh local|remote [test-file] [ert selector]
# Runs the ERT tests inside WSL against the local build or the remote-box host.
cd "$(dirname "$0")/../.." || exit 1
case "$1" in
  remote) export LXS_SERVER="${LXS_SERVER:-/mnt/c/depot/scoop/apps/putty/current/PLINK.EXE -ssh -batch -T remote-box /home/user/lxs/lite-xl-server --stdio}" ;;
  *) export LXS_SERVER="$HOME/lxs-build/lite-xl-server --datadir $PWD/data --stdio" ;;
esac
exec emacs -Q --batch -L emacs -l "${2:-emacs/test/lxs-fs-test.el}" --eval "(setq ert-batch-backtrace-right-margin 150 ert-batch-print-length 8 ert-batch-print-level 4)" --eval "(ert-run-tests-batch-and-exit '${3:-t})"
