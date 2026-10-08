-- Test runtime for the remote client: loaded by lite-xl.exe through
--   LITE_XL_RUNTIME=lxc_runtime   (this directory is the USERDIR, so `require`
--                                  finds it; see run.ps1 and data/plugins/thither/README.md)
-- It replaces `core` as the entry module. Two modes:
--   headless (default)  the real core modules (common, doc, project, ...) are
--                       loaded but core.init() is not called: no window. A
--                       small scheduler runs core.threads like core.run does.
--   LXC_REAL=1          the real core.init()/core.run() with a window; the tests
--                       run inside a core thread of the real editor.
-- Environment: LXC_SERVER (server executable inside WSL or on LXC_HOST), LXC_HOST (real host, plink launcher; empty = WSL), LXC_NO_RG, LXC_DATADIR (optional server
-- --datadir, e.g. thither/lua as seen from WSL), LXC_FILTER (test name substring), LXC_BIG_MB.
local M = {}

local T = require "framework"

local function run_headless()
  local core = require "core"
  core.threads = setmetatable({}, { __mode = "k" })
  -- core.init (which loads plugins) does not run headless
  require "plugins.thither"
  T.setup(core)
  local ok, err = xpcall(T.run_all, debug.traceback)
  if not ok then
    io.stdout:write("RUNNER ERROR: " .. tostring(err) .. "\n")
    io.stdout:flush()
    os.exit(2)
  end
  io.stdout:flush()
  os.exit(T.failed > 0 and 1 or 0)
end

local function run_real()
  local core = require "core"
  core.init()
  -- core.run sleeps without a timeout while the window is unfocused (the test
  -- window usually is): pretend it has the focus so threads keep running
  system.window_has_focus = function() return true end
  -- tests run in a core thread of the real editor (so blocking calls yield-poll)
  T.setup(core, true)
  core.add_thread(function()
    local ok, err = xpcall(T.run_all, debug.traceback)
    if not ok then io.stdout:write("RUNNER ERROR: " .. tostring(err) .. "\n") end
    io.stdout:flush()
    local code = (not ok) and 2 or (T.failed > 0 and 1 or 0)
    os.exit(code)
  end)
  core.run()
end

function M.init()
  if os.getenv("LXC_REAL") == "1" then
    M.real = true
  end
  io.stdout:setvbuf("no")
end

function M.run()
  if M.real then run_real() else run_headless() end
end

-- main.c calls core.init() then core.run(); in headless mode init is a no-op
-- and run() does everything. In real mode init is deferred to run_real.
return M
