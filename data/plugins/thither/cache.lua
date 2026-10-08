--- stat / readdir cache of one remote host. Entries live `ttl()` seconds and
--- are dropped earlier when a watch event reports the directory changed or
--- when this client changes something itself. Keys are POSIX paths on the
--- server (never mount-root paths).
local Cache = {}
Cache.__index = Cache

local function now() return system.get_time() end

local function parent(p)
  return p:match("^(.*)/[^/]+$") or "/"
end
Cache.parent = parent

--- `ttl` is a function returning the current lifetime in seconds.
function Cache.new(ttl)
  return setmetatable({ ttl = ttl, stat = {}, dirs = {}, children = {} }, Cache)
end

function Cache:clear()
  self.stat, self.dirs, self.children = {}, {}, {}
end

--- Returns the cached entry for `path`: nil (unknown), false (known to be
--- missing) or the raw stat table of the server.
function Cache:get_stat(path)
  local e = self.stat[path]
  if not e then return nil end
  if now() - e.t > self.ttl() then
    self.stat[path] = nil
    return nil
  end
  if e.missing then return false end
  return e.raw
end

local function link_child(self, path)
  local dir = parent(path)
  local set = self.children[dir]
  if not set then set = {}; self.children[dir] = set end
  set[path] = true
end

function Cache:put_stat(path, raw)
  if raw then
    self.stat[path] = { t = now(), raw = raw }
  else
    self.stat[path] = { t = now(), missing = true }
  end
  link_child(self, path)
end

--- Names (array) of a cached directory listing, or nil.
function Cache:get_dir(path)
  local e = self.dirs[path]
  if not e then return nil end
  if now() - e.t > self.ttl() then
    self.dirs[path] = nil
    return nil
  end
  return e.names
end

--- Stores a listing; `entries` are the server's stat tables with `name`.
function Cache:put_dir(path, entries)
  local names = {}
  local t = now()
  local prefix = path == "/" and "/" or (path .. "/")
  for i, ent in ipairs(entries) do
    names[i] = ent.name
    local p = prefix .. ent.name
    self.stat[p] = { t = t, raw = ent }
    link_child(self, p)
  end
  self.dirs[path] = { t = t, names = names }
  link_child(self, path)
end

--- Forgets a directory: its listing, its own stat and the stats of its entries.
function Cache:invalidate_dir(path)
  self.dirs[path] = nil
  self.stat[path] = nil
  local set = self.children[path]
  if set then
    for p in pairs(set) do self.stat[p] = nil end
    self.children[path] = nil
  end
end

--- Forgets one path and the listing of its parent (after create/remove/write).
function Cache:invalidate_path(path)
  self.stat[path] = nil
  self.dirs[parent(path)] = nil
  self.dirs[path] = nil
  local set = self.children[path]
  if set then
    for p in pairs(set) do self.stat[p] = nil end
    self.children[path] = nil
  end
end

return Cache
