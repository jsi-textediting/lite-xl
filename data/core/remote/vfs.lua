--- Remote virtual file system: everything the shimmed system / io / os /
--- process functions do for a path below the mount root (data/core/remote/init.lua
--- installs the dispatch). Blocking entry points exist only for APIs that are
--- synchronous by contract; they are cached (see cache.lua) and invalidated by
--- server watch events.
local paths = require "core.remote.paths"
local options = require "core.remote.options"
local Conn = require "core.remote.client"
local Cache = require "core.remote.cache"

local vfs = {}

local parse = paths.parse
local WIN = paths.WINDOWS

local function now() return system.get_time() end

local function log(level, fmt, ...)
  local ok, core = pcall(require, "core")
  if ok and core[level] then
    if pcall(core[level], fmt, ...) then return end
  end
  io.stderr:write(string.format(fmt, ...) .. "\n")
end
vfs.log = log

---------------------------------------------------------------------------
-- Errors
---------------------------------------------------------------------------

local ERRNO = {
  EPERM = { 1, "Operation not permitted" }, ENOENT = { 2, "No such file or directory" },
  EIO = { 5, "Input/output error" }, EACCES = { 13, "Permission denied" },
  EEXIST = { 17, "File exists" }, EXDEV = { 18, "Invalid cross-device link" },
  ENOTDIR = { 20, "Not a directory" }, EISDIR = { 21, "Is a directory" },
  EINVAL = { 22, "Invalid argument" }, ENOSPC = { 28, "No space left on device" },
  EROFS = { 30, "Read-only file system" }, ENOTEMPTY = { 39, "Directory not empty" },
  ELOOP = { 40, "Too many levels of symbolic links" },
}

--- Maps a protocol error table to (message, errno) in the style of io.open.
local function errmsg(path, err)
  err = err or {}
  local e = ERRNO[err.code]
  if e then return path .. ": " .. e[2], e[1] end
  if err.code == "disconnected" or err.code == "timeout" then
    return path .. ": remote connection unavailable (" .. tostring(err.msg) .. ")", 5
  elseif err.code == "conflict" then
    return path .. ": file changed on the server (conflict)", 11
  elseif err.code == "stale" then
    return path .. ": file changed on the server", 11
  end
  return path .. ": " .. tostring(err.msg or err.code or "remote error"), 5
end
vfs.errmsg = errmsg

---------------------------------------------------------------------------
-- Hosts and connections
---------------------------------------------------------------------------

local hosts = {}
vfs.hosts = hosts

local recent -- lazily loaded list of { label=, spec= }

local function registry_file()
  return USERDIR and (USERDIR .. PATHSEP .. "remote_hosts.lua")
end

local function load_recent()
  if recent then return recent end
  recent = {}
  local f = registry_file()
  if f then
    local fp = io.open(f, "rb")
    if fp then
      local src = fp:read("a")
      fp:close()
      local fn = load(src or "", "=remote_hosts", "t", {})
      local ok, t = pcall(fn or function() end)
      if ok and type(t) == "table" then recent = t end
    end
  end
  return recent
end

local function save_recent()
  local f = registry_file()
  if not f then return end
  local parts = { "return {\n" }
  for _, r in ipairs(recent) do
    parts[#parts + 1] = string.format("  { label = %q, spec = %q, path = %q },\n", r.label, r.spec, r.path or "")
  end
  parts[#parts + 1] = "}\n"
  local fp = io.open(f, "wb")
  if fp then fp:write(table.concat(parts)); fp:close() end
end

--- Recent hosts list: array of { label, spec, path }.
function vfs.recent_hosts()
  return load_recent()
end

function vfs.remember_host(spec, label, path)
  local list = load_recent()
  for i = #list, 1, -1 do
    if list[i].label == label then table.remove(list, i) end
  end
  table.insert(list, 1, { label = label, spec = spec, path = path })
  local max = options.get("recent_hosts")
  while #list > max do table.remove(list) end
  save_recent()
end

--- Host spec for a path label (reverse of sanitize_host).
local function spec_for(label)
  local h = hosts[label]
  if h and h.spec then return h.spec end
  for _, r in ipairs(load_recent()) do
    if r.label == label then return r.spec end
  end
  if label == "wsl" then return "wsl:" end
  if label == "local" then return "local:" end
  local distro = label:match("^wsl%-(.+)$")
  if distro then return "wsl:" .. distro end
  return label
end

local function get_host(label)
  local h = hosts[label]
  if not h then
    h = { label = label, evlog = {}, seq = 0, etags = {}, watches = {}, watch_wanted = {} }
    h.cache = Cache.new(function()
      return (h.watch_ok and options.get("stat_ttl", label)) or options.get("stat_ttl_nowatch", label)
    end)
    hosts[label] = h
  end
  return h
end
vfs.get_host = get_host

local function ensure_conn(h, quiet)
  local c = h.conn
  if not c then
    h.spec = h.spec or spec_for(h.label)
    c = Conn.new(h.spec, h.label)
    h.conn = c
    vfs.attach(h, c)
  end
  if c.state == "ready" then return c end
  if c.state == "connecting" then
    local ok, why = c:wait_ready()
    if ok then return c end
    return nil, { code = "disconnected", msg = tostring(why) }
  end
  -- idle, closed or failed: try (re)connecting, but not more than every 5 s
  local t = now()
  if h.last_try and t - h.last_try < 5 then
    return nil, { code = "disconnected", msg = c.reason or "not connected" }
  end
  h.last_try = t
  if not quiet then log("log", "Connecting to %s ...", h.label) end
  local ok, msg
  if c.generation == 0 then ok, msg = c:start() else ok, msg = c:reconnect() end
  if not ok then return nil, { code = "disconnected", msg = msg } end
  local ok2, why = c:wait_ready()
  if ok2 then return c end
  return nil, { code = "disconnected", msg = tostring(why) }
end
vfs.ensure_conn = ensure_conn

--- Connection for a host label; returns conn or nil, err.
function vfs.conn_for(label, quiet)
  return ensure_conn(get_host(label), quiet)
end

--- Opens (or reuses) the connection to `spec`; returns the host record.
function vfs.connect(spec, blocking)
  local label = paths.sanitize_host(spec)
  local h = get_host(label)
  h.spec = spec
  if not h.conn then
    h.conn = Conn.new(spec, label)
    vfs.attach(h, h.conn)
  end
  local c = h.conn
  if c.state ~= "ready" and c.state ~= "connecting" then
    h.last_try = now()
    local ok, msg = c:start()
    if not ok then return nil, msg end
  end
  if blocking ~= false then
    local ok, why = c:wait_ready()
    if not ok then return nil, tostring(why) end
  end
  return h
end

--- Blocking request on the connection of `h`: ok | nil, err.
local function rpc(h, op, args, timeout, opts)
  local c, err = ensure_conn(h)
  if not c then return nil, err end
  return c:call(op, args, timeout, opts)
end
vfs.rpc = rpc

--- Same for a mount path; returns ok, err, host, rpath.
function vfs.rpc_path(path, op, args, timeout)
  local label, rpath = parse(path)
  if not label then return nil, { code = "bad_path", msg = "not a remote path" } end
  args = args or {}
  args.path = rpath
  local h = get_host(label)
  local ok, err = rpc(h, op, args, timeout)
  return ok, err, h, rpath
end

---------------------------------------------------------------------------
-- stat / readdir
---------------------------------------------------------------------------

local function to_info(raw)
  local t = raw.type
  local info = {
    size = raw.size,
    modified = raw.mtime,
    type = (t == "file" or t == "dir") and t or nil,
  }
  if t == "dir" then info.symlink = raw.is_link or false end
  return info
end
vfs.to_info = to_info

--- Raw server stat of host/rpath, cached unless `fresh`. nil, err on failure
--- (err.code == "ENOENT" for a missing file).
function vfs.stat_raw(h, rpath, fresh)
  if not fresh then
    local c = h.cache:get_stat(rpath)
    if c then return c end
    if c == false then return nil, { code = "ENOENT" } end
  end
  local raw, err = rpc(h, "stat", { path = rpath })
  if raw then
    h.cache:put_stat(rpath, raw)
    return raw
  end
  if err and err.code == "ENOENT" then h.cache:put_stat(rpath, nil) end
  return nil, err
end

function vfs.get_file_info(path)
  local label, rpath = parse(path)
  if not label then return nil, "invalid remote path" end
  local h = get_host(label)
  local raw, err = vfs.stat_raw(h, rpath)
  if not raw then return nil, (select(1, errmsg(path, err))) end
  return to_info(raw)
end

--- Lists a remote directory: array of server stat tables with `name`.
function vfs.readdir_entries(h, rpath)
  local all, offset = {}, 0
  while true do
    local res, err = rpc(h, "readdir", { path = rpath, offset = offset, limit = 20000 })
    if not res then return nil, err end
    for _, e in ipairs(res.entries) do all[#all + 1] = e end
    if not res.more or #res.entries == 0 then break end
    offset = offset + #res.entries
  end
  return all
end

function vfs.list_dir(path)
  local label, rpath = parse(path)
  if not label then return nil, "invalid remote path" end
  local h = get_host(label)
  local names = h.cache:get_dir(rpath)
  if names then
    local copy = {}
    for i, n in ipairs(names) do copy[i] = n end
    return copy
  end
  local entries, err = vfs.readdir_entries(h, rpath)
  if not entries then return nil, (select(1, errmsg(path, err))) end
  h.cache:put_dir(rpath, entries)
  local copy = {}
  for i, e in ipairs(entries) do copy[i] = e.name end
  return copy
end

function vfs.absolute_path(path)
  local p = paths.normalize(path)
  return p
end

function vfs.mkdir(path)
  local ok, err, h, rpath = vfs.rpc_path(path, "mkdir", {})
  if not ok then return false, (select(1, errmsg(path, err))) end
  h.cache:invalidate_path(rpath)
  return true
end

function vfs.rmdir(path)
  local label, rpath = parse(path)
  local h = get_host(label)
  local raw, err = vfs.stat_raw(h, rpath, true)
  if not raw then return false, (select(1, errmsg(path, err))) end
  if raw.type ~= "dir" then return false, path .. ": Not a directory" end
  local ok, err2 = rpc(h, "remove", { path = rpath })
  if not ok then return false, (select(1, errmsg(path, err2))) end
  h.cache:invalidate_path(rpath)
  return true
end

function vfs.remove(path)
  local ok, err, h, rpath = vfs.rpc_path(path, "remove", {})
  if not ok then
    local m, n = errmsg(path, err)
    return nil, m, n
  end
  h.cache:invalidate_path(rpath)
  h.etags[rpath] = nil
  return true
end

function vfs.rename(from, to)
  local h1, r1 = parse(from)
  local h2, r2 = parse(to)
  if not h1 or h1 ~= h2 then
    return nil, from .. ": cannot rename between local and remote or different hosts", 18
  end
  local h = get_host(h1)
  local ok, err = rpc(h, "rename", { from = r1, to = r2 })
  if not ok then
    local m, n = errmsg(from, err)
    return nil, m, n
  end
  h.cache:invalidate_path(r1)
  h.cache:invalidate_path(r2)
  h.etags[r1], h.etags[r2] = nil, nil
  return true
end

--- Home directory of the remote account (hello reply).
function vfs.home(label)
  local c = vfs.conn_for(label, true)
  return c and c.hello and c.hello.home
end

---------------------------------------------------------------------------
-- Whole-file read / write helpers
---------------------------------------------------------------------------

--- Reads a remote file completely. Returns data, etag or nil, err.
function vfs.read_file(h, rpath)
  local read_size = options.get("read_size", h.label)
  local parts, off, etag = {}, 0, nil
  while true do
    local res, err = rpc(h, "read", { path = rpath, offset = off, len = read_size, etag = etag }, 60)
    if not res then return nil, err end
    etag = etag or res.etag
    parts[#parts + 1] = res.data
    off = off + #res.data
    if res.eof or #res.data == 0 then break end
  end
  return table.concat(parts), etag
end

local MAX_ONE_WRITE = 8 * 1024 * 1024

--- Atomic write. opts: if_match (etag or "-"), mode, create_dirs.
--- Returns the new server stat table or nil, err ("conflict" has err.etag).
function vfs.write_file(h, rpath, data, opts)
  opts = opts or {}
  local res, err
  if #data <= MAX_ONE_WRITE then
    res, err = rpc(h, "write", { path = rpath, data = require("core.remote.msgpack").bin(data),
      if_match = opts.if_match, mode = opts.mode, create_dirs = opts.create_dirs }, 60)
  else
    local begin, e1 = rpc(h, "write_begin", { path = rpath, if_match = opts.if_match,
      mode = opts.mode, create_dirs = opts.create_dirs })
    if not begin then return nil, e1 end
    local bin = require("core.remote.msgpack").bin
    local step = 1024 * 1024
    local failed
    for off = 1, #data, step do
      local ok, e2 = rpc(h, "write_chunk", { wid = begin.wid, data = bin(data:sub(off, off + step - 1)) }, 60)
      if not ok then failed = e2; break end
    end
    if failed then
      rpc(h, "write_abort", { wid = begin.wid })
      return nil, failed
    end
    res, err = rpc(h, "write_commit", { wid = begin.wid }, 120)
  end
  if not res then return nil, err end
  h.cache:invalidate_path(rpath)
  if type(res) == "table" and res.etag then h.etags[rpath] = res.etag end
  return res
end

---------------------------------------------------------------------------
-- io.open / io.lines / loadfile / dofile
---------------------------------------------------------------------------

local File = {}
File.__index = File
File.__name = "remote file"
vfs.File = File

function File:__tostring()
  return (self.closed and "file (closed)" or "file (remote ") .. (self.closed and "" or (self.path .. ")"))
end

local function fill(self)
  -- fetches the next block of a read-mode file; returns false at EOF/error
  if self.eof then return false end
  local h = self.h
  local res, err = rpc(h, "read", { path = self.rpath, offset = self.next_off,
    len = options.get("read_size", h.label), etag = self.etag }, 60)
  if not res then
    self.eof, self.failed = true, err
    return false
  end
  self.etag = self.etag or res.etag
  if self.next_off == 0 then h.etags[self.rpath] = res.etag end
  self.next_off = self.next_off + #res.data
  if #res.data > 0 then
    if self.pos > #self.data then self.data, self.pos = res.data, 1
    else self.data = self.data:sub(self.pos) .. res.data; self.pos = 1 end
  end
  if res.eof or #res.data == 0 then self.eof = true end
  return #res.data > 0
end

local function read_one(self, fmt)
  if type(fmt) == "number" then
    local n = fmt
    while #self.data - self.pos + 1 < n and not self.eof do fill(self) end
    if n == 0 then return (self.pos <= #self.data or not self.eof) and "" or nil end
    local avail = #self.data - self.pos + 1
    if avail <= 0 then return nil end
    local s = self.data:sub(self.pos, self.pos + math.min(n, avail) - 1)
    self.pos = self.pos + #s
    return s
  end
  fmt = tostring(fmt):gsub("^%*", "")
  local c = fmt:sub(1, 1)
  if c == "a" then
    while not self.eof do fill(self) end
    local s = self.data:sub(self.pos)
    self.pos = #self.data + 1
    return s
  elseif c == "l" or c == "L" then
    while true do
      local nl = self.data:find("\n", self.pos, true)
      if nl then
        local s = self.data:sub(self.pos, c == "L" and nl or nl - 1)
        self.pos = nl + 1
        return s
      end
      if self.eof then break end
      fill(self)
    end
    if self.pos > #self.data then return nil end
    local s = self.data:sub(self.pos)
    self.pos = #self.data + 1
    return s
  elseif c == "n" then
    while not self.eof and #self.data - self.pos + 1 < 64 do fill(self) end
    local num, e = self.data:match("^%s*([%+%-]?%d*%.?%d+[eE]?[%+%-]?%d*)()", self.pos)
    if not num then return nil end
    self.pos = e
    return tonumber(num)
  end
  error("bad argument #1 to 'read' (invalid format)", 3)
end

function File:read(...)
  if self.closed then error("attempt to use a closed file", 2) end
  if self.mode ~= "r" then return nil, "Bad file descriptor", 9 end
  local n = select("#", ...)
  if n == 0 then return read_one(self, "l") end
  local out = {}
  for i = 1, n do
    local v = read_one(self, (select(i, ...)))
    out[i] = v
    if v == nil then return table.unpack(out, 1, i) end
  end
  return table.unpack(out, 1, n)
end

function File:lines(...)
  local fmts = table.pack(...)
  if self.closed then error("file is already closed", 2) end
  return function()
    if self.closed then error("file is already closed", 2) end
    if fmts.n == 0 then return read_one(self, "l") end
    return self:read(table.unpack(fmts, 1, fmts.n))
  end
end

function File:write(...)
  if self.closed then error("attempt to use a closed file", 2) end
  if self.mode ~= "w" then return nil, "Bad file descriptor", 9 end
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    local t = type(v)
    if t == "number" then v = tostring(v)
    elseif t ~= "string" then error("bad argument #" .. i .. " to 'write' (string expected, got " .. t .. ")", 2) end
    self.wbuf[#self.wbuf + 1] = v
    self.wlen = self.wlen + #v
  end
  return self
end

function File:seek(whence, offset)
  whence, offset = whence or "cur", offset or 0
  if self.mode == "r" then
    if whence == "set" then
      self.data, self.pos, self.next_off, self.eof = "", 1, offset, false
      return offset
    elseif whence == "cur" then
      if offset ~= 0 then
        -- relative seek inside the buffered window only
        local np = self.pos + offset
        if np >= 1 and np <= #self.data + 1 then self.pos = np else return nil, "Invalid argument", 22 end
      end
      return self.next_off - (#self.data - self.pos + 1)
    end
    while not self.eof do fill(self) end
    return self.next_off + offset
  end
  if whence == "end" or whence == "cur" then return self.wlen end
  return nil, "Invalid argument", 22
end

function File:flush() return self end
function File:setvbuf() return true end

function File:close()
  if self.closed then error("attempt to use a closed file", 2) end
  self.closed = true
  if self.mode == "w" then
    local data = table.concat(self.wbuf)
    self.wbuf = nil
    local if_match = self.if_match
    if if_match == nil and not self.no_check then if_match = self.h.etags[self.rpath] end
    local res, err = vfs.write_file(self.h, self.rpath, data, { if_match = if_match })
    if not res then
      local m, n = errmsg(self.path, err)
      return nil, m, n
    end
  end
  return true
end

File.__gc = nil
File.__close = function(self) if not self.closed then pcall(File.close, self) end end

--- io.open for a remote path. Modes: r, rb, w, wb, a, ab (no "+" modes).
function vfs.io_open(path, mode)
  mode = mode or "r"
  local label, rpath = parse(path)
  if not label then return nil, path .. ": Invalid argument", 22 end
  local base = mode:gsub("b", "")
  if base ~= "r" and base ~= "w" and base ~= "a" then
    return nil, path .. ": remote files do not support mode '" .. mode .. "'", 22
  end
  local h = get_host(label)
  local self = setmetatable({ path = path, rpath = rpath, h = h, data = "", pos = 1,
    next_off = 0, eof = false, wbuf = {}, wlen = 0 }, File)
  if base == "r" then
    self.mode = "r"
    local raw, err = vfs.stat_raw(h, rpath, true)
    if not raw then local m, n = errmsg(path, err); return nil, m, n end
    if raw.type == "dir" then return nil, path .. ": Is a directory", 21 end
    fill(self)   -- first block: also errors early (EACCES)
    if self.failed then local m, n = errmsg(path, self.failed); return nil, m, n end
    return self
  end
  self.mode = "w"
  if base == "a" then
    local data, etag = vfs.read_file(h, rpath)
    if data then
      self.wbuf[1], self.wlen = data, #data
      self.if_match = etag
    else
      self.if_match = "-"
    end
  else
    -- creating or truncating: refuse directories early
    local raw = vfs.stat_raw(h, rpath, true)
    if raw and raw.type == "dir" then return nil, path .. ": Is a directory", 21 end
  end
  return self
end

function vfs.io_lines(path, ...)
  local fp, err = vfs.io_open(path, "r")
  if not fp then error(err, 2) end
  local fmts = table.pack(...)
  return function()
    if fp.closed then return nil end
    local r = table.pack(fp:read(table.unpack(fmts, 1, fmts.n)))
    if r[1] == nil then fp:close() end
    return table.unpack(r, 1, math.max(r.n, 1))
  end
end

local function load_remote(path, mode, env)
  local fp, err = vfs.io_open(path, "r")
  if not fp then return nil, err end
  local src = fp:read("a")
  fp:close()
  if src:sub(1, 1) == "#" then src = "--" .. src end   -- shebang line
  if env ~= nil then return load(src, "@" .. path, mode, env) end
  return load(src, "@" .. path, mode)
end

function vfs.loadfile(path, mode, env)
  return load_remote(path, mode or "bt", env)
end

function vfs.dofile(path)
  local fn, err = load_remote(path, "bt")
  if not fn then error(err, 0) end
  return fn()
end

---------------------------------------------------------------------------
-- Watching: server events, dirwatch backend
---------------------------------------------------------------------------

local EVLOG_MAX = 512

local function push_event(h, ev)
  h.seq = h.seq + 1
  ev.seq = h.seq
  local log_ = h.evlog
  log_[#log_ + 1] = ev
  if #log_ > EVLOG_MAX then table.remove(log_, 1) end
end

--- Called by the connection when watch / overflow events arrive.
local function on_watch(h, msg)
  for _, dir in ipairs(msg.paths or {}) do
    h.cache:invalidate_dir(dir)
    push_event(h, { dir = dir })
  end
  local docs = package.loaded["core.remote.docs"]
  if docs and docs.on_dirs_changed then docs.on_dirs_changed(h, msg.paths or {}) end
  local ok, core = pcall(require, "core")
  if ok then core.redraw = true end
end

local function on_overflow(h)
  h.cache:clear()
  push_event(h, { overflow = true })
  local docs = package.loaded["core.remote.docs"]
  if docs and docs.on_dirs_changed then docs.on_dirs_changed(h, nil) end
end

--- Starts server watches for everything that is wanted (called after connect
--- and reconnect). `h.watch_wanted[rpath] = recursive`.
local function start_watches(h)
  local c = h.conn
  if not c or c.state ~= "ready" or not c.caps.watch or not options.get("watch", h.label) then
    h.watch_ok = false
    return
  end
  h.watches = {}
  h.watch_ok = false
  for rpath, recursive in pairs(h.watch_wanted) do
    h.watch_inflight = (h.watch_inflight or 0) + 1
    c:request("watch", { path = rpath, recursive = recursive }, function(res, err)
      h.watch_inflight = h.watch_inflight - 1
      if res then
        h.watches[rpath] = { id = res.watch, recursive = recursive, truncated = res.truncated }
        h.watch_ok = true
        if res.truncated then h.watch_truncated = true end
      else
        h.watches[rpath] = { failed = true }
        vfs.log("log_quiet", "remote: watch of %s failed: %s", rpath, err and err.msg or "?")
      end
    end)
  end
end

--- Makes sure `rpath` (a directory or file) is covered by a server watch.
function vfs.ensure_watch(h, rpath)
  if not options.get("watch", h.label) then return end
  for w, recursive in pairs(h.watch_wanted) do
    if w == rpath or (recursive and rpath:sub(1, #w + 1) == (w == "/" and "/" or w .. "/")) then return end
  end
  -- prefer one recursive watch on the project root
  local root, recursive = rpath, false
  local ok, core = pcall(require, "core")
  local proj = ok and core.root_project and core.projects and core.root_project()
  if proj then
    local ph, pr = parse(proj.path)
    if ph == h.label and (rpath == pr or rpath:sub(1, #pr + 1) == (pr == "/" and "/" or pr .. "/")) then
      root, recursive = pr, true
    end
  end
  h.watch_wanted[root] = recursive
  local c = h.conn
  if c and c.state == "ready" and c.caps.watch then
    h.watch_inflight = (h.watch_inflight or 0) + 1
    c:request("watch", { path = root, recursive = recursive }, function(res, err)
      h.watch_inflight = h.watch_inflight - 1
      if res then
        h.watches[root] = { id = res.watch, recursive = recursive, truncated = res.truncated }
        h.watch_ok = true
        if res.truncated then h.watch_truncated = true end
      else
        h.watches[root] = { failed = true }
        vfs.log("log_quiet", "remote: watch of %s failed: %s", root, err and err.msg or "?")
      end
    end)
  end
end

--- Hooks a connection up: events and state changes.
function vfs.attach(h, c)
  c:on("watch", function(_, msg) on_watch(h, msg) end)
  c:on("overflow", function() on_overflow(h) end)
  c:on("notify", function(_, msg) h.notifications = h.notifications or {}; table.insert(h.notifications, msg) end)
  local was_ready = false
  Conn.listeners[#Conn.listeners + 1] = function(conn, state)
    if conn ~= c then return end
    if state == "ready" then
      local re = was_ready
      was_ready = true
      h.cache:clear()
      h.hello = conn.hello
      start_watches(h)
      if re then
        push_event(h, { overflow = true })
        local docs = package.loaded["core.remote.docs"]
        if docs and docs.on_reconnected then docs.on_reconnected(h) end
        vfs.log("log", "Reconnected to %s", h.label)
      end
      local ok, core = pcall(require, "core")
      if ok then core.redraw = true end
    elseif state == "closed" or state == "failed" then
      h.watch_ok = false
      h.watches = {}
      local ok, core = pcall(require, "core")
      if ok then core.redraw = true end
      if was_ready and state == "closed" and not c.no_reconnect then
        vfs.log("warn", "Connection to %s lost: %s", h.label, tostring(c.reason))
      end
    end
  end
end

---------------------------------------------------------------------------
-- core.dirwatch backend
---------------------------------------------------------------------------

local function dirwatch_state(self)
  local rw = rawget(self, "rwatched")
  if not rw then rw = {}; rawset(self, "rwatched", rw) end
  return rw
end

function vfs.dirwatch_watch(self, path, unwatch)
  local rw = dirwatch_state(self)
  if unwatch == false then rw[path] = nil; return end
  local label, rpath = parse(path)
  if not label or rw[path] then return end
  local h = get_host(label)
  local raw = vfs.stat_raw(h, rpath, false)
  if not raw then return end
  rw[path] = { host = label, rpath = rpath, dir = raw.type == "dir", etag = raw.etag,
               cursor = h.seq }
  vfs.ensure_watch(h, raw.type == "dir" and rpath or Cache.parent(rpath))
end

local function fresh_etag(h, rpath)
  local raw, err = vfs.stat_raw(h, rpath, true)
  if raw then return raw.etag end
  if err and err.code == "ENOENT" then return "-" end
  return nil
end

--- Called from the patched dirwatch:check (inside a coroutine).
--- Returns true if a callback was called.
function vfs.dirwatch_check(self, cb)
  local rw = rawget(self, "rwatched")
  if not rw or not next(rw) then return false end
  local changed = false
  local t = now()
  -- group by host
  local by_host = {}
  for path, w in pairs(rw) do
    local l = by_host[w.host]
    if not l then l = {}; by_host[w.host] = l end
    l[#l + 1] = path
  end
  for label, plist in pairs(by_host) do
    local h = get_host(label)
    local c = h.conn
    if c and c.state == "ready" then
      -- events newer than each watch's cursor
      local dirty = {}   -- path -> "event" | "poll"
      local last_seq = h.seq
      local first_seq = h.evlog[1] and h.evlog[1].seq or (last_seq + 1)
      for _, path in ipairs(plist) do
        local w = rw[path]
        if w and w.cursor < last_seq then
          local overflow = w.cursor < first_seq - 1
          local hit = false
          for _, ev in ipairs(h.evlog) do
            if ev.seq > w.cursor then
              if ev.overflow then overflow = true
              elseif (w.dir and ev.dir == w.rpath) or (not w.dir and ev.dir == Cache.parent(w.rpath)) then
                hit = true
              end
            end
          end
          w.cursor = last_seq
          if overflow then dirty[path] = "overflow" elseif hit then dirty[path] = "event" end
        end
      end
      -- without server watches fall back to polling every stat_ttl_nowatch seconds
      if not h.watch_ok or h.watch_truncated then
        local last = h.last_poll or 0
        if t - last >= options.get("stat_ttl_nowatch", label) then
          h.last_poll = t
          for _, path in ipairs(plist) do dirty[path] = dirty[path] or "poll" end
        end
      end
      for path, why in pairs(dirty) do
        local w = rw[path]
        if w then
          if (why == "event" or why == "overflow") and w.dir then
            -- the server reports a directory only when its entries changed
            -- (and an overflow means "anything may have changed")
            w.etag = fresh_etag(h, w.rpath) or w.etag
            cb(path)
            changed = true
          else
            local et = fresh_etag(h, w.rpath)
            if et ~= nil and et ~= w.etag then
              w.etag = et
              cb(path)
              changed = true
            end
          end
        end
      end
    end
  end
  return changed
end

---------------------------------------------------------------------------
-- process.start through the server's exec
---------------------------------------------------------------------------

local RemoteProc = {}
RemoteProc.__index = RemoteProc

local function rewrite_text(text, rewrites, keep_tail)
  -- maps remote absolute paths back to mount paths; operates on whole lines,
  -- a trailing partial line is returned separately
  local tail = ""
  if keep_tail then
    -- (the plain find first: ".*()\n" is quadratic on a long text without newline)
    local last = text:find("\n", 1, true) and text:match(".*()\n")
    if last then tail = text:sub(last + 1); text = text:sub(1, last)
    elseif #text <= 4096 then return "", text end
    -- (no newline for 4 KiB: not a path list, stop holding data back)
  end
  for _, rw in ipairs(rewrites) do
    local R, M = rw.remote, rw.mount
    local out, pos = {}, 1
    while true do
      local s, e = text:find(R, pos, true)
      if not s then break end
      local nc = text:sub(e + 1, e + 1)
      if nc == "/" or nc == "" or nc == "\n" or nc == ":" or nc == " " or nc == "\r" or nc == "\0" then
        out[#out + 1] = text:sub(pos, s - 1)
        out[#out + 1] = M
        pos = e + 1
        if WIN and nc == "/" then
          local line_end = text:find("[\n%z]", pos) or (#text + 1)
          local seg = text:sub(pos, line_end - 1)
          local colon = seg:find(":%d")
          local path_part = colon and seg:sub(1, colon - 1) or seg
          out[#out + 1] = path_part:gsub("/", "\\")
          pos = pos + #path_part
        end
      else
        out[#out + 1] = text:sub(pos, e)
        pos = e + 1
      end
    end
    out[#out + 1] = text:sub(pos)
    text = table.concat(out)
  end
  return text, tail
end

local function new_remote_proc(h, conn, argv, opts, rewrites)
  local self = setmetatable({
    conn = conn, host = h, out = { stdout = {}, stderr = {} }, tail = { stdout = "", stderr = "" },
    tail_since = { stdout = 0, stderr = 0 },
    rewrites = rewrites, exited = false, consumed = 0, window = opts.window or options.get("exec_window", h.label),
  }, RemoteProc)
  return self
end

function RemoteProc:_on_event(m)
  if m.ev == "stdout" or m.ev == "stderr" then
    local name = m.ev
    local data = m.data
    if self.rewrites and #self.rewrites > 0 then
      local text, tail = rewrite_text(self.tail[name] .. data, self.rewrites, true)
      self.tail[name] = tail
      self.tail_since[name] = now()
      data = text
    end
    if #data > 0 then
      local l = self.out[name]
      l[#l + 1] = data
      self.raw_in = (self.raw_in or 0) + #m.data
    else
      self.raw_in = (self.raw_in or 0) + #m.data   -- all held back in tail; still account for acks
    end
  elseif m.ev == "exit" then
    self.exited = true
    self.exit_code = m.code
    self.killed = m.killed
    -- release held-back partial lines
    for _, name in ipairs({ "stdout", "stderr" }) do
      if self.tail[name] ~= "" then
        local text = rewrite_text(self.tail[name], self.rewrites or {}, false)
        local l = self.out[name]
        l[#l + 1] = text
        self.tail[name] = ""
      end
    end
  end
end

local function release_stale_tail(self, name)
  local tail = self.tail[name]
  if tail ~= "" and now() - self.tail_since[name] > 0.1 then
    local text = rewrite_text(tail, self.rewrites or {}, false)
    local l = self.out[name]
    l[#l + 1] = text
    self.tail[name] = ""
  end
end

--- raw read(fd, n): "" = nothing yet, nil = end of stream
function RemoteProc:read(fd, n)
  local name = fd == process.STREAM_STDERR and "stderr" or "stdout"
  if self.conn.state ~= "ready" and self.conn.state ~= "connecting" and not self.exited then
    -- connection lost: surface it as exit
    self:_on_event({ ev = "exit", code = -1, killed = true })
  end
  self.conn:poll()
  local l = self.out[name]
  if #l == 0 then release_stale_tail(self, name) end
  if #l == 0 then
    if self.exited and self.tail[name] == "" then return nil end
    return ""
  end
  local s = table.concat(l)
  if #s > n then
    self.out[name] = { s:sub(n + 1) }
    s = s:sub(1, n)
  else
    self.out[name] = {}
  end
  self.consumed = self.consumed + #s
  -- flow control: acknowledge once everything delivered so far was consumed
  if self.stream_id and self.window > 0 and not self.exited
     and #self.out.stdout == 0 and #self.out.stderr == 0 then
    local avail = self.raw_in or 0
    local acked = self.acked or 0
    if avail > acked then
      self.acked = avail
      self.conn:notify("ack", { stream = self.stream_id, n = avail - acked })
    end
  end
  return s
end

function RemoteProc:read_stdout(n) return self:read(process.STREAM_STDOUT, n or 65536) end
function RemoteProc:read_stderr(n) return self:read(process.STREAM_STDERR, n or 65536) end

function RemoteProc:write(data)
  if self.exited or self.stdin_closed or not self.stream_id then
    error("cannot write to child process: stream closed", 2)
  end
  local pos = 1
  while pos <= #data do
    local piece = data:sub(pos, pos + 262143)
    self.conn:notify("stdin", { stream = self.stream_id, data = require("core.remote.msgpack").bin(piece) })
    pos = pos + #piece
  end
  return #data
end

function RemoteProc:close_stream(fd)
  if fd == process.STREAM_STDIN and not self.stdin_closed and self.stream_id then
    self.stdin_closed = true
    self.conn:notify("stdin_close", { stream = self.stream_id })
  end
  return true
end

function RemoteProc:pid() return self.remote_pid end

function RemoteProc:running()
  if not self.exited and self.conn.state ~= "ready" and self.conn.state ~= "connecting" then
    self:_on_event({ ev = "exit", code = -1, killed = true })
  end
  if not self.exited then self.conn:poll() end
  return not self.exited
end

function RemoteProc:returncode()
  if self:running() then return nil end
  return self.exit_code
end

function RemoteProc:wait(timeout)
  timeout = timeout or 0
  local deadline = timeout == process.WAIT_INFINITE and math.huge or (now() + timeout / 1000)
  while self:running() do
    if now() >= deadline then return nil end
    if timeout == 0 then return nil end
    system.sleep(0.001)
  end
  return self.exit_code
end

local function send_signal(self, sig)
  if self.stream_id and not self.exited then
    self.conn:notify("kill", { stream = self.stream_id, signal = sig })
  end
  return true
end
function RemoteProc:terminate() return send_signal(self, "term") end
function RemoteProc:kill() return send_signal(self, "kill") end
function RemoteProc:interrupt() return send_signal(self, "int") end

--- Translates one argv element: a mount path, or `--opt=<mount path>`.
local function translate_arg(a, rewrites, host_ref)
  if type(a) ~= "string" then return a end
  local prefix, path = "", a
  if not paths.is_remote(a) then
    local p, rest = a:match("^(%-%-?[%w_-]+=)(.+)$")
    if p and paths.is_remote(rest) then prefix, path = p, rest else return a end
  end
  local label, rpath = parse(path)
  if not label then return a end
  host_ref.label = host_ref.label or label
  if host_ref.label ~= label then return a end
  rewrites[#rewrites + 1] = { remote = rpath, mount = paths.make(label, rpath) }
  return prefix .. rpath
end

--- Starts `argv` on the server for host label; returns a process object that
--- behaves like core.process (stdout/stderr/stdin streams, wait, ...).
function vfs.exec(label, argv, opts)
  opts = opts or {}
  local h = get_host(label)
  local c, err = ensure_conn(h)
  if not c then error("cannot run " .. tostring(argv[1]) .. " on " .. label .. ": " .. tostring(err and err.msg), 2) end
  local rewrites = opts.rewrites
  local raw = new_remote_proc(h, c, argv, opts, rewrites)
  local args = { argv = argv, cwd = opts.cwd, env = opts.env, stdin = opts.stdin ~= false,
                 merge_stderr = opts.merge_stderr or false, window = raw.window }
  local res, e = c:call("exec", args, 20)
  if not res then
    error("cannot run " .. tostring(argv[1]) .. " on " .. label .. ": " .. tostring(e and (e.msg or e.code)), 2)
  end
  raw.stream_id = res.stream
  raw.remote_pid = res.pid
  c.streams[res.stream] = function(m) raw:_on_event(m) end
  local early = c.early[res.stream]
  if early then
    c.early[res.stream] = nil
    for _, m in ipairs(early) do raw:_on_event(m) end
  end
  if opts.stdin == false then raw.stdin_closed = true end
  return raw
end

local function is_remote_arg(a)
  if type(a) ~= "string" then return false end
  if paths.is_remote(a) then return true end
  local p, rest = a:match("^(%-%-?[%w_-]+=)(.+)$")
  return p ~= nil and paths.is_remote(rest)
end

--- True if process.start(command, options) must run on a server.
function vfs.wants_exec(command, options_)
  if options_ and type(options_.cwd) == "string" and paths.is_remote(options_.cwd) then return true end
  if type(command) == "table" then
    for _, a in ipairs(command) do
      if is_remote_arg(a) then return true end
    end
  elseif type(command) == "string" and paths.is_remote(command) then
    return true
  end
  return false
end

--- Replacement for process.start for remote paths. `wrap(raw)` turns the raw
--- process into the object returned to the caller.
function vfs.process_start(command, options_, wrap)
  options_ = options_ or {}
  local argv = type(command) == "table" and command or { command }
  local host_ref = {}
  local rewrites = {}
  local cwd = options_.cwd
  if cwd and paths.is_remote(cwd) then
    local label, rpath = parse(cwd)
    host_ref.label = label
    cwd = rpath
    if options.get("rewrite_output", label) then
      rewrites[#rewrites + 1] = { remote = rpath, mount = paths.make(label, rpath) }
    end
  elseif cwd then
    cwd = nil   -- a local cwd means nothing on the server
  end
  local new_argv = {}
  local arg_rewrites = {}
  for i, a in ipairs(argv) do new_argv[i] = translate_arg(a, arg_rewrites, host_ref) end
  local label = host_ref.label
  if options.get("rewrite_output", label) then
    for _, r in ipairs(arg_rewrites) do rewrites[#rewrites + 1] = r end
  end
  -- longest remote prefix first so nested roots map correctly
  table.sort(rewrites, function(a, b) return #a.remote > #b.remote end)
  local env
  if type(options_.env) == "table" then
    env = {}
    for k, v in pairs(options_.env) do env[k] = tostring(v) end
  end
  local stdin_flag = options_.stdin ~= process.REDIRECT_DISCARD
  local merge = options_.stderr == process.REDIRECT_STDOUT
  local raw = vfs.exec(label, new_argv, { cwd = cwd, env = env, stdin = stdin_flag,
    merge_stderr = merge, rewrites = rewrites })
  return wrap(raw)
end

---------------------------------------------------------------------------

--- Disconnects every host (user command / shutdown).
function vfs.disconnect(label)
  local h = hosts[label]
  if h and h.conn then h.conn:close("disconnected by user") end
end

return vfs
