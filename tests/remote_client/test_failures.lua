-- Failure injection with the real transport (plink / ssh / wsl): connect
-- failures must end in a clear message, never in a hang; killing the transport
-- in the middle of a fetch / save must not damage the server file.
-- Connect-failure tests need a real host (LXC_HOST) and the default launcher.
return function(T)
  local paths = require "core.remote.paths"

  local function capture_errors(fn)
    local core = T.core
    local errors = {}
    local orig = core.error
    core.error = function(fmt, ...)
      local ok, s = pcall(string.format, fmt, ...)
      errors[#errors + 1] = ok and s or tostring(fmt)
    end
    local ok, err = pcall(fn)
    core.error = orig
    if not ok then error(err, 0) end
    return errors
  end

  --- Runs remote.open_project against a bad target; returns seconds, first error text.
  local function failing_open(location, timeout)
    local commands = require "core.remote.commands"
    local done, why
    local t0 = system.get_time()
    local errors = capture_errors(function()
      commands.open_project(location, function(ok, w) done = true; why = w end)
      T.wait_for(function() return done end, timeout or 40, "open_project to give up")
    end)
    return system.get_time() - t0, errors[1] or "", why
  end

  T.test("failure: plink errors surface as clear messages (no hang)", function()
    if not T.host then io.stdout:write("      (skipped: needs a real host)\n") return end
    local fqdn = T.sh_ok("hostname -f"):gsub("%s+$", "")
    local cases = {
      { "wrong user (auth fails in batch mode)", "nosuchuser@" .. fqdn .. ":/tmp", "interactive prompts" },
      { "unknown host name", "user@no-such-host.invalid:/tmp", "Host does not exist" },
      { "connection refused", "user@127.0.0.1:/tmp", "refused" },
    }
    -- an address the session has no cached host key for
    local ip = T.sh_ok("hostname -I | cut -d' ' -f1"):gsub("%s+$", "")
    if ip:find("^%d+%.%d+%.%d+%.%d+$") then
      cases[#cases + 1] = { "host key not cached (IP address)", "user@" .. ip .. ":/tmp", "host key" }
    end
    for _, c in ipairs(cases) do
      local dt, msg = failing_open(c[2], 45)
      io.stdout:write(string.format("      %-40s %.1f s -> %s\n", c[1], dt, (msg:gsub("%s+", " ")):sub(1, 230)))
      T.ok(msg:find("cannot connect"), "core.error shown: " .. msg)
      T.ok(msg:lower():find(c[3]:lower(), 1, true), "message mentions '" .. c[3] .. "': " .. msg)
      T.ok(dt < 40, "gave up in time")
    end
  end)

  T.test("failure: host key mismatch (-hostkey) is reported", function()
    if not T.host then io.stdout:write("      (skipped: needs a real host)\n") return end
    local config = require "core.config"
    local rc = config.plugins.remote
    local saved = rc.ssh_command
    rc.ssh_command = { "plink", "-ssh", "-batch", "-T", "-hostkey", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }
    local ok, err = pcall(function()
      local dt, msg = failing_open("user@" .. T.sh_ok("hostname -f"):gsub("%s+$", "") .. ":/tmp", 40)
      io.stdout:write(string.format("      wrong -hostkey: %.1f s -> %s\n", dt, (msg:gsub("%s+", " ")):sub(1, 200)))
      T.ok(msg:find("Host key not in manually configured list"), msg)
    end)
    rc.ssh_command = saved
    T.configure_remote()
    if not ok then error(err, 0) end
  end)

  --- Kills the transport process right after the client sent the n-th request with op.
  local function kill_on_send(conn, op, n, before)
    local orig = conn.send
    local count = 0
    conn.send = function(self, msg)
      if before and msg.op == op then
        count = count + 1
        if count == n then
          conn.send = orig
          conn.proc:kill()
          system.sleep(0.5)       -- the real plink behind a launcher shim dies a moment later
          return orig(self, msg)
        end
      end
      local r = orig(self, msg)
      if not before and msg.op == op then
        count = count + 1
        if count == n then
          conn.send = orig
          conn:flush()
          conn.proc:kill()
        end
      end
      return r
    end
    return function() conn.send = orig end
  end

  T.test("failure: transport killed in the middle of a small-file upload keeps the old file", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("printf 'ORIGINAL\\n' > " .. dir .. "/target.txt")
    local conn = h.conn
    local f = assert(io.open(paths.join(m, "target.txt"), "wb"))
    f:write(string.rep("0123456789abcdef", 1024 * 1024 * 3))       -- 48 MiB: many chunks
    local restore = kill_on_send(conn, "write_chunk", 3)
    local ok, err = f:close()
    restore()
    io.stdout:write("      close() after the kill: " .. tostring(ok) .. " " .. tostring(err) .. "\n")
    T.ok(not ok, "close must report the failure")
    T.wait_for(function() return conn.state == "ready" end, 30, "auto reconnect")
    T.sleep(0.5)
    T.eq(T.sh_ok("cat " .. dir .. "/target.txt"), "ORIGINAL\n")
    local left = T.sh_ok("ls -A " .. dir):gsub("%s+$", "")
    io.stdout:write("      directory after the failed upload: [" .. left .. "]\n")
    T.eq(left, "target.txt", "no temp file left behind")
    -- and the retry works
    local f2 = assert(io.open(paths.join(m, "target.txt"), "wb"))
    f2:write("second try\n")
    T.ok(f2:close())
    T.eq(T.sh_ok("cat " .. dir .. "/target.txt"), "second try\n")
  end)

  for _, before in ipairs { false, true } do
  T.test("failure: transport killed " .. (before and "just before" or "just after") .. " a large document save request", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    -- 40 MiB file of 64 byte lines (large_file_threshold_mb is 10)
    T.sh_ok("cd " .. dir .. " && F=$(head -c 63 /dev/zero | tr '\\0' x) && yes \"$F\" | head -c 41943040 > big.txt && cp big.txt orig.txt && md5sum big.txt | cut -d' ' -f1 > orig.md5")
    local md5 = T.sh_ok("cat " .. dir .. "/orig.md5"):gsub("%s+", "")
    local Doc = require "core.doc"
    local doc = Doc("big.txt", paths.join(m, "big.txt"))
    T.ok(doc.remote and doc.remote.large, "large doc")
    T.wait_for(function() return doc.lines[1] ~= "\xe2\x80\xa6\n" end, 20, "first chunk")
    doc:insert(1, 1, "EDITED\n")
    local conn = h.conn
    local restore = kill_on_send(conn, "apply_edit", 1, before)
    local saved, err = pcall(function() doc:save() end)
    restore()
    io.stdout:write("      save with the kill: " .. tostring(saved) .. " " .. tostring(err):sub(1, 150) .. " dirty=" .. tostring(doc:is_dirty()) .. "\n")
    T.wait_for(function() return conn.state == "ready" end, 30, "auto reconnect")
    -- the server of the dead connection may still be finishing the request it
    -- had already read: wait until only the new connection's server is left
    local deadline = system.get_time() + 30
    while system.get_time() < deadline do
      local n = tonumber((T.sh_ok("pgrep -u $(id -u) -f '[l]ite-xl-server --stdio' | wc -l"):gsub("%s+", ""))) or 0
      if n <= 1 then break end
      T.sleep(0.2)
    end
    T.sleep(0.3)
    local got = T.sh_ok("md5sum " .. dir .. "/big.txt | cut -d' ' -f1"):gsub("%s+", "")
    local expect_new = T.sh_ok("cd " .. dir .. " && (printf 'EDITED\\n'; cat orig.txt) | md5sum | cut -d' ' -f1"):gsub("%s+", "")
    local state = got == md5 and "old file" or (got == expect_new and "new file" or "CORRUPT")
    io.stdout:write("      server file after the interrupted save: " .. state .. "; doc dirty=" .. tostring(doc:is_dirty()) .. " stale=" .. tostring(doc.remote.stale) .. "\n")
    T.ok(state ~= "CORRUPT", "file is either the old or the new version, never partial")
    T.eq(T.sh_ok("ls -A " .. dir .. " | grep -v -E '^(big.txt|orig.txt|orig.md5)$' | wc -l"):gsub("%s+", ""), "0", "no temp files left")
    if state == "old file" then
      T.ok(doc:is_dirty(), "edits are kept when the save did not happen")
      local okr, errr = pcall(function() doc:save() end)           -- retry after the reconnect
      if not okr then
        local st = h.conn:call("stat", { path = dir .. "/big.txt" })
        error(tostring(errr) .. " [doc etag " .. tostring(doc.remote.etag) .. ", server etag " .. tostring(st and st.etag) .. ", stale " .. tostring(doc.remote.stale) .. "]", 0)
      end
      T.wait_for(function() return not doc:is_dirty() end, 30, "retry save")
      local got2 = T.sh_ok("md5sum " .. dir .. "/big.txt | cut -d' ' -f1"):gsub("%s+", "")
      T.eq(got2, expect_new, "retry saved the edit")
    end
    require("core.remote.docs").release(doc)
  end)
  end

  T.test("failure: a frozen transport (suspended plink) is detected by the heartbeat", function()
    if not T.host then io.stdout:write("      (skipped: needs a real host)\n") return end
    local h = T.connect()
    local config = require "core.config"
    local rc = config.plugins.remote
    local conn = h.conn
    rc.ping_interval, rc.ping_timeout = 0.5, 2
    local pid = conn.proc:pid()
    local function ps(script)
      local p = process.start({ "powershell.exe", "-NoProfile", "-Command", script }, { stdin = process.REDIRECT_DISCARD, stderr = process.REDIRECT_STDOUT })
      T.wait_for(function() return not p:running() end, 30, "powershell")
      return p:read_stdout(4096) or ""
    end
    local def = "Add-Type -Name N -Namespace W -MemberDefinition '[DllImport(\"ntdll.dll\")] public static extern int NtSuspendProcess(IntPtr h);'; $id=" .. pid .. "; $c=Get-CimInstance Win32_Process -Filter \"ParentProcessId=$id AND Name='plink.exe'\"; if ($c) { $id=$c.ProcessId }; $p=[Diagnostics.Process]::GetProcessById($id); "
    io.stdout:write("      ps: " .. ps(def .. "[W.N]::NtSuspendProcess($p.Handle)") .. "\n")
    local t0 = system.get_time()
    T.wait_for(function() return conn.state ~= "ready" end, 30, "heartbeat timeout")
    io.stdout:write(string.format("      suspended plink detected after %.1f s: %s\n", system.get_time() - t0, tostring(conn.reason)))
    T.ok(tostring(conn.reason):find("no response"), tostring(conn.reason))
    rc.ping_interval, rc.ping_timeout = 2, 20
    T.wait_for(function() return conn.state == "ready" end, 30, "auto reconnect")
  end)

  T.test("failure: remote:disconnect and remote:reconnect commands", function()
    if not T.real then io.stdout:write("      (skipped outside -Real mode)\n") return end
    local command = require "core.command"
    local h = T.connect()
    command.perform("remote:disconnect")
    T.wait_for(function() return h.conn.state == "closed" end, 10, "disconnected")
    command.perform("remote:reconnect")
    T.wait_for(function() return h.conn.state == "ready" end, 20, "reconnected")
    T.eq(system.get_file_info(paths.make(T.label, "/tmp")).type, "dir")
  end)
end
