-- Tiny test framework + helpers for the remote client tests (see lxc_runtime.lua).
local T = {}

T.passed, T.failed, T.skipped = 0, 0, 0
T.tests = {}
T.tmpdirs = {}

local function now() return system.get_time() end

function T.test(name, fn, opts)
  T.tests[#T.tests + 1] = { name = name, fn = fn, opts = opts }
end

--- Marks a test that needs rg on the server / only works over WSL.
function T.test_rg(name, fn) T.test(name, fn, { needs_rg = true }) end
function T.test_wsl(name, fn) T.test(name, fn, { wsl_only = true }) end

---------------------------------------------------------------------------
-- Assertions
---------------------------------------------------------------------------

local function fmt(v)
  if type(v) == "string" then
    if #v > 80 then return string.format("%q...(%d bytes)", v:sub(1, 80), #v) end
    return string.format("%q", v)
  end
  return tostring(v)
end

function T.eq(a, b, msg)
  if a ~= b then
    error(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", fmt(b), fmt(a)), 2)
  end
end

function T.ok(v, msg)
  if not v then error(msg or "assertion failed", 2) end
  return v
end

function T.fails(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then error((msg or "expected an error") .. ": nothing raised", 2) end
  if pattern and not tostring(err):find(pattern) then
    error(string.format("%serror %q does not match %q", msg and (msg .. ": ") or "", tostring(err), pattern), 2)
  end
  return err
end

---------------------------------------------------------------------------
-- Scheduler: headless mode runs core.threads like core.run does
---------------------------------------------------------------------------

function T.step()
  local core = T.core
  local t = now()
  local list = {}
  for k, th in pairs(core.threads) do list[#list + 1] = { k, th } end
  for _, e in ipairs(list) do
    local k, th = e[1], e[2]
    if core.threads[k] and th.wake <= t and coroutine.status(th.cr) == "suspended" then
      local ok, wait = coroutine.resume(th.cr)
      if not ok then
        io.stdout:write("THREAD ERROR: " .. tostring(wait) .. "\n")
        core.threads[k] = nil
      elseif coroutine.status(th.cr) == "dead" then
        core.threads[k] = nil
      else
        th.wake = now() + (wait or 1 / 30)
      end
    end
  end
end

--- Lets the world run for a moment (works in headless and real mode).
function T.sleep(s)
  s = s or 0.002
  if T.real then
    coroutine.yield(s)
  else
    local t0 = now()
    repeat
      T.step()
      system.sleep(0.001)
    until now() - t0 >= s
  end
end

function T.wait_for(pred, timeout, what)
  local deadline = now() + (timeout or 10)
  while not pred() do
    if now() > deadline then error("timeout waiting for " .. (what or "condition"), 2) end
    T.sleep(0.002)
  end
end

--- Runs fn in a core thread and waits for it; returns its results.
--- Used to exercise the yield-polling branch of blocking calls.
function T.in_thread(fn, timeout)
  local core = T.core
  local res
  core.add_thread(function()
    res = table.pack(pcall(fn))
  end)
  T.wait_for(function() return res ~= nil end, timeout or 30, "thread")
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

---------------------------------------------------------------------------
-- WSL shell helper and server setup
---------------------------------------------------------------------------

-- Target host: LXC_HOST (a PuTTY session / user@host) selects a real host that
-- is reached with the client's default launcher (plink); otherwise WSL.
T.host = (os.getenv("LXC_HOST") or "") ~= "" and os.getenv("LXC_HOST") or nil
T.spec = T.host or "wsl:"
T.label = T.host and T.host:gsub("[^%w_.@-]", "-") or "wsl"
-- tests that need `rg` on the server are skipped when LXC_NO_RG=1
T.no_rg = os.getenv("LXC_NO_RG") == "1"

local function sq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

--- Runs a shell script on the server (inside WSL, or via plink on the real host); returns output, exit code.
function T.sh(script, timeout)
  local argv
  if T.host then
    argv = { "plink", "-batch", "-ssh", "-T", T.host, "sh -c " .. sq(script) }
  else
    argv = { "wsl.exe", "-e", "sh", "-c", script }
  end
  local p = process.start(argv, { stderr = process.REDIRECT_STDOUT, stdin = process.REDIRECT_DISCARD })
  local out = {}
  local deadline = now() + (timeout or 120)
  while p:running() do
    local d = p:read_stdout(65536)
    if d and d ~= "" then out[#out + 1] = d end
    if now() > deadline then p:kill(); error("shell timeout: " .. script) end
    T.sleep(0.003)
  end
  while true do
    local d = p:read_stdout(65536)
    if not d or d == "" then break end
    out[#out + 1] = d
  end
  return table.concat(out), p:returncode()
end

function T.sh_ok(script, timeout)
  local out, code = T.sh(script, timeout)
  if code ~= 0 then error("shell failed (" .. tostring(code) .. "): " .. script .. "\n" .. out, 2) end
  return out
end

function T.configure_remote()
  local config = require "core.config"
  local server = os.getenv("LXC_SERVER")
  local datadir = os.getenv("LXC_DATADIR")
  assert(server, "set LXC_SERVER (run.ps1 does)")
  local rc = config.plugins.thither
  local args = (datadir and datadir ~= "") and { "--datadir", datadir } or {}
  rc.hosts = { [T.label] = { server_path = server, server_args = args } }
  rc.ping_interval = 2
  rc.ping_timeout = 20
  rc.stat_ttl_nowatch = 0.2
  rc.reconnect_delays = { 0.3, 0.5, 1 }
end

function T.connect()
  local vfs = require "plugins.thither.vfs"
  local h = vfs.hosts[T.label]
  if h and h.conn and h.conn.state == "ready" then return h end
  local h2, err = vfs.connect(T.spec)
  assert(h2, "cannot connect: " .. tostring(err))
  return h2
end

--- Waits until every requested server watch is established.
function T.watch_ready(h)
  T.wait_for(function() return h.watch_ok and (h.watch_inflight or 0) == 0 end, 10, "server watch")
end

--- Creates a temp dir on the server. Returns its POSIX path and mount path.
function T.tmpdir(name)
  local paths = require "plugins.thither.paths"
  local dir = T.sh_ok("mktemp -d /tmp/lxc-test-XXXXXX"):gsub("%s+$", "")
  T.tmpdirs[#T.tmpdirs + 1] = dir
  return dir, paths.make(T.label, dir)
end

---------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------

function T.setup(core, real)
  T.core = core
  T.real = real or false
  core.projects = core.projects or {}
  -- Nags are recorded instead of shown so tests can answer them (also in the
  -- real editor, where core.nag_view is the real view).
  local nv = core.nag_view
  if not nv then
    nv = {}
    core.nag_view = nv
  end
  nv.shown = {}
  nv.show = function(self, title, message, options, cb)
    self.shown[#self.shown + 1] = { title = title, message = message, options = options, cb = cb }
  end
end

--- Answers the oldest nag matching `title_pattern` with the option `text`.
function T.answer_nag(title_pattern, text)
  local nv = T.core.nag_view
  local shown = nv.shown
  assert(shown, "answer_nag needs the stub nag view (headless mode)")
  for i, n in ipairs(shown) do
    if n.title:find(title_pattern) then
      table.remove(shown, i)
      for _, o in ipairs(n.options) do
        if o.text == text then n.cb(o) return n end
      end
      error("nag has no option " .. text)
    end
  end
  error("no nag matching " .. title_pattern)
end

function T.nag_count(title_pattern)
  local n = 0
  for _, s in ipairs(T.core.nag_view.shown or {}) do
    if s.title:find(title_pattern) then n = n + 1 end
  end
  return n
end

function T.run_all()
  local dir = os.getenv("LXC_TESTS") or USERDIR
  local files = system.list_dir(dir) or {}
  table.sort(files)
  local filter = os.getenv("LXC_FILTER")
  T.configure_remote()
  for _, f in ipairs(files) do
    if f:match("^test_.*%.lua$") then
      local chunk, err = loadfile(dir .. PATHSEP .. f)
      if not chunk then error(err) end
      local def = chunk()
      if type(def) == "function" then def(T) end
    end
  end
  local t_all = now()
  for _, t in ipairs(T.tests) do
    if filter and not t.name:find(filter, 1, true) then
      T.skipped = T.skipped + 1
    elseif t.opts and t.opts.needs_rg and T.no_rg then
      T.skipped = T.skipped + 1
      io.stdout:write(string.format("skip  %-58s skipped: no rg on host\n", t.name))
    elseif t.opts and t.opts.wsl_only and T.host then
      T.skipped = T.skipped + 1
      io.stdout:write(string.format("skip  %-58s skipped: WSL transport test\n", t.name))
    else
      if T.core.nag_view then T.core.nag_view.shown = {} end      -- nags of earlier tests are void
      local t0 = now()
      local ok, err = xpcall(t.fn, function(e) return debug.traceback(tostring(e), 2) end)
      local ms = (now() - t0) * 1000
      if ok then
        T.passed = T.passed + 1
        io.stdout:write(string.format("ok    %-58s %7.0f ms\n", t.name, ms))
      else
        T.failed = T.failed + 1
        io.stdout:write(string.format("FAIL  %-58s %7.0f ms\n%s\n", t.name, ms, tostring(err)))
      end
    end
  end
  -- clean up
  local ok, vfs = pcall(require, "plugins.thither.vfs")
  if ok then
    for _, h in pairs(vfs.hosts) do if h.conn then h.conn:close("tests done") end end
  end
  if #T.tmpdirs > 0 then
    pcall(T.sh, "rm -rf " .. table.concat(T.tmpdirs, " "))
  end
  io.stdout:write(string.format("\n%d passed, %d failed, %d skipped in %.1f s\n",
    T.passed, T.failed, T.skipped, now() - t_all))
end

return T
