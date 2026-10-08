# lxs: edit remote files from Emacs through lite-xl-server

`lxs` opens files on a host that runs `lite-xl-server`
(protocol: [docs/remote-protocol.md](../docs/remote-protocol.md)) as if they
were local. A remote file is named `/lxs:HOST:/absolute/path`; HOST is an ssh
host, or a PuTTY session on Windows. TRAMP is not involved: one connection per
host carries file operations, listings, process execution and conflict-safe
saves.

* [Quick start](#quick-start)
* [Install](#install) (use-package, package.el, plain load-path)
* [Configuration examples](#configuration-examples)
* [Using it](#using-it)
* [Setting up a host](#setting-up-a-host)
* [Variables](#variables)
* [Troubleshooting](#troubleshooting)
* [What works, what does not](#what-works-what-does-not)
* [Tests](#tests)

## Quick start

1. Put `lite-xl-server` on the host (see [Setting up a host](#setting-up-a-host)).
2. In Emacs:

```elisp
(add-to-list 'load-path "/path/to/lite-xl/emacs")
(require 'lxs-setup)
```

3. `C-x C-f /lxs:devbox:/home/me/project/main.c`. `devbox` is anything `ssh -T
   devbox` (or `plink -ssh -batch -T devbox`) can reach without a prompt.

## Install

Files: `lxs.el` (protocol), `lxs-fs.el` (file name handler), `lxs-proc.el`
(processes), `lxs-setup.el` (the entry point: launcher, commands, tweaks for
other packages). Require `lxs-setup` (or use one of the forms below); it pulls
in the rest. Needs Emacs 28.1 or newer (developed on 29.3).

### use-package, local checkout

The package is not on an archive, so it needs `:ensure nil` (and an explicit
`:load-path`). Use the form your config style asks for.

Eager, simple (loads at startup, costs a few milliseconds):

```elisp
(use-package lxs-setup
  :ensure nil
  :demand t
  :load-path "~/src/lite-xl/emacs"
  :custom
  (lxs-hosts '("devbox" "build-server")))
```

Lazy (loaded the first time an `/lxs:` name or one of the commands is used):

```elisp
(use-package lxs-setup
  :ensure nil
  :load-path "~/src/lite-xl/emacs"
  :commands (lxs-find-file lxs-disconnect-all)
  :init
  ;; A /lxs: name must find its handler before the package is loaded
  ;; (session restore, recentf, command line arguments, ...).
  (autoload 'lxs-file-name-handler "lxs-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/lxs:[^:/]+:" #'lxs-file-name-handler))
  :custom
  (lxs-hosts '("devbox" "build-server")))
```

Both forms are tested in fresh Emacs processes (`test/up-eager.el`,
`test/up-lazy.el`). `:custom` works because every setting is a `defcustom`;
setting `lxs-command-function` yourself is respected (the setup file only
installs its launcher when the value is still the default).

### package.el (package-vc)

The directory is a complete package (`lxs-pkg.el`, autoload cookies). From a
checkout, Emacs 29 or newer:

```elisp
(package-vc-install-from-checkout "~/src/lite-xl/emacs" "lxs")
```

package.el generates `lxs-autoloads.el`, which registers the file name handler
and the commands at startup without loading the package; then plain
`(use-package lxs-setup :ensure nil :commands (lxs-find-file lxs-disconnect-all))`
(or just nothing) is enough. With Emacs 30 and the repository URL of your
fork:

```elisp
(use-package lxs
  :vc (:url "<url of your lite-xl fork>" :lisp-dir "emacs")
  :commands (lxs-find-file lxs-disconnect-all))
```

### Plain load-path

```elisp
(add-to-list 'load-path "/path/to/lite-xl/emacs")
(require 'lxs-setup)
```

## Configuration examples

### Hosts and server paths

`lxs-host-options` is an alist `(HOST . PLIST)`; keys: `:server` (program on
that host), `:server-args` (extra arguments, e.g. `--root` to jail file
operations, `--log FILE`), `:command` (a function of HOST returning the whole
command list, replacing everything else).

```elisp
(setq lxs-server-program "lite-xl-server"        ; default, found through PATH on the host
      lxs-host-options
      '(("devbox")                               ; nothing special
        ("build-server" :server "/opt/lxs/lite-xl-server"
                        :server-args ("--root" "/home/me"))
        ("remote-box" :server "/home/user/lxs/lite-xl-server")))
```

### Windows (PuTTY sessions, plink, Pageant)

HOST is the PuTTY session name; Pageant (or a key in the session) must log in
without a prompt, and the host key must have been accepted once
(`plink -ssh my-session exit` in a terminal). `plink` is found on `PATH`; use
`:command` to give a full path or extra options:

```elisp
(setq lxs-host-options
      `(("remote-box" :server "/home/user/lxs/lite-xl-server")
        ("old-box" :command ,(lambda (host)
                               (list "C:/Program Files/PuTTY/plink.exe" "-ssh" "-batch" "-T"
                                     "-P" "2222" host "/opt/lxs/lite-xl-server" "--stdio")))))
```

### Linux and macOS (ssh)

Everything comes from `~/.ssh/config`; a `ControlMaster` there makes
reconnects instant (the connection is one long-lived `ssh -T` anyway):

```
Host devbox
  HostName devbox.example.com
  User me
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

```elisp
(setq lxs-hosts '("devbox"))                     ; offered by M-x lxs-find-file
```

### Emacs in WSL, keys in Windows (Pageant)

The Windows `plink.exe` can be started from WSL Emacs and uses Pageant:

```elisp
(setq lxs-host-options
      `(("remote-box"
         :command ,(lambda (host)
                     (list "/mnt/c/depot/scoop/apps/putty/current/PLINK.EXE"
                           "-ssh" "-batch" "-T" host
                           "/home/user/lxs/lite-xl-server" "--stdio")))))
```

### Key bindings

```elisp
(global-set-key (kbd "C-c r f") #'lxs-find-file)        ; pick a host, then a file
(global-set-key (kbd "C-c r q") #'lxs-disconnect-all)   ; close all connections
```

With `use-package`:

```elisp
(use-package lxs-setup
  :ensure nil
  :load-path "~/src/lite-xl/emacs"
  :commands (lxs-find-file lxs-disconnect-all)
  :bind (("C-c r f" . lxs-find-file)
         ("C-c r q" . lxs-disconnect-all))
  :init
  (autoload 'lxs-file-name-handler "lxs-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/lxs:[^:/]+:" #'lxs-file-name-handler)))
```

### vertico, orderless, consult, embark, marginalia

Nothing to configure: filename completion in the minibuffer works on
`/lxs:HOST:/...` names (the listing of a directory is fetched once and reused
for `lxs-cache-ttl` seconds, so typing is not one round trip per key), and
`consult-ripgrep`, `consult-fd`, `consult-find`, `consult-grep` run on the host
when `default-directory` is a remote name. Live grep needs `rg` on the host;
without it `consult-ripgrep` falls back to `consult-grep` (and `consult-fd` to
`consult-find` when `fd` is missing). To make live preview gentler on a slow
link:

```elisp
(with-eval-after-load 'consult
  (consult-customize consult-ripgrep consult-grep consult-fd consult-find
                     :preview-key '(:debounce 0.6 any)))
```

### project.el, dired, compile

`project-current` / `project-find-file` / `project-switch-project` work on a
git checkout on the host (they run `git` there). `M-x compile`,
`shell-command` and `M-!` run on the host in `default-directory`. Dired uses
the host's `ls`; a remote switches list is fine with the usual
`dired-listing-switches` (`-alh`). Optional tweaks:

```elisp
;; do not litter the remote directories with ~ backups
(add-to-list 'backup-directory-alist (cons "\\`/lxs:" temporary-file-directory))

;; recentf keeps remote files, but the startup cleanup would connect to every
;; host to check them
(setq recentf-auto-cleanup 'never)
```

### Disabling the tool tweaks

`lxs-setup` keeps lsp-mode and flycheck from starting in remote buffers (they
cannot reach the host's tools). To change that:

```elisp
(setq lxs-disable-remote-tools nil)
```

### Everything together (a module for a use-package based config)

A module such as `as-emacs-lxs-setup.el` in the style of the existing ones
(`require`d from your setup file after the completion stack):

```elisp
;;; as-emacs-lxs-setup.el -- remote files through lite-xl-server  -*- lexical-binding: t; -*-

(defvar as-emacs-lxs-dir
  (expand-file-name "third-party/lite-xl/emacs" (getenv "DEPOT_STONE"))
  "Directory of the lxs package (lite-xl/emacs).")

(use-package lxs-setup
  :ensure nil
  :if (file-directory-p as-emacs-lxs-dir)
  :load-path as-emacs-lxs-dir
  :commands (lxs-find-file lxs-disconnect-all)
  :bind (("C-c r f" . lxs-find-file))
  :init
  (autoload 'lxs-file-name-handler "lxs-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/lxs:[^:/]+:" #'lxs-file-name-handler))
  :custom
  (lxs-hosts '("remote-box"))
  (lxs-host-options '(("remote-box"
                       :server "/home/user/lxs/lite-xl-server")))
  :config
  (setq recentf-auto-cleanup 'never)
  (add-to-list 'backup-directory-alist (cons "\\`/lxs:" temporary-file-directory)))

(provide 'as-emacs-lxs-setup)
;;; as-emacs-lxs-setup.el ends here
```

## Using it

| Do | How |
|---|---|
| Open a file | `C-x C-f /lxs:HOST:/path`, or `M-x lxs-find-file` (asks for the host; `~` is the host's home) |
| Browse | `M-x dired RET /lxs:HOST:/dir/` |
| Search | `consult-ripgrep` / `consult-fd` with a remote `default-directory`, `project-find-file`, `M-x grep` |
| Run commands | `M-x compile`, `M-!`, `shell-command`, `process-file`, `start-file-process`, `make-process` with `default-directory` on the host |
| Reconnect | automatic on next use; `M-x lxs-disconnect-all` forces it |

Saving is atomic on the host. The buffer remembers the file's etag; when the
file changed in the meantime the save fails with "File changed on the host"
instead of overwriting it, and `revert-buffer` reloads. `M-x lxs-disconnect-all`
closes every connection; running remote processes end with it.

## Setting up a host

The server is POSIX only (Linux, macOS, BSD). Build a static binary once and
copy it; it is a single file (its Lua modules are compiled in):

```
cmake -B build-server -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DLITE_SERVER_ONLY=ON -DLITE_SERVER_STATIC=ON \
      -DLITE_BUILD_TREE_SITTER=OFF -DLITE_BUNDLE_TREE_SITTER_GRAMMARS=OFF
cmake --build build-server

ssh host mkdir -p lxs
scp build-server/lite-xl-server host:lxs/
```

A `data` directory left on the host by older setups is ignored unless
`--datadir` points at it (in `:server-args`); remove both after upgrading.

Check it: `ssh -T host ~/lxs/lite-xl-server --version`. The static binary needs
no matching glibc (it was built on Ubuntu and runs on Rocky Linux 8). The
login shell on the host must print nothing for non-interactive sessions
(banners or `echo` in `.bashrc` corrupt the protocol); `ssh -T` / `plink
-batch -T` is used for that reason. The server must have the `fs_meta` and
`host_info` capabilities: `chmod`, `set-file-times`, links, same-host
`copy-file`, `delete-directory`, the `file-readable-p` family (`access(2)` on
the host, so ACLs and read-only mounts are right) and `exec-path` are server
ops, not programs run on the host, and they respect `--root`. With an older
server these operations fail with "lite-xl-server on the host is too old";
copy the new binary and its `data` directory to the host. Older builds also
lack the `src/api/process.c` argument-list fix (they crash on commands with
about twenty arguments, e.g. `grep` with many `--exclude`).

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `lxs-hosts` | nil | host names offered by `lxs-find-file` (connected hosts are always offered) |
| `lxs-server-program` | `"lite-xl-server"` | server program on the host |
| `lxs-host-options` | nil | per host `:server`, `:server-args`, `:command` |
| `lxs-command-function` | `lxs-launch-command` | function of HOST returning the command list; set it to take over completely |
| `lxs-cache-ttl` | 3 | seconds that stat/readdir/realpath results are reused; writes flush them |
| `lxs-timeout` | 30 | seconds a synchronous request may take |
| `lxs-disable-remote-tools` | t | no lsp-mode / flycheck in remote buffers |

## Troubleshooting

* **"Cannot connect to lxs host"**: run the command yourself, e.g. `ssh -T
  HOST lite-xl-server --stdio` or `plink -ssh -batch -T HOST ...`; it must wait
  silently (type nothing, Ctrl-C). Typical causes: password/host key prompts,
  `ssh-agent`/Pageant not running, server not on `PATH` (set `:server`), shell
  output in the profile. The server's stderr is in the buffer ` *lxs-stderr*`.
* **Hangs on the first access** to a host: the connection waits for the
  handshake for `lxs-timeout` seconds, then reports the error above.
* **A file does not show a change made on the host**: metadata is cached for
  `lxs-cache-ttl` seconds; `g` in dired, or set the TTL lower.
* **`consult-ripgrep` finds nothing**: `rg` must be installed on the host,
  otherwise `consult-grep` is used. consult logs the command it ran in the
  buffer ` *consult-async*`.
* **Slow directory listings** of very large directories: a 5000 entry
  directory takes about 0.3 s the first time over a slow link; later keystrokes
  are served from the cache.
* **Server crashes with `realloc(): invalid next size`**: the old
  `process.c` bug, replace the binary on the host.
* **"lite-xl-server on the host is too old (unknown op: ...)"**: the server
  predates the file ops this package uses; replace the binary and its `data`
  directory on the host.

## What works, what does not

Works: `find-file` and `save-buffer` with conflict detection, dired,
filename completion, `project.el` with git, `vc-git` commands, consult live
search, `shell-command`, `compile`, stdin to async processes
(`process-send-string`, `process-send-eof`), kill and interrupt of remote
programs, copying between local and remote.

Not yet: ptys (`M-x shell`, `term`, programs needing a tty), LSP servers on the
host, auto-revert from the server's watch events, the large-file operations of
the server (`lineindex`, `read_range`, `apply_edit`, `search`), reconnect of
running processes, `file-notify`, Windows-native Emacs (only tried from WSL;
`plink` is used when `system-type` is `windows-nt`).

Bridged processes are local pipe processes whose output is fed from the
server: `process-status`, `process-exit-status`, `delete-process`,
`signal-process`, `kill-process` and the other signal commands,
`process-send-*` and `accept-process-output` are advised for them only, and
killing the process buffer stops the remote program. Other processes, and
integer/buffer/name arguments that are not bridged processes, fall through
unchanged. The server's `exec` has no tty and refuses `bin` strings in `argv`
(`lxs--arg` converts).

## Tests

```
sh emacs/test/all-wsl.sh local      # WSL Emacs, ~/lxs-build/lite-xl-server
sh emacs/test/all-wsl.sh remote     # plink to remote-box, /home/user/lxs
sh emacs/test/run-wsl.sh remote emacs/test/lxs-fs-test.el lxs-proc-make-process
```

`lxs-test` (protocol), `lxs-fs-test` (handler, dired, processes, project),
`lxs-integration-test` (consult's own async pipeline, completion table,
project over git; needs consult in `~/.emacs.d/elpa`),
`lxs-use-package-test` (the eager and lazy use-package forms above, each in a
fresh Emacs). With plain Emacs: set `LXS_SERVER="<server command> --stdio"` and
run `emacs -Q --batch -L emacs -l emacs/test/lxs-fs-test.el -f
ert-run-tests-batch-and-exit`. `emacs/test/bench.el` prints protocol timings.

Measured (byte-compiled, WSL Emacs 29.3 to a Linux host through plink):
`file-exists-p` 0.1 ms cached; completion on a 5000 entry directory 300 ms cold,
1.6 ms warm; dired of 5000 files 180 ms; open a small file 12 ms; save 52 ms;
`process-file echo` 6 ms; a 4 MiB write 0.15-0.25 s (a big
`process-send-string` is slow in Emacs, so frames go out in 16 KiB slices).
