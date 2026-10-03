# Remote editing: the Lite XL client

The editor edits files that live on another machine through `lite-xl-server`
(protocol: [remote-protocol.md](remote-protocol.md)). A remote project looks
like a normal project: tree view, find file, project search, syntax
highlighting and every plugin that works through the file APIs keep working.
Multi-GB files open instantly and are edited without being downloaded.

Contents: [Quick start](#quick-start) | [Windows: PuTTY](#windows-putty-plink-and-pageant) |
[POSIX: OpenSSH](#posix-openssh) | [WSL test transport](#the-wsl-transport) |
[Commands](#commands) | [Options](#options) | [How it works](#how-it-works) |
[Remote large files](#remote-large-files) | [Tests](#tests) | [Limitations](#limitations)

## Quick start

1. Install `lite-xl-server` on the remote machine (Linux/macOS, see
   "Running and building" in the protocol document) and make sure
   `lite-xl-server --version` works in a non-interactive ssh session
   (otherwise set `server_path`, see [Options](#options)).
2. Make passwordless login work (key in Pageant / ssh-agent, or a key file).
3. In the editor run **remote:open-project** and enter `host:/path`, for
   example `devbox:/home/me/project` (`host:~/code` also works). The editor
   connects, remembers the host (recent hosts are suggested next time) and
   restarts with the remote directory as project, like `core:open-project`.

Remote files appear below a synthetic mount root: `\\lxl-remote\<host>\...`
on Windows, `/.lxl-remote/<host>/...` elsewhere. That is the path you see in
the title bar, in `core.open_doc` and in plugin code; `core.remote.parse(path)`
gives `(host, absolute path on the server)`.

## Windows: PuTTY, plink and Pageant

The default transport is `plink -ssh -batch -T <target> lite-xl-server --stdio`.

* Put `plink.exe` on `PATH` (or set `ssh_command = { "C:\\Program Files\\PuTTY\\plink.exe", "-ssh", "-batch", "-T" }`).
* `-batch` forbids prompts, so authentication must be non-interactive: load
  your key into **Pageant**, or set `identity = "C:\\keys\\id.ppk"`.
* **Pre-accept the host key once**: run `plink -ssh user@host exit` in a
  terminal and answer `y`. With `-batch` an unknown host key makes the
  connection fail (the error text from plink is shown in the log). You can also
  put `-hostkey <fingerprint>` into `ssh_command`.
* The host can be `user@host`, a plain host name (add `user`/`port` options), or
  the name of a **PuTTY saved session** (host, port, user and key come from the
  session): `remote:open-project my-session:/srv/app`.
* Check the binary-clean pipe once with
  `plink -ssh -batch -T user@host lite-xl-server --version`; nothing but the
  version must be printed (a login script that prints text breaks the protocol).

```lua
-- user init.lua
local config = require "core.config"
config.plugins.remote.identity = "C:\\keys\\id.ppk"
config.plugins.remote.hosts = {
  ["dev-box"] = { port = 2222, user = "me", server_path = "/opt/lxs/lite-xl-server" },
}
```

### Verified with real plink

The complete client test suite (see [Tests](#tests)) and the real editor pass
against a Rocky Linux 8 host (glibc 2.28) over PuTTY plink 0.85 and Pageant, and
the binary pipe was checked byte for byte:

* plink `-batch -ssh -T` is binary clean: random data (8 MiB in one write and
  in 1 MiB writes), all 256 byte values, CR/LF/NUL/Ctrl-Z/Ctrl-D/ESC runs and
  1-byte writes come back identical through `cat`; no CRLF translation, no
  banner on stdout, nothing on stderr. Typical latencies on a LAN host: connect
  (spawn plink, ssh handshake, server hello) 0.35 s, stat round trip 2 ms,
  20 KB document open 7 ms / save 5 ms.
* Closing stdin (or killing plink) makes the server exit within a second; no
  server process is left behind.
* All plink failures are written to **stderr** and show up in the editor log
  as `remote: cannot connect to <host>: server did not start (exit 1) (<plink text>)`
  within a fraction of a second (2 s for a refused connection), never as a hang:

| situation | message from plink |
|---|---|
| host key not cached | `The host key is not cached for this server ... Connection abandoned. FATAL ERROR: Cannot confirm a host key in batch mode` |
| wrong user, no usable key in Pageant, wrong or unreadable `identity` | `FATAL ERROR: Cannot answer interactive prompts in batch mode` (plink asks for a password) |
| unknown host name | `Unable to open connection: Host does not exist` |
| connection refused | `FATAL ERROR: Network error: Connection refused` |
| wrong `-hostkey` | `FATAL ERROR: Host key not in manually configured list` |

* A killed or suspended plink is detected by the heartbeat (about
  `ping_timeout` seconds) and reconnected; a kill in the middle of a chunk fetch,
  of a multi-chunk upload or of a large file save leaves the server file either
  old or new (never partial) and no temporary files; unsaved edits stay in the
  editor. If the save request reached the server the document is marked stale
  after the reconnect (offer to reload) because the file already changed.

Recommended settings for a host with a PuTTY saved session:

```lua
config.plugins.remote.hosts["remote-box"] = {
  server_path = "/home/user/lxs/lite-xl-server",
  server_args = { "--datadir", "/home/user/lxs/data" },
}
```

#### Old-glibc hosts: static server

The server has no dependencies besides libc. For hosts with an older glibc
(or without a compiler) build it statically once, for example in WSL or any
recent Linux machine, and copy it with its data directory:

```
cmake -S . -B build-static -G Ninja -DLITE_SERVER_ONLY=ON -DLITE_SERVER_STATIC=ON \
      -DLITE_BUILD_TREE_SITTER=OFF -DLITE_BUNDLE_TREE_SITTER_GRAMMARS=OFF
cmake --build build-static && strip -o lite-xl-server build-static/lite-xl-server
plink -batch -ssh host 'mkdir -p lxs/data/core'
pscp -batch -q lite-xl-server host:lxs/lite-xl-server
pscp -batch -q -r data/server host:lxs/data/                 # server Lua modules and plugins
pscp -batch -q -r data/core/remote host:lxs/data/core/       # protocol modules shared with the client
```

Then set `server_path` and `server_args = { "--datadir", ... }` as above.
Check with `plink -batch -ssh -T host lxs/lite-xl-server --version`.

## POSIX: OpenSSH

The default is `ssh -T -o ServerAliveInterval=15 -o BatchMode=yes <target> lite-xl-server --stdio`.
Use `~/.ssh/config`, ssh-agent and `ssh-keyscan`/a first interactive login for
the host key. `identity` adds `-i`, `port` adds `-p`.

## The WSL transport

For testing on Windows without an sshd: host `wsl:` (or `wsl:<distro>`) starts
`wsl.exe [-d distro] -e <server> --stdio`. `local:` starts the server
executable directly (server on the same machine).

```lua
config.plugins.remote.hosts = {
  wsl = { server_path = "/home/me/lxs-verify/lite-xl-server",
          server_args = { "--datadir", "/mnt/c/src/lite-xl/data" } },
}
```
`remote:open-project wsl:/home/me/project`.

## Commands

| command | |
|---|---|
| `remote:open-project` | connect to `host:/path` and open it as the project |
| `remote:disconnect` | close the connection of a host (asks if there are several) |
| `remote:reconnect` | reconnect now (also done automatically with backoff) |

The status bar shows `host connected | connecting... | disconnected (reconnecting)`;
clicking it when disconnected reconnects. Recent hosts are kept in
`USERDIR/remote_hosts.lua`.

## Options

`config.plugins.remote.<name>`; every option can also be set per host label
in `config.plugins.remote.hosts["<label>"]`. The label is the host spec made
path safe (`wsl:` is `wsl`, `wsl:Ubuntu` is `wsl-Ubuntu`).

| option | default | meaning |
|---|---|---|
| `ssh_command` | plink (Windows) / ssh (POSIX) argv, see above | argv prefix; target and remote command are appended |
| `identity`, `port`, `user` | none | `-i`, `-P`/`-p`, `user@` |
| `server_path` | `lite-xl-server` | server executable on the remote side |
| `server_args` | `{}` | extra server arguments (`--root`, `--datadir`, ...) |
| `wsl_command`, `wsl_server_path` | `wsl.exe`, `server_path` | wsl transport |
| `hello_timeout` / `request_timeout` | 30 / 30 s | handshake / blocking calls |
| `ping_interval` / `ping_timeout` | 15 / 45 s | heartbeat; silence after a ping kills the connection |
| `auto_reconnect`, `reconnect_delays` | true, `{1,2,5,10,20}` | automatic reconnect |
| `chunk_size` | 262144 | chunk size of remote large files |
| `cache_budget_mb` | 256 | resident bytes per remote large file (LRU) |
| `read_size` | 1048576 | bytes per read for small files |
| `stat_ttl`, `stat_ttl_nowatch` | 60, 2 s | stat/readdir cache life with and without a server watch |
| `watch` | true | use server watches (otherwise polling) |
| `rewrite_output` | true | map remote paths in `exec` output back to mount paths |
| `exec_window` | 1048576 | flow-control window of exec output |

`large_file_threshold_mb` (core option, default 10) decides which remote files
open as large files.

## How it works

`core/start.lua` loads `core.remote` right after `core.process`. It wraps
`system.get_file_info/list_dir/absolute_path/mkdir/rmdir/chdir/get_fs_type`,
`io.open/io.lines/io.type`, `os.remove/os.rename`, `loadfile/dofile`,
`process.start`, `buffer.open` and the `core.dirwatch` methods with a
one-byte path prefix test; everything outside the mount root goes straight to
the original function (the originals are in `core.remote.original`; the cost of
the check is measured in the tests, a few hundred nanoseconds per call).

* **Connections** (`client.lua`): one child process per host, framed msgpack,
  non-blocking and polled by a ticker thread. Blocking calls (the shimmed
  `io.open` and friends, which are synchronous by contract) yield-poll inside
  core threads and busy-poll with a timeout elsewhere. A heartbeat detects dead
  links; reconnect re-establishes watches, clears the caches, triggers a full
  rescan of watched directories and revalidates open documents by etag.
* **VFS** (`vfs.lua`, `cache.lua`): stat and readdir caches (a `readdir`
  seeds the stat cache of all entries, so a directory scan is one round trip),
  invalidated by server watch events. `io.open` read buffers blocks lazily;
  write buffers and uploads on `close` as one atomic `write` with the known etag
  (`close` returns `nil, "...conflict"` when the file changed). `r+b` returns `nil`,
  so `Doc:save` falls back to `wb`.
* **Processes**: `process.start` with a mount path as `cwd` or argument runs
  the program on the server (`exec`) and returns the usual process object
  (streams, `wait`, `terminate`, `kill`, ...). Mount paths in arguments are
  translated, and absolute remote paths in the output are mapped back to mount
  paths line by line, so `rgsearch`, `fd-files` and similar plugins work
  unchanged (they need `rg`/`fd` on the server).
* **Watching**: one recursive server watch on the project root feeds
  `core.dirwatch` (`autoreload`, tree view). `overflow` events and reconnects
  cause a rescan; without a usable watch the dirwatch polls with `stat`.
* **Small remote files** are ordinary documents loaded through the shimmed
  `io.open`. Saving checks the etag; on a conflict a nag offers
  *Overwrite / Reload / Save As*. External changes reload a clean document or
  nag for a modified one (`autoreload` does not know remote paths, the client
  does this itself).
* Always local: `USERDIR`, `DATADIR`, `EXEDIR`, tree-sitter parsers, `use_package`.
* `treeview:open-in-system` refuses remote files.

## Remote large files

A remote file of at least `large_file_threshold_mb` is opened with
`buffer.open_remote` from the server's line index (`lineindex`): the open
costs one round trip plus the first chunk (about 250 ms for 1 GiB including the
first-time index on the server, 25 ms when cached) and no file data is
downloaded. The document is flagged `large_file` (plain text, no highlighter,
no wrapping, no autocomplete) like local large files.

* **Fetch pump** (`docs.lua`): a core thread drains `buffer:missing()` and
  requests chunks with `read_range` (up to 6 in flight), supplies or cancels
  everything it drained, prefetches two chunks in the scroll direction, cancels
  work that is far from what is wanted now and retries failed fetches with
  backoff. Unloaded lines show a placeholder (`…`) until their chunk arrives.
  Highlighter caches compare line text, so placeholders never stick.
* **Editing**: edits need the chunk of the cursor to be resident (it is,
  because it is on screen); otherwise they are refused with a message. Removed
  text for the undo stack is fetched synchronously when needed, so undo never
  records placeholders. Memory stays inside `cache_budget_mb`.
* **Saving**: `buffer:edit_script()` becomes `apply_edit`; only the inserted
  bytes are sent (inserts over 8 MiB go through `blob_put`). The server builds
  the new file by copying kept ranges, then the buffer is rebased onto the
  returned chunk table. Saving runs in a thread, edits are refused while it runs.
  The time is dominated by the server copying the file (about 7 s for 1 GiB on
  the WSL test disk).
* **Changed on the server**: a watch event, a stale chunk read or a reconnect
  revalidation marks the document stale: edits are blocked and a nag offers
  *Reload*. A save conflict keeps the edits. *Overwrite* is only possible when
  the new file has the same chunk structure (for example after a `touch`),
  because the edit script refers to offsets of the old content; otherwise
  reload.
* **Search**: `core.doc.search.find` (find, replace) is routed to the server
  `search` op (literal, case-insensitive, regex; forward, reverse, wrap) for
  documents without unsaved changes (save first otherwise). Lua patterns are
  not supported. *Replace All* and `trim-whitespace` are disabled for remote
  large documents, `go-to-line` does not list lines.
* *Save As* of a remote large document to another remote path copies the file
  on the server (`cp --reflink=auto`) and applies the edit to the copy.

## Tests

`tests/remote_client/` runs the real client modules inside the real editor
binary against the real server in WSL. Build the editor and the server first
(`cmake --build build --config Release`; the server recipe is in
remote-protocol.md), then:

```
powershell -File tests\remote_client\run.ps1                 # headless, all tests
powershell -File tests\remote_client\run.ps1 -Filter large   # tests whose name contains "large"
powershell -File tests\remote_client\run.ps1 -BigMB 2048     # bigger large file
powershell -File tests\remote_client\run.ps1 -Real           # inside the real editor window
# a real host through the default plink launcher (no WSL), see below
powershell -File tests\remote_client\run.ps1 -Host my-session -Server /home/me/lxs/lite-xl-server `
    -ServerData /home/me/lxs/data [-NoRg] [-Real]
```

With `-Host` the shell helper of the tests (`T.sh`, temp dirs, the big file)
runs on the host through `plink -batch -ssh -T`, the editor connects with the
default `ssh_command`, and the WSL-only tests are skipped. The host needs
python3, cp, cmp, dd, truncate, md5sum and about 3 GB in `/tmp` (test data is
`/tmp/lxc-test-*` and `/tmp/lxc-big-<MB>`; the latter is kept between runs,
delete it when done). `-NoRg` skips the tests that need `rg` on the host
(reported as `skipped: no rg on host`). `test_failures.lua` injects failures
(killed or suspended plink, bad host, user or host key); its connect cases
need a real host.

What `run.ps1` does: it makes a junction `%TEMP%\lxc-stage\share\lite-xl` to
`data/` (the editor finds its data below `LITE_PREFIX`), sets
`LITE_USERDIR` to `tests\remote_client` (a scratch copy with `-Real`),
`LITE_XL_RUNTIME=lxc_runtime` (a Lua module in that directory that replaces
`core` as entry point and runs the tests; headless it loads the real core
modules without opening a window, with `-Real` it runs `core.init()`/`core.run()`
and the tests inside a core thread), and `LXC_SERVER` / `LXC_DATADIR` (the
server inside WSL, default `~/lxs-verify/lite-xl-server`). Equivalent by hand:

```
set LITE_PREFIX=%TEMP%\lxc-stage
set LITE_USERDIR=C:\src\lite-xl\tests\remote_client
set LITE_XL_RUNTIME=lxc_runtime
set LXC_SERVER=/home/me/lxs-verify/lite-xl-server
set LXC_DATADIR=/mnt/c/src/lite-xl/data
set LXC_TESTS=C:\src\lite-xl\tests\remote_client
build\src\Release\lite-xl.exe
```

The large file tests create `/tmp/lxc-big-<MB>` inside WSL (1 GiB of 64-byte
lines with sentinel lines, about 2.5 s; kept between runs) and verify the
server file against a model built independently with `python3` and compared
with `cmp`. They need about 3 GB free in WSL `/tmp`, `rg`, `cp`, `cmp`, `python3`.

## Limitations

* The server is POSIX only; Windows is client only.
* `r+b` and read/write modes of `io.open` are not available on remote files.
* The first access of a host from a synchronous API blocks the UI until the
  connection is up (at most `hello_timeout`), later failures are throttled to
  one reconnect attempt per 5 s. Opening a remote project restarts the editor
  (like local projects) and reconnects lazily.
* `projectsearch` reads every file through the network (files over
  `file_size_limit` are skipped); prefer `rgsearch`, which runs `rg` on the
  server. Output path rewriting is line based and heuristic (paths end at
  `:<digit>` or the end of the line); a line without newline for 100 ms or 4 KiB
  is passed through unchanged.
* Remote large files: no syntax highlighting, no Lua-pattern search, no
  replace-all, search needs a saved document, edits are refused where the chunk
  is not loaded, a single line must fit in the cache budget. A line that spans
  two chunks needs two round trips to show.
* Large saves block further edits of that document and take as long as the
  server needs to copy the file; the UI stays responsive.
* Running `exec` streams do not survive a reconnect (they end as killed).
* `autoreload` ignores remote paths; the client reloads by itself. Symlinked
  directories are followed (stat follows links).
* The `wsl.exe` relay is not byte-for-byte guaranteed by Microsoft; it passed
  all binary tests here.
* plink resolved through a launcher shim (for example scoop's `shims\plink.exe`)
  runs the real plink as a child process: terminating the shim ends the child
  a few milliseconds later, so a "kill" can still deliver data written just
  before it. Nothing in the protocol depends on this.
