-- Helpers for the loopback tests (POSIX).
local U = {}

-- the embedded Lua is built without io.popen, so output goes through a file
local out_file = string.format("/tmp/thither-sh-%d.out", system.get_process_id())

--- Runs a shell command; returns its combined output and exit code.
function U.sh(cmd)
  local ok, how, code = os.execute("(" .. cmd .. ") > " .. out_file .. " 2>&1")
  local f = io.open(out_file, "rb")
  local out = f and f:read("a") or ""
  if f then f:close() end
  if ok then code = 0 end
  if code and code >= 256 then code = code // 256 end  -- raw wait status (no LUA_USE_POSIX)
  return out, code
end

function U.shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local counter = 0
local made = {}

--- Creates a fresh temporary directory (removed by U.cleanup()).
function U.tmpdir(prefix)
  counter = counter + 1
  local base = os.getenv("THITHER_TEST_TMP") or "/tmp"
  local dir = string.format("%s/thither-%s-%d-%d-%d", base, prefix or "t", system.get_process_id(), os.time(), counter)
  assert(os.execute("mkdir -p " .. U.shq(dir)))
  made[#made + 1] = dir
  return dir
end

function U.cleanup()
  for _, d in ipairs(made) do os.execute("rm -rf " .. U.shq(d)) end
  made = {}
end

function U.write_file(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

function U.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end

function U.exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

--- Sorted names in a directory (via ls -A).
function U.ls(dir)
  local out = U.sh("ls -A " .. U.shq(dir))
  local names = {}
  for n in out:gmatch("[^\n]+") do names[#names + 1] = n end
  table.sort(names)
  return names
end

function U.count_lf(s)
  local _, n = s:gsub("\n", "\n")
  return n
end

return U
