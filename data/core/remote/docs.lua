--- Remote documents: small files (ordinary Doc through the shimmed io.open,
--- etag checked save) and remote large files (lazy remote buffer, fetch pump,
--- edit-script save, server search). See docs/remote-client.md.
local paths = require "core.remote.paths"
local vfs = require "core.remote.vfs"
local options = require "core.remote.options"
local msgpack = require "core.remote.msgpack"
local Conn = require "core.remote.client"
local Cache = require "core.remote.cache"

local docs = {}

local parse = paths.parse
local function now() return system.get_time() end

local function core() return require "core" end
local function config() return require "core.config" end

local function log(level, fmt, ...)
  local c = core()
  if c[level] then
    if pcall(c[level], fmt, ...) then return end
  end
  io.stderr:write(string.format(fmt, ...) .. "\n")
end

local function redraw() core().redraw = true end

--- Documents with a remote state, host label -> weak set.
docs.active = setmetatable({}, { __mode = "k" })

local MAX_INFLIGHT = 6
local PREFETCH = 2
local ONE_FRAME_INSERTS = 8 * 1024 * 1024

---------------------------------------------------------------------------
-- Errors
---------------------------------------------------------------------------

local Conflict = {}
Conflict.__index = Conflict
Conflict.__tostring = function(e) return e.msg end

local function conflict_error(doc, msg, extra)
  local e = setmetatable({ remote_conflict = true, doc = doc, msg = msg }, Conflict)
  if extra then for k, v in pairs(extra) do e[k] = v end end
  return e
end

local function nag(title, message, opts, cb)
  local c = core()
  if c.nag_view then
    c.nag_view:show(title, message, opts, cb)
  else
    log("warn", "%s: %s", title, message)
  end
end

---------------------------------------------------------------------------
-- Common state
---------------------------------------------------------------------------

local function compute_offsets(chunks)
  local offsets, off = {}, 0
  for i, c in ipairs(chunks) do
    offsets[i] = off
    off = off + c[1]
  end
  return offsets, off
end

local function detect_crlf(data)
  local nl = data:find("\n", 1, true)
  if not nl then return nil end
  return data:sub(nl - 1, nl - 1) == "\r" or nil
end

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------

local pump_started = false
local function ensure_pump()
  if pump_started then return end
  local c = core()
  if not (c.add_thread and c.threads) then return end
  pump_started = true
  docs.pump_thread = c.add_thread(function() docs.pump_loop() end)
end

local search_installed = false
local function install_search()
  if search_installed then return end
  search_installed = true
  local search = require "core.doc.search"
  local orig = search.find
  docs.orig_search_find = orig
  search.find = function(doc, line, col, text, opt)
    local r = doc.remote
    if r and r.large then return docs.find(doc, line, col, text, opt) end
    return orig(doc, line, col, text, opt)
  end
end

--- Fetches bytes of a chunk synchronously (explicit actions only; used as
--- the sync_fn of buffer:get_text, so it must never yield).
local function make_sync_fn(doc, r)
  return function(idx, off, len)
    local data, err = r.conn:call("read_range",
      { path = r.rpath, off = off, len = len, etag = r.etag }, 60, { noyield = true })
    if not data then
      if err and err.code == "stale" then docs.mark_stale(doc, "file changed on the server") end
      error(err and (err.msg or err.code) or "read failed", 0)
    end
    return data
  end
end

function docs.release(doc)
  local r = doc.remote
  if not r then return end
  r.released = true
  if r.large and r.conn then
    for _, req in pairs(r.inflight or {}) do r.conn:cancel(req.id) end
  end
  r.inflight, r.ninflight = {}, 0
  docs.active[doc] = nil
  doc.remote = nil
end

--- Remote branch of Doc:load. Returns true when the document was loaded
--- here (large file); false to continue with the ordinary path.
function docs.load(doc, filename)
  local label, rpath = parse(filename)
  if not label then return false end
  -- the current remote state is kept until the new one is ready: a failed
  -- (re)load must leave a working document behind (Doc:load releases it
  -- before an ordinary load)
  local h = vfs.get_host(label)
  local raw, err = vfs.stat_raw(h, rpath, true)
  if not raw or raw.type ~= "file" then return false end
  local cfg = config()
  local threshold = (cfg.large_file_threshold_mb or 10) * 1e6
  if raw.size < threshold then return false end
  local conn = vfs.conn_for(label)
  if not conn or not conn.caps or not conn.caps.large_file then return false end

  local chunk_size = options.get("chunk_size", label)
  local idx, ierr = conn:call("lineindex", { path = rpath, chunk_size = chunk_size }, 180)
  if not idx and ierr and ierr.code == "too_large" and ierr.min_chunk_size then
    chunk_size = ierr.min_chunk_size
    idx, ierr = conn:call("lineindex", { path = rpath, chunk_size = chunk_size }, 180)
  end
  if not idx then
    error(vfs.errmsg(filename, ierr), 0)
  end
  local buffer = require "buffer"
  local budget = options.get("cache_budget_mb", label) * 1024 * 1024
  local buf = buffer.open_remote({ size = idx.size, chunks = idx.chunks,
    ends_with_nl = idx.ends_with_nl, chunk_size = chunk_size, budget = budget })

  local r = {
    large = true, host = h, label = label, rpath = rpath, path = filename, conn = conn,
    etag = idx.etag, size = idx.size, chunk_size = chunk_size, chunks = idx.chunks,
    inflight = {}, ninflight = 0, fail_until = {}, fail_count = {}, have = {}, nhave = 0,
    demand = {}, dir = 1, last_demand = 1, gen = (doc.remote_gen or 0) + 1,
    ends_with_nl = idx.ends_with_nl,
  }
  doc.remote_gen = r.gen
  r.offsets = compute_offsets(r.chunks)
  r.sync_fn = make_sync_fn(doc, r)
  h.etags[rpath] = idx.etag

  -- the first chunk right away: CRLF detection and the first screen
  local crlf
  if #idx.chunks > 0 then
    local first, ferr = conn:call("read_range",
      { path = rpath, off = 0, len = idx.chunks[1][1], etag = idx.etag }, 60)
    if not first then error(vfs.errmsg(filename, ferr), 0) end
    local ok, e = buf:supply(1, first)
    if not ok then error("remote: first chunk rejected: " .. tostring(e), 0) end
    r.have[1], r.nhave = true, 1
    crlf = detect_crlf(first)
  end

  if doc.remote then docs.release(doc) end
  doc:reset()
  doc.buffer = buf
  doc.lines = buf
  doc.crlf = crlf
  doc.large_file = true
  doc.remote = r
  doc.highlighter:soft_reset()
  doc:reset_syntax()
  docs.active[doc] = true
  install_search()
  ensure_pump()
  core().log_quiet("Document \"%s\" opened as remote large file (%d lines, %.1f MB, %d chunks)",
    doc:get_name(), #buf, idx.size / 1e6, #idx.chunks)
  return true
end

--- Called by Doc:load after an ordinary (in-memory) load of a remote path.
function docs.loaded_small(doc, filename)
  local label, rpath = parse(filename)
  if not label then return end
  local h = vfs.get_host(label)
  doc.remote = { small = true, host = h, label = label, rpath = rpath, path = filename,
                 etag = h.etags[rpath] }
  docs.active[doc] = true
end

---------------------------------------------------------------------------
-- Fetch pump
---------------------------------------------------------------------------

local function backoff(r, idx)
  local n = (r.fail_count[idx] or 0) + 1
  r.fail_count[idx] = n
  r.fail_until[idx] = now() + math.min(10, 0.5 * 2 ^ (n - 1))
end

local function send_fetch(doc, r, idx, prefetch)
  local conn = r.conn
  local buf = doc.buffer
  local c = r.chunks[idx]
  local off, len = r.offsets[idx], c[1]
  local gen = r.gen
  local req = { prefetch = prefetch, t = now(), idx = idx }
  r.inflight[idx] = req
  r.ninflight = r.ninflight + 1
  local id = conn:request("read_range", { path = r.rpath, off = off, len = len, etag = r.etag },
    function(data, err)
      if r.gen ~= gen or r.released or doc.buffer ~= buf then return end
      if r.inflight[idx] == req then
        r.inflight[idx] = nil
        r.ninflight = r.ninflight - 1
      end
      if data then
        local ok, e = buf:supply(idx, data)
        if ok then
          if not r.have[idx] then r.have[idx] = true; r.nhave = r.nhave + 1 end
          r.fail_count[idx] = nil
          redraw()
        else
          buf:cancel(idx)
          if e ~= "stale" then
            backoff(r, idx)
            log("warn", "remote: chunk %d rejected: %s", idx, tostring(e))
          end
        end
      else
        buf:cancel(idx)
        if err and err.code == "stale" then
          docs.mark_stale(doc, "file changed on the server")
        elseif not (err and (err.code == "cancelled" or err.code == "disconnected")) then
          backoff(r, idx)
          log("warn", "remote: reading %s failed: %s", doc:get_name(), tostring(err and (err.msg or err.code)))
        end
      end
    end)
  req.id = id
  if not id then
    -- request failed synchronously (callback already ran)
    return false
  end
  return true
end

local function pump_doc(doc, r)
  local buf = doc.buffer
  if not buf or r.released or r.saving then return false end
  local conn = r.conn
  if conn.state ~= "ready" or r.stale then return false end
  local busy = false

  -- forget residency knowledge once the engine evicted something
  local t = now()
  if t - (r.stats_t or 0) > 2 then
    r.stats_t = t
    local st = buf:stats()
    if st.resident < r.nhave then r.have, r.nhave = {}, 0 end
  end

  -- everything drained from missing() is either requested, owned by an
  -- in-flight request, or cancelled
  local miss = buf:missing(64)
  if #miss > 0 then
    busy = true
    -- a new demand batch supersedes unsent ones of earlier batches
    for _, d in ipairs(r.demand) do
      if not r.inflight[d.idx] then buf:cancel(d.idx) end
    end
    r.demand = {}
    local lo
    for _, m in ipairs(miss) do
      local idx = m[1]
      if r.inflight[idx] then
        local req = r.inflight[idx]
        req.prefetch = false   -- demanded now
      elseif (r.fail_until[idx] or 0) > t then
        buf:cancel(idx)
      else
        r.demand[#r.demand + 1] = { idx = idx }
        lo = lo and math.min(lo, idx) or idx
      end
    end
    if lo then
      local dir = lo > r.last_demand and 1 or (lo < r.last_demand and -1 or r.dir)
      r.dir, r.last_demand = dir, lo
      -- demand is served newest (highest priority) first: nearest to the end of the scroll
      table.sort(r.demand, function(a, b)
        if dir > 0 then return a.idx < b.idx else return a.idx > b.idx end
      end)
      -- cancel in-flight work that is far from what is wanted now
      if r.ninflight >= MAX_INFLIGHT then
        for idx, req in pairs(r.inflight) do
          if math.abs(idx - lo) > 8 then
            conn:cancel(req.id)
            r.inflight[idx] = nil
            r.ninflight = r.ninflight - 1
            buf:cancel(idx)
          end
        end
      end
    end
  end

  -- send demand
  while #r.demand > 0 and r.ninflight < MAX_INFLIGHT do
    local d = table.remove(r.demand, 1)
    busy = true
    if not r.inflight[d.idx] then
      if not send_fetch(doc, r, d.idx, false) then buf:cancel(d.idx) end
    end
  end

  -- prefetch in the scroll direction when idle
  if #r.demand == 0 and r.ninflight < MAX_INFLIGHT / 2 and r.last_demand then
    local base = r.last_demand
    for step = 1, PREFETCH do
      local i = base + r.dir * step
      if i >= 1 and i <= #r.chunks and not r.have[i] and not r.inflight[i]
         and (r.fail_until[i] or 0) <= t and r.ninflight < MAX_INFLIGHT / 2 then
        busy = true
        send_fetch(doc, r, i, true)
      end
    end
    -- a prefetch round is done once; remember so we do not repeat it forever
    r.last_demand_done = base
  end
  return busy or r.ninflight > 0
end

function docs.pump_loop()
  while true do
    local busy = false
    for doc in pairs(docs.active) do
      local r = doc.remote
      if r and r.large then
        local ok, res = pcall(pump_doc, doc, r)
        if ok then busy = busy or res
        else log("warn", "remote: fetch pump failed: %s", tostring(res)) end
      end
    end
    coroutine.yield(busy and 0.008 or 0.025)
  end
end

--- Runs one pump round for `doc` (tests).
function docs.pump_once(doc)
  local r = doc.remote
  if r and r.large then return pump_doc(doc, r) end
end

---------------------------------------------------------------------------
-- Stale / changed on the server
---------------------------------------------------------------------------

function docs.mark_stale(doc, why)
  local r = doc.remote
  if not r or r.stale or r.released then return end
  r.stale = true
  if doc.buffer and doc.buffer.set_stale then doc.buffer:set_stale(true) end
  redraw()
  nag("File Changed on Server",
    string.format("%s: %s. Editing is blocked until the file is reloaded.", doc:get_name(), why),
    { { text = "Reload", default_yes = true }, { text = "Keep", default_no = true } },
    function(item)
      if item.text == "Reload" then
        core().add_thread(function() docs.reload(doc) end)
      end
    end)
end

function docs.reload(doc)
  local ok, err = pcall(doc.reload, doc)
  if ok then
    log("log", "Reloaded %s", doc:get_name())
  else
    log("error", "remote: reload failed: %s", tostring(err))
  end
  redraw()
end

--- A stat of the file says it differs from what the document is based on.
function docs.file_changed(doc, raw)
  local r = doc.remote
  if not r or r.released or r.saving then return end
  if r.nagged == raw.etag then return end
  r.nagged = raw.etag
  if r.large then
    docs.mark_stale(doc, "file changed on the server")
  else
    if not doc:is_dirty() then
      core().add_thread(function() docs.reload(doc) end)
    else
      nag("File Changed", doc.filename .. " has changed on the server. Reload this file?", {
        { text = "Yes", default_yes = true }, { text = "No", default_no = true } },
        function(item)
          if item.text == "Yes" then core().add_thread(function() docs.reload(doc) end) end
        end)
    end
  end
end

local function check_doc(doc, r)
  local conn = r.conn or (vfs.get_host(r.label).conn)
  if not conn or conn.state ~= "ready" then return end
  local seq = r.save_seq
  conn:request("stat", { path = r.rpath }, function(raw, err)
    if not raw or doc.remote ~= r then return end
    -- a stat that raced with a save of ours says nothing about foreign changes
    if r.saving or r.save_seq ~= seq then return end
    r.host.cache:put_stat(r.rpath, raw)
    local known = r.etag or r.host.etags[r.rpath]
    if known and raw.etag ~= known then docs.file_changed(doc, raw) end
  end)
end

--- Server watch event: directories changed (nil = everything, after overflow).
function docs.on_dirs_changed(h, dirs)
  local set
  if dirs then
    set = {}
    for _, d in ipairs(dirs) do set[d] = true end
  end
  for doc in pairs(docs.active) do
    local r = doc.remote
    if r and r.label == h.label and not r.released then
      if not set or set[Cache.parent(r.rpath)] then check_doc(doc, r) end
    end
  end
end

--- Connection restored: revalidate every open document against the server.
function docs.on_reconnected(h)
  for doc in pairs(docs.active) do
    local r = doc.remote
    if r and r.label == h.label and not r.released then
      r.conn = h.conn
      -- chunks that were in flight died with the old connection
      if r.large then
        r.inflight, r.ninflight, r.demand = {}, 0, {}
        r.gen = r.gen + 1
        doc.remote_gen = r.gen
      end
      check_doc(doc, r)
    end
  end
end

---------------------------------------------------------------------------
-- Saving
---------------------------------------------------------------------------

local function doc_text(doc)
  local parts = {}
  -- a piece-tree buffer keeps the raw bytes: its lines already end in "\r\n"
  local crlf = doc.crlf and not doc.buffer
  for i = 1, #doc.lines do
    local line = doc.lines[i]
    if crlf then line = line:gsub("\n", "\r\n") end
    parts[i] = line
  end
  return table.concat(parts)
end

local function save_small(doc, abs_filename)
  -- one save at a time: a second one must use the etag the first one gets
  if doc.remote_saving then
    if not Conn.in_core_thread() then error("remote: a save of this file is still in progress", 0) end
    local deadline = now() + 120
    while doc.remote_saving and now() < deadline do coroutine.yield(0.01) end
    if doc.remote_saving then error("remote: a save of this file is still in progress", 0) end
  end
  local label, rpath = parse(abs_filename)
  local h = vfs.get_host(label)
  local r = doc.remote
  local same = r and r.rpath == rpath and r.label == label
  local force = doc.remote_force
  doc.remote_force = nil
  local if_match
  if force then
    if_match = nil
  elseif same and not doc.new_file then
    if_match = r.etag or h.etags[rpath]
  elseif doc.new_file and doc.abs_filename == abs_filename then
    if_match = "-"     -- the file must not exist yet
  end
  local data = doc_text(doc)
  doc.remote_saving = true
  local ok, res, err = pcall(vfs.write_file, h, rpath, data, { if_match = if_match })
  doc.remote_saving = nil
  if not ok then error(res, 0) end
  if not res then
    if err and err.code == "conflict" then
      error(conflict_error(doc, doc:get_name() .. " changed on the server since it was loaded",
        { etag = err.etag, small = true }), 0)
    end
    error(vfs.errmsg(abs_filename, err), 0)
  end
  doc.remote = { small = true, host = h, label = label, rpath = rpath, path = abs_filename, etag = res.etag }
  docs.active[doc] = true
  return res
end

local function same_shape(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then return false end
  end
  return true
end

local function upload_inserts(conn, inserts)
  local total = 0
  for _, s in ipairs(inserts) do total = total + #s end
  if total <= ONE_FRAME_INSERTS then
    local out = {}
    for i, s in ipairs(inserts) do out[i] = msgpack.bin(s) end
    return out
  end
  local out, ids = {}, {}
  for i, s in ipairs(inserts) do
    local id = string.format("lxc-%d-%d", math.floor(now() * 1000) % 1000000, i)
    ids[#ids + 1] = id
    local step = 4 * 1024 * 1024
    if #s == 0 then s = "" end
    for off = 1, math.max(#s, 1), step do
      local ok, err = conn:call("blob_put", { id = id, data = msgpack.bin(s:sub(off, off + step - 1)) }, 120)
      if not ok then
        for _, bid in ipairs(ids) do conn:call("blob_drop", { id = bid }) end
        return nil, err
      end
    end
    out[i] = { blob = id }
  end
  return out, nil, ids
end

local function adopt_result(doc, r, res)
  local buf = doc.buffer
  local ok, e = pcall(buf.rebase, buf, res.size, res.chunks, res.ends_with_nl)
  if not ok then
    log("error", "remote: cannot rebase %s (%s); reloading", doc:get_name(), tostring(e))
    return false
  end
  for _, req in pairs(r.inflight) do r.conn:cancel(req.id) end
  r.inflight, r.ninflight, r.demand = {}, 0, {}
  r.fail_until, r.fail_count = {}, {}
  r.have, r.nhave = {}, 0
  r.gen = r.gen + 1
  doc.remote_gen = r.gen
  r.chunks = res.chunks
  r.offsets, r.size = compute_offsets(res.chunks)
  r.etag = res.etag
  r.ends_with_nl = res.ends_with_nl
  r.stale = false
  r.nagged = nil
  r.host.etags[r.rpath] = res.etag
  r.host.cache:invalidate_path(r.rpath)
  r.ctext = nil
  redraw()
  return true
end

--- Waits (bounded) until the lines under the cursors are loaded, so typing
--- right after a save or reload is not refused while chunks are in flight.
function docs.make_resident(doc, timeout)
  local r = doc.remote
  local buf = doc.buffer
  if not (r and r.large and buf) then return end
  local lines = {}
  for _, l1, _, l2 in doc:get_selections() do
    lines[#lines + 1] = math.min(l1, #doc.lines)
    if #lines >= 8 then break end
  end
  local deadline = now() + timeout
  local yieldable = Conn.in_core_thread()
  local function all_ready()
    for _, l in ipairs(lines) do
      if not buf:is_resident(l, l) then
        local _ = doc.lines[l]          -- queues the chunk
        return false
      end
    end
    return true
  end
  while not all_ready() and now() < deadline do
    pump_doc(doc, r)
    r.conn:poll()
    if yieldable then coroutine.yield(0.002) else system.sleep(0.001) end
  end
  redraw()
end

local function save_large(doc, abs_filename)
  local r = doc.remote
  local buf = doc.buffer
  local conn = r.conn
  if r.saving then error("remote: save already in progress", 0) end
  if r.stale then
    error(conflict_error(doc, doc:get_name() .. " changed on the server and the buffer is stale",
      { large = true, stale = true }), 0)
  end
  local label, rpath = parse(abs_filename)
  local script, inserts = buf:edit_script()
  if not script then error("remote: cannot build the edit script: " .. tostring(inserts), 0) end
  local unchanged = #inserts == 0 and #script == 1 and script[1].keep
    and script[1].off == 0 and script[1].len == r.size
  local same = rpath == r.rpath and label == r.label
  if unchanged and same then return end
  if label ~= r.label then
    -- the edit script refers to the original file, which only that host has
    error("a remote large file can only be saved on the host it was opened from", 0)
  end

  r.saving = true
  r.save_seq = (r.save_seq or 0) + 1
  local function finish() r.saving = false; r.save_seq = r.save_seq + 1 end
  local ok, res_or_err = pcall(function()
    local ins, uerr, blob_ids = upload_inserts(conn, inserts)
    if not ins then error("upload failed: " .. tostring(uerr and (uerr.msg or uerr.code)), 0) end
    -- save as: the server reads the original and writes the edited file to
    -- `dest` in one pass (the original stays as it is)
    local res, err = conn:call("apply_edit", { path = r.rpath, etag = r.etag, script = script,
      inserts = ins, chunk_size = r.chunk_size, dest = not same and rpath or nil }, 600)
    if blob_ids then for _, bid in ipairs(blob_ids) do conn:call("blob_drop", { id = bid }) end end
    if not same then r.host.cache:invalidate_path(rpath) end
    if not res then
      if err and err.code == "conflict" then
        error(conflict_error(doc, doc:get_name() .. " changed on the server since it was loaded",
          { etag = err.etag, large = true }), 0)
      end
      error(vfs.errmsg(abs_filename, err), 0)
    end
    return res
  end)
  finish()
  if not ok then error(res_or_err, 0) end
  local res = res_or_err
  -- closed (or reloaded) while the save ran: the server has the new content,
  -- there is nothing left to rebase
  if r.released or doc.remote ~= r or doc.buffer ~= buf then return res end
  if not same then
    r.rpath, r.path = rpath, abs_filename
  end
  if not adopt_result(doc, r, res) then
    r.stale = true
    docs.reload(doc)
  else
    docs.make_resident(doc, 3)
  end
  return res
end

--- Remote branch of Doc:save (raises on failure; conflicts raise a table with
--- `remote_conflict = true`, see docs.conflict_nag).
function docs.save(doc, abs_filename)
  local r = doc.remote
  if r and r.large and doc.buffer then
    return save_large(doc, abs_filename)
  end
  if doc.buffer and doc.buffer:is_remote() then
    -- a remote buffer without its state: lines that are not loaded would be
    -- written as placeholders
    error("remote: " .. doc:get_name() .. " lost its server state; reload it before saving", 0)
  end
  return save_small(doc, abs_filename)
end

--- Shows the choices after a save conflict. `retry` re-runs the save.
function docs.conflict_nag(doc, err, retry)
  local r = doc.remote
  local opts = {
    { text = "Overwrite" },
    { text = "Reload", default_yes = true },
    { text = "Save As" },
    { text = "Cancel", default_no = true },
  }
  nag("Save Conflict", tostring(err) .. ".\nOverwrite the server version, reload it (discarding your changes), or save under another name?",
    opts, function(item)
      local c = core()
      if item.text == "Overwrite" then
        c.add_thread(function()
          if err.large then
            local ok, why = docs.large_overwrite(doc)
            if not ok then log("error", "remote: %s", tostring(why)); return end
          else
            doc.remote_force = true
          end
          if retry then retry() end
        end)
      elseif item.text == "Reload" then
        c.add_thread(function() docs.reload(doc) end)
      elseif item.text == "Save As" then
        c.add_thread(function()
          -- doc:save-as works on the active view: make it this document's
          local view = c.get_views_referencing_doc(doc)[1]
          if not view then return end
          if c.active_view ~= view and c.active_view.doc ~= doc then
            c.root_view.root_node:get_node_for_view(view):set_active_view(view)
          end
          require("core.command").perform("doc:save-as")
        end)
      end
    end)
end

--- "Overwrite" for a large document whose file changed on the server: only
--- possible when the new file has the same chunk structure (a touch or
--- metadata change), because the edit script refers to offsets of the old
--- content. Returns true or nil, reason.
function docs.large_overwrite(doc)
  local r = doc.remote
  local idx, err = r.conn:call("lineindex", { path = r.rpath, chunk_size = r.chunk_size }, 180)
  if not idx then return nil, vfs.errmsg(r.path, err) end
  local changed = "the file on the server has different content now; reload it (your edits cannot be applied to it)"
  if idx.size ~= r.size or idx.ends_with_nl ~= r.ends_with_nl or not same_shape(idx.chunks, r.chunks) then
    return nil, changed
  end
  -- The same chunk lengths and newline counts do not mean the same bytes: the
  -- edit script keeps ranges of the server file, so every chunk this buffer has
  -- loaded (what the user saw and edited around) must still hold what it held.
  -- Chunks never loaded were never seen, so the server's bytes are all there is.
  local buf = doc.buffer
  for _, i in ipairs(buf:loaded_chunks()) do
    local data, rerr = r.conn:call("read_range",
      { path = r.rpath, off = r.offsets[i], len = r.chunks[i][1], etag = idx.etag }, 60)
    if not data then return nil, vfs.errmsg(r.path, rerr) end
    if doc.remote ~= r or doc.buffer ~= buf then return nil, "the document was reloaded" end
    if not buf:chunk_matches(i, data) then return nil, changed end
  end
  r.etag = idx.etag
  r.stale = false
  if doc.buffer.set_stale then doc.buffer:set_stale(false) end
  return true
end

---------------------------------------------------------------------------
-- Server-side search
---------------------------------------------------------------------------

local function fetch_chunk_text(doc, r, i)
  r.ctext = r.ctext or {}
  for _, e in ipairs(r.ctext) do if e.i == i then return e.data end end
  local data, err = r.conn:call("read_range", { path = r.rpath, off = r.offsets[i],
    len = r.chunks[i][1], etag = r.etag }, 60)
  if not data then return nil, err end
  table.insert(r.ctext, 1, { i = i, data = data })
  if #r.ctext > 4 then table.remove(r.ctext) end
  return data
end

--- Byte offset in the original file of the start of 1-based `line`
--- (document without unsaved edits).
function docs.line_offset(doc, line)
  local r = doc.remote
  if line <= 1 then return 0 end
  local need = line - 1          -- offset is right after the need-th newline
  local before = 0
  for i, c in ipairs(r.chunks) do
    if before + c[2] >= need then
      local data, err = fetch_chunk_text(doc, r, i)
      if not data then return nil, err end
      local k, pos = need - before, 0
      for _ = 1, k do
        pos = data:find("\n", pos + 1, true)
        if not pos then return nil, "index mismatch" end
      end
      return r.offsets[i] + pos
    end
    before = before + c[2]
  end
  return r.size
end

local function server_search(doc, from, text, opt, limit)
  local r = doc.remote
  return r.conn:call("search", { path = r.rpath, pattern = text,
    opts = { regex = opt.regex and true or false, case = not opt.no_case, limit = limit },
    from_off = from, etag = r.etag }, 120)
end

--- Last match whose end is <= `limit` (a byte offset). Returns match | nil, err.
function docs.last_match(doc, limit, text, opt)
  local pos, last = 0, nil
  while true do
    local res, err = server_search(doc, pos, text, opt, 100000)
    if not res then return nil, err end
    if #res == 0 then break end
    local stop = false
    for _, m in ipairs(res) do
      if m.off + m.len <= limit then last = m else stop = true; break end
    end
    if stop or #res < 100000 then break end
    local lm = res[#res]
    pos = lm.off + lm.len
  end
  return last
end

--- Replacement of core.doc.search.find for remote large documents.
function docs.find(doc, line, col, text, opt)
  local r = doc.remote
  opt = opt or {}
  if opt.pattern then
    log("error", "Lua patterns are not supported on remote large files (use plain text or regex)")
    return
  end
  if r.stale then log("error", "%s is stale; reload it first", doc:get_name()); return end
  if doc:is_dirty() then
    log("error", "Save %s before searching it: remote large files are searched on the server", doc:get_name())
    return
  end
  line, col = doc:sanitize_position(line, col)
  local lo, lerr = docs.line_offset(doc, line)
  if not lo then log("error", "remote search: %s", tostring(lerr and (lerr.msg or lerr))); return end
  local from = lo + col - 1
  local found
  if opt.reverse then
    -- last match that ends at or before the position: scan from the start
    local last, lerr2 = docs.last_match(doc, from, text, opt)
    if lerr2 then log("error", "remote search: %s", tostring(lerr2.msg or lerr2.code)); return end
    found = last
    if not found and opt.wrap then
      found, lerr2 = docs.last_match(doc, math.huge, text, opt)
    end
  else
    local res, err = server_search(doc, from, text, opt, 1)
    if not res then log("error", "remote search: %s", tostring(err and (err.msg or err.code))); return end
    found = res[1]
    if not found and opt.wrap and from > 0 then
      res = server_search(doc, 0, text, opt, 1)
      found = res and res[1]
    end
  end
  if not found then return end
  local line2, col2 = found.line, found.col + found.len
  if not opt.regex then
    local nls = select(2, text:gsub("\n", ""))
    if nls > 0 then
      line2 = found.line + nls
      col2 = #text:match("([^\n]*)$") + 1
    end
  end
  -- a match that ends with the newline selects up to the start of the next line
  return found.line, found.col, line2, col2
end

--- Guard used by features that scan every line.
function docs.is_large(doc)
  return doc.remote ~= nil and doc.remote.large == true
end

return docs
