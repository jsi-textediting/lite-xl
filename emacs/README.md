# thither: edit remote files from Emacs through thither-server

`thither` opens files on a host that runs `thither-server`
(protocol: [thither/docs/protocol.md](../thither/docs/protocol.md)) as if they
were local. A remote file is named `/thither:HOST:/absolute/path`; HOST is an ssh
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

1. Put `thither-server` on the host (see [Setting up a host](#setting-up-a-host)).
2. In Emacs:

```elisp
(add-to-list 'load-path "/path/to/lite-xl/emacs")
(require 'thither-setup)
```

3. `C-x C-f /thither:devbox:/home/me/project/main.c`. `devbox` is anything `ssh -T
   devbox` (or `plink -ssh -batch -T devbox`) can reach without a prompt.

## Install

Files: `thither.el` (protocol), `thither-fs.el` (file name handler), `thither-proc.el`
(processes), `thither-setup.el` (the entry point: launcher, commands, tweaks for
other packages). Require `thither-setup` (or use one of the forms below); it pulls
in the rest. Needs Emacs 28.1 or newer (developed on 29.3).

### use-package, local checkout

The package is not on an archive, so it needs `:ensure nil` (and an explicit
`:load-path`). Use the form your config style asks for.

Eager, simple (loads at startup, costs a few milliseconds):

```elisp
(use-package thither-setup
  :ensure nil
  :demand t
  :load-path "~/src/lite-xl/emacs"
  :custom
  (thither-hosts '("devbox" "build-server")))
```

Lazy (loaded the first time an `/thither:` name or one of the commands is used):

```elisp
(use-package thither-setup
  :ensure nil
  :load-path "~/src/lite-xl/emacs"
  :commands (thither-find-file thither-disconnect-all)
  :init
  ;; A /thither: name must find its handler before the package is loaded
  ;; (session restore, recentf, command line arguments, ...).
  (autoload 'thither-file-name-handler "thither-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/thither:[^:/]+:" #'thither-file-name-handler))
  :custom
  (thither-hosts '("devbox" "build-server")))
```

Both forms are tested in fresh Emacs processes (`test/up-eager.el`,
`test/up-lazy.el`). `:custom` works because every setting is a `defcustom`;
setting `thither-command-function` yourself is respected (the setup file only
installs its launcher when the value is still the default).

### package.el (package-vc)

The directory is a complete package (`thither-pkg.el`, autoload cookies). From a
checkout, Emacs 29 or newer:

```elisp
(package-vc-install-from-checkout "~/src/lite-xl/emacs" "thither")
```

package.el generates `thither-autoloads.el`, which registers the file name handler
and the commands at startup without loading the package; then plain
`(use-package thither-setup :ensure nil :commands (thither-find-file thither-disconnect-all))`
(or just nothing) is enough. With Emacs 30 and the repository URL of your
fork:

```elisp
(use-package thither
  :vc (:url "<url of your lite-xl fork>" :lisp-dir "emacs")
  :commands (thither-find-file thither-disconnect-all))
```

### Plain load-path

```elisp
(add-to-list 'load-path "/path/to/lite-xl/emacs")
(require 'thither-setup)
```

## Configuration examples

### Hosts and server paths

`thither-host-options` is an alist `(HOST . PLIST)`; keys: `:server` (program on
that host), `:server-args` (extra arguments, e.g. `--root` to jail file
operations, `--log FILE`), `:command` (a function of HOST returning the whole
command list, replacing everything else).

```elisp
(setq thither-server-program "thither-server"        ; default, found through PATH on the host
      thither-host-options
      '(("devbox")                               ; nothing special
        ("build-server" :server "/opt/thither/thither-server"
                        :server-args ("--root" "/home/me"))
        ("remote-box" :server "/home/user/thither/thither-server")))
```

### Windows (PuTTY sessions, plink, Pageant)

HOST is the PuTTY session name; Pageant (or a key in the session) must log in
without a prompt, and the host key must have been accepted once
(`plink -ssh my-session exit` in a terminal). `plink` is found on `PATH`; use
`:command` to give a full path or extra options:

```elisp
(setq thither-host-options
      `(("remote-box" :server "/home/user/thither/thither-server")
        ("old-box" :command ,(lambda (host)
                               (list "C:/Program Files/PuTTY/plink.exe" "-ssh" "-batch" "-T"
                                     "-P" "2222" host "/opt/thither/thither-server" "--stdio")))))
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
(setq thither-hosts '("devbox"))                     ; offered by M-x thither-find-file
```

### Emacs in WSL, keys in Windows (Pageant)

The Windows `plink.exe` can be started from WSL Emacs and uses Pageant:

```elisp
(setq thither-host-options
      `(("remote-box"
         :command ,(lambda (host)
                     (list "/mnt/c/depot/scoop/apps/putty/current/PLINK.EXE"
                           "-ssh" "-batch" "-T" host
                           "/home/user/thither/thither-server" "--stdio")))))
```

### Key bindings

```elisp
(global-set-key (kbd "C-c r f") #'thither-find-file)        ; pick a host, then a file
(global-set-key (kbd "C-c r q") #'thither-disconnect-all)   ; close all connections
```

With `use-package`:

```elisp
(use-package thither-setup
  :ensure nil
  :load-path "~/src/lite-xl/emacs"
  :commands (thither-find-file thither-disconnect-all)
  :bind (("C-c r f" . thither-find-file)
         ("C-c r q" . thither-disconnect-all))
  :init
  (autoload 'thither-file-name-handler "thither-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/thither:[^:/]+:" #'thither-file-name-handler)))
```

### vertico, orderless, consult, embark, marginalia

Nothing to configure: filename completion in the minibuffer works on
`/thither:HOST:/...` names (the listing of a directory is fetched once and reused
for `thither-cache-ttl` seconds, so typing is not one round trip per key), and
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
(add-to-list 'backup-directory-alist (cons "\\`/thither:" temporary-file-directory))

;; recentf keeps remote files, but the startup cleanup would connect to every
;; host to check them
(setq recentf-auto-cleanup 'never)
```

### Disabling the tool tweaks

`thither-setup` keeps lsp-mode and flycheck from starting in remote buffers (they
cannot reach the host's tools). To change that:

```elisp
(setq thither-disable-remote-tools nil)
```

### Everything together (a module for a use-package based config)

A module such as `as-emacs-thither-setup.el` in the style of the existing ones
(`require`d from your setup file after the completion stack):

```elisp
;;; as-emacs-thither-setup.el -- remote files through thither-server  -*- lexical-binding: t; -*-

(defvar as-emacs-thither-dir
  (expand-file-name "third-party/lite-xl/emacs" (getenv "DEPOT_STONE"))
  "Directory of the thither package (lite-xl/emacs).")

(use-package thither-setup
  :ensure nil
  :if (file-directory-p as-emacs-thither-dir)
  :load-path as-emacs-thither-dir
  :commands (thither-find-file thither-disconnect-all)
  :bind (("C-c r f" . thither-find-file))
  :init
  (autoload 'thither-file-name-handler "thither-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/thither:[^:/]+:" #'thither-file-name-handler))
  :custom
  (thither-hosts '("remote-box"))
  (thither-host-options '(("remote-box"
                       :server "/home/user/thither/thither-server")))
  :config
  (setq recentf-auto-cleanup 'never)
  (add-to-list 'backup-directory-alist (cons "\\`/thither:" temporary-file-directory)))

(provide 'as-emacs-thither-setup)
;;; as-emacs-thither-setup.el ends here
```

## Using it

| Do | How |
|---|---|
| Open a file | `C-x C-f /thither:HOST:/path`, or `M-x thither-find-file` (asks for the host; `~` is the host's home) |
| Browse | `M-x dired RET /thither:HOST:/dir/` |
| Search | `consult-ripgrep` / `consult-fd` with a remote `default-directory`, `project-find-file`, `M-x grep` |
| Run commands | `M-x compile`, `M-!`, `shell-command`, `process-file`, `start-file-process`, `make-process` with `default-directory` on the host |
| Reconnect | automatic on next use; `M-x thither-disconnect-all` forces it |

Saving is atomic on the host. The buffer remembers the file's etag; when the
file changed in the meantime the save fails with "File changed on the host"
instead of overwriting it, and `revert-buffer` reloads. `M-x thither-disconnect-all`
closes every connection; running remote processes end with it.

## Setting up a host

The server is POSIX only (Linux, macOS, BSD). Build a static binary once and
copy it; it is a single file (its Lua modules are compiled in):

```
cmake -S thither -B build-server -G Ninja -DCMAKE_BUILD_TYPE=Release -DTHITHER_STATIC=ON
cmake --build build-server

ssh host mkdir -p thither
scp build-server/thither-server host:thither/
```

`--datadir DIR` in `:server-args` makes the server load its Lua modules from
DIR instead (for developing the server).

Check it: `ssh -T host ~/thither/thither-server --version`. The static binary needs
no matching glibc (it was built on Ubuntu and runs on Rocky Linux 8). The
login shell on the host must print nothing for non-interactive sessions
(banners or `echo` in `.bashrc` corrupt the protocol); `ssh -T` / `plink
-batch -T` is used for that reason. The server must have the `fs_meta` and
`host_info` capabilities: `chmod`, `set-file-times`, links, same-host
`copy-file`, `delete-directory`, the `file-readable-p` family (`access(2)` on
the host, so ACLs and read-only mounts are right) and `exec-path` are server
ops, not programs run on the host, and they respect `--root`. With an older
server these operations fail with "thither-server on the host is too old";
copy the new binary and its `data` directory to the host. Older builds also
lack the `src/api/process.c` argument-list fix (they crash on commands with
about twenty arguments, e.g. `grep` with many `--exclude`).

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `thither-hosts` | nil | host names offered by `thither-find-file` (connected hosts are always offered) |
| `thither-server-program` | `"thither-server"` | server program on the host |
| `thither-host-options` | nil | per host `:server`, `:server-args`, `:command` |
| `thither-command-function` | `thither-launch-command` | function of HOST returning the command list; set it to take over completely |
| `thither-cache-ttl` | 3 | seconds that stat/readdir/realpath results are reused; writes flush them |
| `thither-timeout` | 30 | seconds a synchronous request may take |
| `thither-disable-remote-tools` | t | no lsp-mode / flycheck in remote buffers |

## Troubleshooting

* **"Cannot connect to thither host"**: run the command yourself, e.g. `ssh -T
  HOST thither-server --stdio` or `plink -ssh -batch -T HOST ...`; it must wait
  silently (type nothing, Ctrl-C). Typical causes: password/host key prompts,
  `ssh-agent`/Pageant not running, server not on `PATH` (set `:server`), shell
  output in the profile. The server's stderr is in the buffer ` *thither-stderr*`.
* **Hangs on the first access** to a host: the connection waits for the
  handshake for `thither-timeout` seconds, then reports the error above.
* **A file does not show a change made on the host**: metadata is cached for
  `thither-cache-ttl` seconds; `g` in dired, or set the TTL lower.
* **`consult-ripgrep` finds nothing**: `rg` must be installed on the host,
  otherwise `consult-grep` is used. consult logs the command it ran in the
  buffer ` *consult-async*`.
* **Slow directory listings** of very large directories: a 5000 entry
  directory takes about 0.3 s the first time over a slow link; later keystrokes
  are served from the cache.
* **Server crashes with `realloc(): invalid next size`**: the old
  `process.c` bug, replace the binary on the host.
* **"thither-server on the host is too old (unknown op: ...)"**: the server
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
(`thither--arg` converts).

## Tests

```
sh emacs/test/all-wsl.sh local      # WSL Emacs, ~/thither-build/thither-server
sh emacs/test/all-wsl.sh remote     # plink to remote-box, /home/user/thither
sh emacs/test/run-wsl.sh remote emacs/test/thither-fs-test.el thither-proc-make-process
```

`thither-test` (protocol), `thither-fs-test` (handler, dired, processes, project),
`thither-integration-test` (consult's own async pipeline, completion table,
project over git; needs consult in `~/.emacs.d/elpa`),
`thither-use-package-test` (the eager and lazy use-package forms above, each in a
fresh Emacs). With plain Emacs: set `THITHER_SERVER="<server command> --stdio"` and
run `emacs -Q --batch -L emacs -l emacs/test/thither-fs-test.el -f
ert-run-tests-batch-and-exit`. `emacs/test/bench.el` prints protocol timings.

Measured (byte-compiled, WSL Emacs 29.3 to a Linux host through plink):
`file-exists-p` 0.1 ms cached; completion on a 5000 entry directory 300 ms cold,
1.6 ms warm; dired of 5000 files 180 ms; open a small file 12 ms; save 52 ms;
`process-file echo` 6 ms; a 4 MiB write 0.15-0.25 s (a big
`process-send-string` is slow in Emacs, so frames go out in 16 KiB slices).
