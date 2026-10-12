-- Persistent server sessions (`session` host option, thither-server --session):
-- reconnect to the same daemon, restart-session, two labels on one session
-- with different roots, and the handshake notices.
return function(T)
  local paths = require "plugins.thither.paths"

  local function sq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

  -- one session per run, named after a shell pid on the server so parallel
  -- runs do not meet; created lazily by the first live test
  local sname
  local function session_name()
    if not sname then
      sname = "lxc_" .. T.sh_ok("echo $$"):gsub("%s+", "")
      local server = os.getenv("LXC_SERVER")
      local datadir = os.getenv("LXC_DATADIR") or ""
      local dd = datadir ~= "" and (" --datadir " .. sq(datadir)) or ""
      T.at_exit(function()
        -- the connections are closed by now; end the daemon, then remove its
        -- runtime files and state dir (kept after any exit on purpose)
        T.sh(sq(server) .. dd .. " --session " .. sname .. " --kill >/dev/null 2>&1; "
          .. "r=${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/thither-server}; r=${r:-/tmp/thither-server-$(id -u)}; "
          .. "rm -f \"$r/" .. sname .. ".lock\" \"$r/" .. sname .. ".sock\"; "
          .. "rm -rf \"${XDG_STATE_HOME:-$HOME/.local/state}/thither-server/" .. sname .. "\"")
      end)
    end
    return sname
  end

  local function session_host(label, extra)
    extra = extra or {}
    extra.session = session_name()
    return T.add_host(label, extra)
  end

  local function conn(label)
    local vfs = require "plugins.thither.vfs"
    local c, err = vfs.conn_for(label)
    T.ok(c, "cannot connect " .. label .. ": " .. tostring(err and err.msg))
    return c
  end

  local function notices(mark)
    local n = {}
    for _, p in ipairs { "restarted", "runs thither%-server", "no session support" } do
      for _, it in ipairs(T.logs_since(mark, p)) do n[#n + 1] = it.text end
    end
    return n
  end

  local function save_and_check(h, dir, text)
    local vfs = require "plugins.thither.vfs"
    local ok, err = vfs.write_file(h, dir .. "/s.txt", text)
    T.ok(ok, "save failed: " .. tostring(err and (err.msg or err.code) or err))
    T.eq(T.sh_ok("cat " .. sq(dir .. "/s.txt")), text)
  end

  T.test("session: handshake notices (skew once per daemon, old server, pid change)", function()
    local vfs = require "plugins.thither.vfs"
    local config = require "core.config"
    local rc = config.plugins.thither
    rc.hosts.lxcfake = { session = "x" }
    local h = { label = "lxcfake" }
    local function hello(s, build) return { hello = { session = s, build_id = build } } end
    local mark = T.log_mark()
    -- an old server: the option is set, the hello has no session table (once)
    vfs.check_session(h, hello(nil))
    vfs.check_session(h, hello(nil))
    T.eq(#T.logs_since(mark, "no session support"), 1)
    -- skew: one notice per daemon pid, however often it reconnects
    mark = T.log_mark()
    local skew = { name = "x", daemon_pid = 10, version = "1.0", version_skew = "1.1 (abc)" }
    vfs.check_session(h, hello(skew, "def"))
    vfs.check_session(h, hello(skew, "def"))
    local sk = T.logs_since(mark, "runs thither%-server")
    T.eq(#sk, 1)
    T.ok(sk[1].text:find("runs thither-server 1.0 (def), installed is 1.1 (abc)", 1, true), sk[1].text)
    T.ok(sk[1].text:find("restart the session to upgrade", 1, true), sk[1].text)
    T.eq(sk[1].level, "WARN")
    T.eq(#T.logs_since(mark, "restarted"), 0, "same pid: no restart notice")
    -- another pid: the restart notice, and the skew of the new daemon once more
    mark = T.log_mark()
    vfs.check_session(h, hello({ name = "x", daemon_pid = 11, version = "1.0", version_skew = "1.1 (abc)" }))
    local re = T.logs_since(mark, "restarted")
    T.eq(#re, 1)
    T.ok(re[1].text:find("session x on lxcfake was restarted (pid 10 -> 11)", 1, true), re[1].text)
    T.eq(re[1].level, "WARN")
    T.eq(#T.logs_since(mark, "runs thither%-server"), 1)
    -- an expected restart (thither:restart-session) is reported as such
    mark = T.log_mark()
    h.session_restart_expected = true
    vfs.check_session(h, hello({ name = "x", daemon_pid = 12, version = "1.1" }))
    re = T.logs_since(mark, "restarted")
    T.eq(#re, 1)
    T.ok(re[1].text:find("session x on lxcfake restarted (pid 11 -> 12)", 1, true), re[1].text)
    T.eq(re[1].level, "INFO")
    T.eq(h.session_restart_expected, nil)
    T.eq(h.session_pid, 12)
    -- no option, no session table: silent
    rc.hosts.lxcfake = nil
    mark = T.log_mark()
    vfs.check_session({ label = "lxcfake" }, hello(nil))
    T.eq(#notices(mark), 0)
  end)

  T.test("session: connect, transport killed, reconnect to the same daemon without a notice", function()
    local h = session_host("lxcsa")
    local dir = T.tmpdir()
    local mark = T.log_mark()
    local c = conn("lxcsa")
    T.ok(c.caps.session, "session cap")
    local s = c.hello.session
    T.eq(type(s), "table")
    T.eq(s.name, sname)
    local pid = s.daemon_pid
    T.ok(pid, "daemon_pid")
    save_and_check(h, dir, "one\n")
    -- the link drops (plink / wsl.exe killed): the automatic reconnect attaches
    -- to the same daemon
    c.proc:kill()
    T.wait_for(function() return c.state ~= "ready" end, 10, "connection lost")
    T.wait_for(function() return c.state == "ready" end, 20, "automatic reconnect")
    T.eq(c.hello.session.daemon_pid, pid, "same daemon")
    T.ok(#T.logs_since(mark, "Reconnected to lxcsa", true) >= 1, "reconnect logged")
    T.eq(#notices(mark), 0, "no session notice: " .. table.concat(notices(mark), " | "))
    save_and_check(h, dir, "two\n")
  end)

  T.test("session: session-info shows the session; refused outside session mode", function()
    local commands = require "plugins.thither.commands"
    session_host("lxcsa")
    local c = conn("lxcsa")
    local res, err, done
    commands.session_info("lxcsa", function(i, e) res, err, done = i, e, true end)
    T.wait_for(function() return done end, 20, "session-info")
    T.ok(res, tostring(err))
    T.eq(res.name, sname)
    T.eq(res.daemon_pid, c.hello.session.daemon_pid)
    T.ok(res.version and res.started and res.connections >= 1)
    local items = T.core.log_items
    T.ok(items[#items].text:find("Session " .. sname .. " on lxcsa: pid " .. res.daemon_pid, 1, true),
      items[#items].text)
    -- the default test host runs without a session
    T.connect()
    done = nil
    commands.session_info(T.label, function(i, e) res, err, done = i, e, true end)
    T.wait_for(function() return done end, 20, "session-info (no session)")
    T.eq(res, nil)
    T.ok(tostring(err):find("not in session mode", 1, true), tostring(err))
  end)

  T.test("session: two labels on one session, each jailed to its own root", function()
    local vfs = require "plugins.thither.vfs"
    local d1, d2 = T.tmpdir(), T.tmpdir()
    T.sh_ok("echo one > " .. d1 .. "/f1 && echo two > " .. d2 .. "/f2")
    local h1 = session_host("lxcsb1", { server_args = { "--root", d1 } })
    local h2 = session_host("lxcsb2", { server_args = { "--root", d2 } })
    local c1, c2 = conn("lxcsb1"), conn("lxcsb2")
    local ca = conn("lxcsa")
    T.eq(c1.hello.session.daemon_pid, c2.hello.session.daemon_pid, "one daemon")
    T.eq(c1.hello.session.daemon_pid, ca.hello.session.daemon_pid, "one daemon")
    T.ok(c2.hello.session.connections >= 2, "connections " .. tostring(c2.hello.session.connections))
    T.eq(c1.hello.root, d1)
    T.eq(c2.hello.root, d2)
    T.ok(vfs.get_file_info(paths.make("lxcsb1", d1 .. "/f1")), "f1 inside the root of lxcsb1")
    T.ok(vfs.get_file_info(paths.make("lxcsb2", d2 .. "/f2")), "f2 inside the root of lxcsb2")
    local raw, err = vfs.stat_raw(h1, d2 .. "/f2", true)
    T.eq(raw, nil, "lxcsb1 must not see the root of lxcsb2")
    T.ok(err and err.code, "error code")
    raw = vfs.stat_raw(h2, d1 .. "/f1", true)
    T.eq(raw, nil, "lxcsb2 must not see the root of lxcsb1")
    save_and_check(h1, d1, "jailed\n")
    -- the unjailed label still sees both
    local ha = vfs.get_host("lxcsa")
    T.ok(vfs.stat_raw(ha, d2 .. "/f2", true), "lxcsa sees everything")
    vfs.disconnect("lxcsb1")
    vfs.disconnect("lxcsb2")
  end)

  T.test("session: restart-session asks, then a new daemon and the restarted notice", function()
    local commands = require "plugins.thither.commands"
    local h = session_host("lxcsa")
    local dir = T.tmpdir()
    local c = conn("lxcsa")
    local old = c.hello.session.daemon_pid
    -- cancelling keeps the session
    local done, ok, why
    commands.restart_session("lxcsa", function(o, w) done, ok, why = true, o, w end)
    T.wait_for(function() return T.nag_count("Restart Remote Session") > 0 end, 20, "confirmation")
    T.answer_nag("Restart Remote Session", "Cancel")
    T.wait_for(function() return done end, 5, "cancel")
    T.eq(ok, nil)
    T.eq(c.state, "ready")
    -- confirmed
    local mark = T.log_mark()
    done = nil
    commands.restart_session("lxcsa", function(o, w) done, ok, why = true, o, w end)
    T.wait_for(function() return T.nag_count("Restart Remote Session") > 0 end, 20, "confirmation")
    local n = T.core.nag_view.shown[#T.core.nag_view.shown]
    T.ok(n.message:find(sname, 1, true) and n.message:find("terminals", 1, true), n.message)
    T.answer_nag("Restart Remote Session", "Restart")
    T.wait_for(function() return done end, 20, "restart")
    T.ok(ok, tostring(why))
    T.ok(c.state ~= "ready", "disconnected after the restart")
    T.ok(#T.logs_since(mark, "is shutting down", true) == 1, "session_closing logged")
    -- no automatic reconnect: the next operation starts the new daemon
    T.sleep(1)
    T.ok(c.state ~= "ready" and c.state ~= "connecting", "no automatic reconnect: " .. c.state)
    save_and_check(h, dir, "after restart\n")
    T.eq(c.state, "ready")
    local new = c.hello.session.daemon_pid
    T.ok(new ~= old, "new daemon pid (" .. tostring(old) .. " -> " .. tostring(new) .. ")")
    local re = T.logs_since(mark, "restarted")
    T.eq(#re, 1, "one restart notice")
    T.ok(re[1].text:find(string.format("session %s on lxcsa restarted (pid %s -> %s)", sname, old, new), 1, true),
      re[1].text)
    T.eq(#T.logs_since(mark, "Connection to lxcsa lost", true), 0, "no lost-connection warning")
  end)
end
