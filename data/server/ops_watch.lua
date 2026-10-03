-- watch ops: watch, unwatch.
--
-- watch { path, recursive = false, debounce_ms = 50, max_pending = 1024 }
--   -> { watch = <id>, dirs = <number of directories watched>, truncated = <bool> }
-- Events (coalesced over `debounce_ms`):
--   { ev = "watch",    watch = id, paths = { <changed directory>, ... } }
--   { ev = "overflow", watch = id }
-- The inotify/kqueue backends report which watched directory changed, not
-- which entry, so `paths` lists directories the client should re-scan (or
-- re-stat). "overflow" means events were lost or too many directories changed
-- within one window (> max_pending): rescan the whole watched tree.
local serverfs = require "serverfs"

return function(server)
  local ops = server.ops
  local raise = server.raise

  local MAX_DIRS = 8192

  local monitor
  local wds = {}      -- backend id -> { path = <dir>, watches = { [watch id] = true } }
  local watches = {}  -- watch id -> state
  local nwatches, next_id = 0, 1

  local function add_dir(w, dir)
    if w.ndirs >= MAX_DIRS then w.truncated = true return false end
    local wd = monitor:watch(dir)
    if type(wd) ~= "number" or wd < 0 then
      w.truncated = true
      return false
    end
    local info = wds[wd]
    if not info then info = { path = dir, watches = {} }; wds[wd] = info end
    info.watches[w.id] = true
    if not w.dirs[dir] then w.ndirs = w.ndirs + 1 end
    w.dirs[dir] = wd
    return true
  end

  local function add_tree(w, dir)
    local queue, qi = { dir }, 1
    while queue[qi] do
      local d = queue[qi]
      qi = qi + 1
      if not w.dirs[d] then add_dir(w, d) end
      if w.dirs[d] then
        local entries = serverfs.readdir(d, 0, 100000)
        for _, e in ipairs(entries or {}) do
          if e.type == "dir" and not e.is_link then
            queue[#queue + 1] = (d == "/" and "" or d) .. "/" .. e.name
          end
        end
      end
    end
  end

  ops.watch = function(a)
    local path = server.path(a.path)
    local st = server.unwrap(serverfs.stat(path))
    if not monitor then monitor = dirmonitor.new() end
    local id = next_id
    next_id = next_id + 1
    local w = {
      id = id, root = path, recursive = a.recursive and true or false,
      debounce = (tonumber(a.debounce_ms) or 50) / 1000,
      max_pending = math.max(1, math.tointeger(a.max_pending) or 1024),
      dirs = {}, ndirs = 0, pending = {}, npending = 0, overflow = false, truncated = false,
    }
    watches[id] = w
    nwatches = nwatches + 1
    if w.recursive and st.type == "dir" then add_tree(w, path) else add_dir(w, path) end
    if w.ndirs == 0 then
      watches[id] = nil
      nwatches = nwatches - 1
      raise("watch_failed", "cannot watch " .. path .. " (is the inotify watch limit reached?)")
    end
    return { watch = id, dirs = w.ndirs, truncated = w.truncated }
  end

  ops.unwatch = function(a)
    local w = watches[a.watch]
    if not w then return true end
    for dir, wd in pairs(w.dirs) do
      local info = wds[wd]
      if info then
        info.watches[w.id] = nil
        if next(info.watches) == nil then
          monitor:unwatch(wd)
          wds[wd] = nil
        end
      end
    end
    watches[w.id] = nil
    nwatches = nwatches - 1
    return true
  end

  local function note(w, dir, now)
    if w.overflow then return end
    if w.recursive then
      -- a new subdirectory may have appeared: watch it too
      local entries = serverfs.readdir(dir, 0, 100000)
      for _, e in ipairs(entries or {}) do
        if e.type == "dir" and not e.is_link then
          local sub = (dir == "/" and "" or dir) .. "/" .. e.name
          if not w.dirs[sub] then add_tree(w, sub) end
        end
      end
    end
    if not w.pending[dir] then
      w.pending[dir] = true
      w.npending = w.npending + 1
      if w.npending > w.max_pending then
        w.overflow = true
        w.pending, w.npending = {}, 0
      end
    end
    w.first_at = w.first_at or now
  end

  local function note_path(w, path, now)
    -- "single" mode backends (fsevents) report paths
    local root = w.root
    if path == root or path:sub(1, #root + 1) == root .. "/" then note(w, path, now) end
  end

  table.insert(server.tickers, function()
    if nwatches == 0 then return nil end
    local changed = {}
    monitor:check(function(id)
      changed[#changed + 1] = id
      return true
    end, function(err) server.log("dirmonitor error: %s", tostring(err)) end)
    local now = system.get_time()
    for _, id in ipairs(changed) do
      if type(id) == "number" and id < 0 then
        for _, w in pairs(watches) do
          w.overflow = true
          w.pending, w.npending = {}, 0
          w.first_at = w.first_at or now
        end
      elseif type(id) == "number" then
        local info = wds[id]
        if info then
          for wid in pairs(info.watches) do
            local w = watches[wid]
            if w then note(w, info.path, now) end
          end
        end
      elseif type(id) == "string" then
        for _, w in pairs(watches) do note_path(w, id, now) end
      end
    end
    local hint = 20
    for _, w in pairs(watches) do
      if w.first_at then
        local due = w.first_at + w.debounce
        if now >= due then
          if w.overflow then
            server.send({ ev = "overflow", watch = w.id })
          else
            local paths = {}
            for p in pairs(w.pending) do paths[#paths + 1] = p end
            table.sort(paths)
            server.send({ ev = "watch", watch = w.id, paths = paths })
          end
          w.pending, w.npending, w.overflow, w.first_at = {}, 0, false, nil
        else
          hint = math.min(hint, math.max(1, math.ceil((due - now) * 1000)))
        end
      end
    end
    return hint
  end)
end
