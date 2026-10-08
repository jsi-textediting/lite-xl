-- process.start on remote paths runs on the server through exec.
return function(T)
  local paths = require "plugins.thither.paths"

  local function read_all(p, timeout)
    local out, err = {}, {}
    local deadline = system.get_time() + (timeout or 20)
    while p:running() do
      local d = p:read_stdout(65536)
      if d and d ~= "" then out[#out + 1] = d end
      local e = p:read_stderr(65536)
      if e and e ~= "" then err[#err + 1] = e end
      if system.get_time() > deadline then error("process timeout") end
      T.sleep(0.003)
    end
    for _ = 1, 3 do
      local d = p:read_stdout(65536)
      if d and d ~= "" then out[#out + 1] = d end
      local e = p:read_stderr(65536)
      if e and e ~= "" then err[#err + 1] = e end
    end
    return table.concat(out), table.concat(err), p:returncode()
  end

  T.test("process: ls on the server, output paths mapped back to mount paths", function()
    T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("cd " .. dir .. " && mkdir src && echo a > src/a.lua && echo b > src/b.lua")
    local p = process.start({ "ls", "-1", paths.join(m, "src") })
    local out, err, code = read_all(p)
    T.eq(code, 0)
    T.eq(out, "a.lua\nb.lua\n")
    -- the path itself printed by the tool is rewritten to the mount form
    p = process.start({ "find", paths.join(m, "src"), "-type", "f" })
    out = read_all(p)
    local lines = {}
    for l in out:gmatch("[^\n]+") do lines[#lines + 1] = l end
    table.sort(lines)
    T.eq(#lines, 2)
    T.eq(lines[1]:sub(1, #paths.join(m, "src")), paths.join(m, "src"))
    T.ok(paths.is_remote(lines[1]), lines[1])
    T.eq(system.get_file_info(lines[1]).type, "file")
  end)

  T.test_rg("process: cwd on the server, rg search, exit code, stderr", function()
    T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("cd " .. dir .. " && mkdir -p src && printf 'alpha\\nneedle here\\nomega\\n' > src/a.txt && printf 'no match\\n' > b.txt")
    local p = process.start({ "rg", "--no-heading", "--line-number", "needle" }, { cwd = m, stdin = process.REDIRECT_DISCARD })
    local out, err, code = read_all(p)
    T.eq(code, 0)
    T.eq(out, "src/a.txt:2:needle here\n")
    -- rg with the root as an argument (rgsearch style): paths come back as mount paths
    p = process.start({ "rg", "--no-heading", "--line-number", "needle", m })
    out = read_all(p)
    local file, line, text = out:match("^(.-):(%d+):(.*)\n$")
    T.eq(line, "2"); T.eq(text, "needle here")
    T.ok(paths.is_remote(file), file)
    T.eq(file, paths.join(paths.join(m, "src"), "a.txt"))
    -- no match: exit code 1; bad option: stderr text
    p = process.start({ "rg", "nonexistentpattern" }, { cwd = m, stdin = process.REDIRECT_DISCARD })
    out, err, code = read_all(p)
    T.eq(code, 1); T.eq(out, "")
    p = process.start({ "rg", "--bogus-option" }, { cwd = m, stdin = process.REDIRECT_DISCARD })
    out, err, code = read_all(p)
    T.ok(code ~= 0)
    T.ok(err:find("bogus"), err)
    -- merged stderr
    p = process.start({ "ls", paths.join(m, "nonexistent") }, { stderr = process.REDIRECT_STDOUT })
    out, err, code = read_all(p)
    T.ok(out:find("No such file"), out)
  end)

  T.test("process: stdin, streams API (read with yield), wait", function()
    T.connect()
    local dir, m = T.tmpdir()
    local p = process.start({ "cat" }, { cwd = m })
    T.eq(p:write("hello "), 6)
    p.stdin:write("world\n")
    p:close_stream(process.STREAM_STDIN)
    -- process.stream:read inside a thread yields while waiting
    local got = T.in_thread(function() return p.stdout:read("all") end)
    T.eq(got, "hello world\n")
    T.eq(p:wait(5000), 0)
    T.eq(p:returncode(), 0)
    T.ok(not p:running())
    T.ok(type(p:pid()) == "number")
    -- line reads
    local q = process.start({ "sh", "-c", "echo one; echo two" }, { cwd = m })
    local l1, l2 = T.in_thread(function() return q.stdout:read("line"), q.stdout:read("line") end)
    T.eq(l1, "one"); T.eq(l2, "two")
  end)

  T.test("process: terminate and kill", function()
    T.connect()
    local dir, m = T.tmpdir()
    local p = process.start({ "sleep", "60" }, { cwd = m })
    T.ok(p:running())
    local t0 = system.get_time()
    p:terminate()
    T.wait_for(function() return not p:running() end, 10, "terminated process")
    T.ok(system.get_time() - t0 < 5)
    local q = process.start({ "sh", "-c", "trap '' TERM; sleep 60" }, { cwd = m })
    q:kill()
    T.wait_for(function() return not q:running() end, 10, "killed process")
  end)

  T.test("process: large output with flow control", function()
    T.connect()
    local dir, m = T.tmpdir()
    local p = process.start({ "sh", "-c", "head -c 20000000 /dev/zero | tr '\\0' 'x'" }, { cwd = m })
    local total = 0
    local deadline = system.get_time() + 60
    while p:running() or total < 20000000 do
      local d = p:read_stdout(262144)
      if d and d ~= "" then total = total + #d end
      if system.get_time() > deadline then break end
      if not d or d == "" then T.sleep(0.002) end
    end
    T.eq(total, 20000000)
  end)

  T.test("process: local commands are untouched", function()
    local cmd = PLATFORM == "Windows" and { "cmd", "/c", "echo local" } or { "sh", "-c", "echo local" }
    local p = process.start(cmd)
    local out = read_all(p)
    T.ok(out:find("local"), out)
  end)

  T.test("process: cwd and an argument on the same tree map output back once; stream released", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("cd " .. dir .. " && mkdir src && echo a > src/a.lua")
    local src = paths.join(m, "src")
    local p = process.start({ "find", src, "-type", "f" }, { cwd = m })
    local out, _, code = read_all(p)
    T.eq(code, 0)
    local line = out:match("[^\n]+")
    T.eq(line, paths.join(src, "a.lua"))
    T.eq(system.get_file_info(line).type, "file")
    -- an exited process no longer keeps a stream handler (and the ticker busy)
    T.eq(h.conn.streams[p.process.stream_id], nil)
  end)

  T.test("process: unknown program reports exec_failed", function()
    T.connect()
    local dir, m = T.tmpdir()
    T.fails(function() process.start({ "definitely-not-a-program" }, { cwd = m }) end, "cannot run")
  end)
end
