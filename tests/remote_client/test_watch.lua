-- Server watch events through core.dirwatch, cache invalidation, polling
-- fallback, heartbeat, reconnect, disconnect.
return function(T)
  local paths = require "plugins.thither.paths"

  local function collect(w, changed)
    w:check(function(p) changed[#changed + 1] = p end)
  end

  T.test("watch: dirwatch reports server side changes and the cache follows", function()
    local h = T.connect()
    local dirwatch = require "core.dirwatch"
    local dir, m = T.tmpdir()
    local w = dirwatch.new()
    w:watch(m)
    T.watch_ready(h)
    T.eq(#system.list_dir(m), 0)         -- cached for 60 s while a watch is active
    T.sh_ok("touch " .. dir .. "/new1")
    local changed = {}
    T.wait_for(function() collect(w, changed) return #changed > 0 end, 10, "change callback")
    T.eq(changed[1], m)
    T.eq(#system.list_dir(m), 1, "listing refreshed by the event, not by the TTL")
    T.eq(system.get_file_info(paths.join(m, "new1")).size, 0)
    -- modification of a file inside: the dir is reported again
    changed = {}
    T.sh_ok("echo data > " .. dir .. "/new1")
    T.wait_for(function() collect(w, changed) return #changed > 0 end, 10, "modification callback")
    T.eq(system.get_file_info(paths.join(m, "new1")).size, 5)
    w:watch(m, false)
  end)

  T.test("watch: file watches fire only when the file itself changed", function()
    local h = T.connect()
    local dirwatch = require "core.dirwatch"
    local dir, m = T.tmpdir()
    T.sh_ok("echo 1 > " .. dir .. "/watched && echo 1 > " .. dir .. "/other")
    local w = dirwatch.new()
    local f = paths.join(m, "watched")
    w:watch(f)
    T.watch_ready(h)
    local changed = {}
    T.sh_ok("sleep 0.05; echo changed > " .. dir .. "/other")
    T.sleep(0.4)
    collect(w, changed)
    T.eq(#changed, 0, "a sibling changed")
    T.sh_ok("sleep 0.05; echo changed > " .. dir .. "/watched")
    T.wait_for(function() collect(w, changed) return #changed > 0 end, 10, "file callback")
    T.eq(changed[1], f)
  end)

  T.test("watch: recursive project watch reports nested directories", function()
    local h = T.connect()
    local core = require "core"
    local Project = require "core.project"
    local dirwatch = require "core.dirwatch"
    local dir, m = T.tmpdir()
    T.sh_ok("mkdir -p " .. dir .. "/a/b/c")
    local saved = core.projects
    core.projects = { Project(m) }
    local w = dirwatch.new()
    w:watch(paths.join(m, "a/b/c"))
    T.wait_for(function() return h.watches[dir] end, 10, "server watch")
    local root_watch = h.watches[dir]
    T.ok(root_watch and root_watch.recursive, "one recursive watch on the project root")
    local changed = {}
    T.sh_ok("touch " .. dir .. "/a/b/c/deep")
    T.wait_for(function() collect(w, changed) return #changed > 0 end, 10, "deep callback")
    T.eq(changed[1], paths.join(m, "a/b/c"))
    core.projects = saved
  end)

  T.test("watch: overflow rescans every watched path", function()
    local h = T.connect()
    local dirwatch = require "core.dirwatch"
    local dir, m = T.tmpdir()
    local w = dirwatch.new()
    w:watch(m)
    T.watch_ready(h)
    T.eq(#system.list_dir(m), 0)
    T.sh_ok("touch " .. dir .. "/x")
    local changed = {}
    -- the server says events may have been lost
    h.conn.handlers.overflow[1](h.conn, { ev = "overflow" })
    T.wait_for(function() collect(w, changed) return #changed > 0 end, 10, "overflow callback")
    T.eq(#system.list_dir(m), 1)
  end)

  T.test("watch: polling fallback when the server cannot watch", function()
    local h = T.connect()
    local dirwatch = require "core.dirwatch"
    local dir, m = T.tmpdir()
    local w = dirwatch.new()
    w:watch(m)
    T.watch_ready(h)
    h.watch_ok = false          -- pretend: no usable watch (inotify limit etc.)
    h.watch_truncated = true
    local changed = {}
    T.sh_ok("sleep 0.05; touch " .. dir .. "/polled")
    T.wait_for(function() collect(w, changed) return #changed > 0 end, 10, "poll callback")
    T.eq(changed[1], m)
    h.watch_ok, h.watch_truncated = true, nil
  end)

  T.test("conn: heartbeat detects a frozen server, reconnect restores everything", function()
    local h = T.connect()
    local config = require "core.config"
    local rc = config.plugins.thither
    local dirwatch = require "core.dirwatch"
    local dir, m = T.tmpdir()
    local conn = h.conn
    rc.ping_interval, rc.ping_timeout = 0.5, 2
    local w = dirwatch.new()
    w:watch(m)
    T.watch_ready(h)
    local pid = conn.hello.pid
    local proc = process.start({ "sleep", "60" }, { cwd = m })       -- an exec stream that must die with the link
    T.ok(proc:running())
    T.sh_ok("kill -STOP " .. pid)
    local t0 = system.get_time()
    T.wait_for(function() return conn.state ~= "ready" end, 20, "heartbeat timeout")
    io.stdout:write(string.format("      frozen server detected after %.1f s: %s\n", system.get_time() - t0, tostring(conn.reason)))
    T.ok(tostring(conn.reason):find("no response"), tostring(conn.reason))
    T.sh_ok("kill -CONT " .. pid .. " ; kill " .. pid)
    T.wait_for(function() return not proc:running() end, 5, "exec stream ends with the connection")
    -- requests fail with a clear error while down
    -- automatic reconnect brings the host back
    T.wait_for(function() return conn.state == "ready" end, 30, "auto reconnect")
    rc.ping_interval, rc.ping_timeout = 2, 20
    T.eq(system.get_file_info(m).type, "dir")
    -- watches were re-established and the dirwatch sees a full rescan
    T.wait_for(function() return h.watch_ok end, 10, "re-watch")
    local changed = {}
    T.wait_for(function() collect(w, changed) return #changed > 0 end, 10, "rescan after reconnect")
    changed = {}
    T.sh_ok("touch " .. dir .. "/after")
    T.wait_for(function() collect(w, changed) return #changed > 0 end, 10, "event after reconnect")
    T.eq(#system.list_dir(m), 1)
  end)

  T.test("conn: reads fail fast while disconnected and work again after reconnect", function()
    local h = T.connect()
    local vfs = require "plugins.thither.vfs"
    local dir, m = T.tmpdir()
    T.sh_ok("echo hi > " .. dir .. "/f")
    local conn = h.conn
    conn.no_reconnect = true
    conn:close("test")
    T.eq(conn.state, "closed")
    h.last_try = system.get_time()           -- the throttle: no reconnect attempt within 5 s
    local t0 = system.get_time()
    local info, err = system.get_file_info(paths.join(m, "f"))
    T.eq(info, nil)
    T.ok(err:find("unavailable") or err:find("disconnected"), err)
    local fp, ferr = io.open(paths.join(m, "f"), "rb")
    T.eq(fp, nil)
    T.ok(system.get_time() - t0 < 1, "failed fast")
    -- explicit reconnect (what remote:reconnect does)
    h.last_try = nil
    local c2 = vfs.ensure_conn(h)
    T.ok(c2 and c2.state == "ready")
    T.eq(io.open(paths.join(m, "f"), "rb"):read("a"), "hi\n")
  end)

  T.test("conn: protocol version mismatch is reported", function()
    local Conn = require "plugins.thither.client"
    local old = Conn.PROTO
    Conn.PROTO = 2
    local c = Conn.new(T.spec, T.label)
    local saved = Conn.all[T.label]
    T.ok(c:start())
    local ok, why = c:wait_ready(20)
    Conn.PROTO = old
    T.ok(not ok)
    T.ok(tostring(why):find("refused") or tostring(why):find("version"), tostring(why))
    T.eq(c.state, "failed")
    Conn.all[T.label] = saved
  end)

  T.test("conn: close is clean (server exits on stdin EOF)", function()
    local Conn = require "plugins.thither.client"
    local saved = Conn.all[T.label]
    local c = Conn.new(T.spec, T.label)
    T.ok(c:start())
    T.ok(c:wait_ready(20))
    local proc = c.proc
    c:close("bye")
    T.eq(c.state, "closed")
    T.ok(not proc:running(), "transport process ended")
    Conn.all[T.label] = saved
  end)
end
