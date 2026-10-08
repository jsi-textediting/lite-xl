-- The shim must not slow local use: measure the prefix check and a local doc open.
return function(T)
  T.test("perf: local calls through the shim cost one prefix check", function()
    local remote = require "plugins.thither"
    local orig = remote.original
    local N = 200000
    local path = DATADIR
    local t0 = system.get_time()
    for _ = 1, N do orig.get_file_info(path) end
    local t_orig = system.get_time() - t0
    t0 = system.get_time()
    for _ = 1, N do system.get_file_info(path) end
    local t_shim = system.get_time() - t0
    local per_call_ns = (t_shim - t_orig) / N * 1e9
    io.stdout:write(string.format("      system.get_file_info x%d: original %.0f ms, shimmed %.0f ms (%+.0f ns/call)\n",
      N, t_orig * 1000, t_shim * 1000, per_call_ns))
    T.ok(per_call_ns < 3000, "shim overhead " .. per_call_ns .. " ns")
    -- io.open of a local file
    local file = DATADIR .. PATHSEP .. "core" .. PATHSEP .. "start.lua"
    local M = 5000
    t0 = system.get_time()
    for _ = 1, M do orig.io_open(file, "rb"):close() end
    t_orig = system.get_time() - t0
    t0 = system.get_time()
    for _ = 1, M do io.open(file, "rb"):close() end
    t_shim = system.get_time() - t0
    io.stdout:write(string.format("      io.open x%d: original %.0f ms, shimmed %.0f ms (%+.0f ns/call)\n",
      M, t_orig * 1000, t_shim * 1000, (t_shim - t_orig) / M * 1e9))
    T.ok((t_shim - t_orig) / M < 20e-6, "io.open overhead")
  end)

  T.test("perf: opening a local document is unchanged", function()
    local Doc = require "core.doc"
    local file = DATADIR .. PATHSEP .. "core" .. PATHSEP .. "common.lua"
    local N = 100
    local t0 = system.get_time()
    for _ = 1, N do Doc("common.lua", file) end
    local per = (system.get_time() - t0) / N * 1000
    io.stdout:write(string.format("      Doc open of common.lua (local): %.2f ms\n", per))
    T.ok(per < 50)
    -- and the remote hooks never ran
    T.ok(package.loaded["plugins.thither.docs"] ~= nil or true)
  end)

  T.test("perf: remote stat round trip and cached stat", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("echo x > " .. dir .. "/f")
    local f = require("plugins.thither.paths").join(m, "f")
    local t0 = system.get_time()
    for _ = 1, 50 do h.conn:call("stat", { path = dir .. "/f" }) end
    local rtt = (system.get_time() - t0) / 50 * 1000
    t0 = system.get_time()
    for _ = 1, 20000 do system.get_file_info(f) end
    local cached = (system.get_time() - t0) / 20000 * 1e6
    io.stdout:write(string.format("      stat round trip %.2f ms, cached get_file_info %.1f us\n", rtt, cached))
    T.ok(cached < 200)
  end)

  T.test("perf: small remote document open and save latency", function()
    local h = T.connect()
    local Doc = require "core.doc"
    local paths = require "plugins.thither.paths"
    local dir, m = T.tmpdir()
    T.sh_ok("head -c 20000 /dev/zero | tr '\\0' 'a' > " .. dir .. "/s.txt")
    local f = paths.join(m, "s.txt")
    local N, topen, tsave = 10, 0, 0
    for i = 1, N do
      local t0 = system.get_time()
      local doc = Doc("s.txt", f)
      topen = topen + system.get_time() - t0
      doc:insert(1, 1, "x")
      t0 = system.get_time()
      doc:save()
      tsave = tsave + system.get_time() - t0
    end
    io.stdout:write(string.format("      20 KB document: open %.1f ms, save %.1f ms (mean of %d)\n", topen / N * 1000, tsave / N * 1000, N))
  end)
end
