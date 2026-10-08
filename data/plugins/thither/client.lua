--- Non-blocking client of the thither-server protocol (thither/docs/protocol.md).
---
--- One `Conn` per host: a long-lived child process (plink / ssh / wsl.exe)
--- whose stdin/stdout carry framed msgpack. Everything is poll driven: a
--- ticker thread (core.add_thread) reads and dispatches, so the UI thread
--- never waits on the network. Blocking calls (`Conn:call`) exist for APIs
--- that are synchronous by contract (io.open, system.get_file_info ...); they
--- yield-poll when running inside a core thread and busy-poll with a timeout
--- otherwise.
local msgpack = require "plugins.thither.msgpack"
local frame = require "plugins.thither.frame"
local ssh = require "plugins.thither.ssh"
local options = require "plugins.thither.options"

local Conn = {}
Conn.__index = Conn

Conn.PROTO = 1
Conn.all = {}              -- label -> Conn
Conn.listeners = {}        -- fn(conn, state, reason) called on state changes

local WRITE_SLICE = 32768
local WRITE_BUDGET = 262144

local function now() return system.get_time() end

local function log(level, fmt, ...)
  local ok, core = pcall(require, "core")
  if ok and core[level] then
    local ok2 = pcall(core[level], fmt, ...)
    if ok2 then return end
  end
  io.stderr:write(string.format(fmt, ...) .. "\n")
end

--- True when the running coroutine is one of core.threads (so yielding is
--- legal and returns to the scheduler, not to some coroutine.wrap consumer).
local function in_core_thread()
  if not coroutine.isyieldable() then return false end
  local core = package.loaded["core"]
  local threads = core and core.threads
  if not threads then return false end
  local co = coroutine.running()
  for _, t in pairs(threads) do
    if t.cr == co then return true end
  end
  return false
end
Conn.in_core_thread = in_core_thread

function Conn.new(spec, label)
  local self = setmetatable({
    spec = spec, label = label, state = "idle", generation = 0,
    handlers = {}, streams = {}, early = {},
    reconnect_attempt = 0,
  }, Conn)
  self:_reset()
  return self
end

function Conn:_reset()
  self.next_id = 1
  self.pending = {}
  self.npending = 0
  self.reader = frame.reader()
  self.inbox, self.ihead = {}, 1
  self.deferred, self.dhead = {}, 1
  self.outq, self.ohead, self.ooff = {}, 1, 0
  self.stderr_tail = ""
  self.hello = nil
  self.last_rx = now()
  self.ping_id = nil
  self.watch_ids = {}
  self.early = {}            -- events of streams of an old server are meaningless
end

function Conn:set_state(state, reason)
  if self.state == state then return end
  self.state = state
  self.reason = reason
  for _, fn in ipairs(Conn.listeners) do
    local ok, err = pcall(fn, self, state, reason)
    if not ok then log("warn", "thither: state listener failed: %s", tostring(err)) end
  end
end

function Conn:is_ready() return self.state == "ready" end

--- Registers a handler for server events with `ev == name` (fn(conn, msg)).
function Conn:on(name, fn)
  local l = self.handlers[name]
  if not l then l = {}; self.handlers[name] = l end
  l[#l + 1] = fn
end

---------------------------------------------------------------------------
-- Process and framing
---------------------------------------------------------------------------

--- Spawns the transport and sends the hello. Returns true or nil, message.
function Conn:start()
  if self.proc then self:_kill_proc() end
  self:_reset()
  self.generation = self.generation + 1
  Conn.all[self.label] = self
  local argv, desc = ssh.build(self.spec, self.label)
  self.desc = desc
  local ok, proc = pcall(process.start, argv)
  if not ok or not proc then
    local msg = "cannot start " .. tostring(argv[1]) .. ": " .. tostring(proc)
    self:set_state("failed", msg)
    return nil, msg
  end
  self.proc = proc
  self.started = now()
  self:set_state("connecting")
  self:send({ ev = "hello", proto_version = Conn.PROTO, client_version = VERSION or "?",
              caps = { "watch", "exec" } })
  Conn.ensure_ticker()
  return true
end

function Conn:_kill_proc()
  local proc = self.proc
  self.proc = nil
  if proc then
    pcall(proc.close_stream, proc, process.STREAM_STDIN)
    local ok, running = pcall(proc.running, proc)
    if ok and running then
      -- give the server a moment to leave on stdin EOF, then terminate
      local t0 = now()
      while now() - t0 < 0.2 do
        local ok2, r = pcall(proc.running, proc)
        if not ok2 or not r then break end
        system.sleep(0.005)
      end
      pcall(proc.terminate, proc)
    end
  end
end

--- Marks the connection dead, fails every pending request.
function Conn:fail(reason)
  if self.state == "closed" or self.state == "failed" then return end
  local tail = self.stderr_tail:gsub("%s+$", "")
  if tail ~= "" then reason = reason .. " (" .. tail:sub(-400) .. ")" end
  local pending = self.pending
  self.pending, self.npending = {}, 0
  self:_kill_proc()
  self:set_state(self.hello and "closed" or "failed", reason)
  local err = { code = "disconnected", msg = reason }
  for _, p in pairs(pending) do
    p.done, p.err = true, err
    if p.cb then pcall(p.cb, nil, err) end
  end
  for _, h in pairs(self.streams) do pcall(h, { ev = "exit", code = -1, killed = true, disconnected = true }) end
  self.streams = {}
  if self.hello then self.reconnect_at = now() + (options.get("reconnect_delays", self.label)[1] or 1) end
end

--- Clean disconnect requested by the user.
function Conn:close(reason)
  if self.state == "closed" then return end
  self.no_reconnect = true
  self.reconnect_at = nil
  local pending = self.pending
  self.pending, self.npending = {}, 0
  self:_kill_proc()
  self:set_state("closed", reason or "disconnected")
  local err = { code = "disconnected", msg = reason or "disconnected" }
  for _, p in pairs(pending) do
    p.done, p.err = true, err
    if p.cb then pcall(p.cb, nil, err) end
  end
  for _, h in pairs(self.streams) do pcall(h, { ev = "exit", code = -1, killed = true, disconnected = true }) end
  self.streams = {}
end

function Conn:flush()
  local proc = self.proc
  if not proc then return end
  local q = self.outq
  local budget = WRITE_BUDGET
  while self.ohead <= #q and budget > 0 do
    local piece = q[self.ohead]
    local off = self.ooff
    local n_to = math.min(#piece - off, WRITE_SLICE)
    local chunk = (off == 0 and n_to == #piece) and piece or piece:sub(off + 1, off + n_to)
    local ok, n = pcall(proc.write, proc, chunk)
    if not ok then
      self:fail("write to server failed: " .. tostring(n))
      return
    end
    if not n or n == 0 then return end
    budget = budget - n
    off = off + n
    if off >= #piece then
      q[self.ohead] = false
      self.ohead = self.ohead + 1
      self.ooff = 0
    else
      self.ooff = off
      if n < #chunk then return end
    end
  end
  if self.ohead > #q then self.outq, self.ohead = {}, 1 end
end

function Conn:send(msg)
  if not self.proc then return false end
  local ok, data = pcall(frame.encode, msg)
  if not ok then error(data, 0) end
  local q = self.outq
  q[#q + 1] = data
  self:flush()
  return true
end

local function inbox_pop(list, headfield, self)
  local h = self[headfield]
  local m = list[h]
  if m == nil then return nil end
  list[h] = false
  self[headfield] = h + 1
  if self[headfield] > #list then
    -- queue drained: reset in place
    for i = #list, 1, -1 do list[i] = nil end
    self[headfield] = 1
  end
  return m
end

function Conn:_dispatch(m)
  if m.id ~= nil and m.ev == nil then
    local p = self.pending[m.id]
    if not p then return end
    self.pending[m.id] = nil
    self.npending = self.npending - 1
    p.done = true
    if m.err ~= nil then p.err = m.err else p.ok = m.ok end
    if p.cb then
      local ok, err = pcall(p.cb, p.ok, p.err)
      if not ok then log("warn", "thither: callback for %s failed: %s", tostring(p.op), tostring(err)) end
    end
    return
  end
  local ev = m.ev
  if ev == "hello" then
    if m.err then
      self:fail("handshake refused: " .. tostring(m.err.msg or m.err.code))
    elseif m.proto_version ~= Conn.PROTO then
      self:fail("protocol version mismatch (server " .. tostring(m.proto_version) .. ")")
    else
      self.hello = m
      self.caps = {}
      for _, c in ipairs(m.caps or {}) do self.caps[c] = true end
      self.reconnect_attempt = 0
      self.no_reconnect = nil
      self:set_state("ready")
      -- first handshake: the plugin adds its status item
      local plugin = package.loaded["plugins.thither"]
      if type(plugin) == "table" and plugin.activate then pcall(plugin.activate) end
    end
    return
  end
  if ev == "stdout" or ev == "stderr" or ev == "exit" then
    local h = self.streams[m.stream]
    if h then
      h(m)
    else
      local e = self.early[m.stream]
      if not e then e = {}; self.early[m.stream] = e end
      e[#e + 1] = m
    end
    return
  end
  local list = ev and self.handlers[ev]
  if list then
    for _, fn in ipairs(list) do
      local ok, err = pcall(fn, self, m)
      if not ok then log("warn", "thither: handler for %s failed: %s", tostring(ev), tostring(err)) end
    end
  elseif m.err and m.id == nil then
    log("warn", "thither: server error: %s", tostring(m.err.msg or m.err.code))
  end
end

--- Reads from the server and dispatches. With `only` (a request id) just that
--- response is dispatched and everything else is deferred to the next normal
--- poll: used by blocking calls so unrelated callbacks (which may touch a
--- buffer that is in the middle of a sync fetch) never run re-entrantly.
function Conn:poll(only)
  local proc = self.proc
  if not proc then return false end
  local got = false
  if self.ohead <= #self.outq then self:flush() end
  for _ = 1, 32 do
    local ok, data = pcall(proc.read_stdout, proc, 262144)
    if not ok then self:fail("read from server failed: " .. tostring(data)); return got end
    if not data or data == "" then break end
    self.reader:feed(data)
    got = true
  end
  local ok, err = pcall(proc.read_stderr, proc, 65536)
  if ok and err and err ~= "" then
    got = true
    self.stderr_tail = (self.stderr_tail .. err):sub(-2048)
  end
  if got then self.last_rx = now() end
  while true do
    local v, code, detail = self.reader:next()
    if v == nil then
      if code then
        self:fail("bad frame from server: " .. code .. " " .. tostring(detail))
        return got
      end
      break
    end
    self.inbox[#self.inbox + 1] = v
  end
  -- deferred messages first (they arrived earlier), then new ones
  if not only then
    while true do
      local m = inbox_pop(self.deferred, "dhead", self)
      if not m then break end
      self:_dispatch(m)
      if self.state == "closed" or self.state == "failed" then return got end
    end
  end
  while true do
    local m = inbox_pop(self.inbox, "ihead", self)
    if not m then break end
    if only and not (m.id == only and m.ev == nil) then
      self.deferred[#self.deferred + 1] = m
    else
      self:_dispatch(m)
      if self.state == "closed" or self.state == "failed" then return got end
    end
  end
  if not got and not proc:running() and (self.state == "ready" or self.state == "connecting") then
    -- process gone and nothing left to read
    self:poll_final()
  end
  return got
end

function Conn:poll_final()
  local proc = self.proc
  if not proc then return end
  local ok, data = pcall(proc.read_stderr, proc, 65536)
  if ok and data and data ~= "" then self.stderr_tail = (self.stderr_tail .. data):sub(-2048) end
  local rc = proc:returncode()
  self:fail(self.hello and ("connection lost (exit " .. tostring(rc) .. ")")
                       or ("server did not start (exit " .. tostring(rc) .. ")"))
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------

--- Sends a request; `cb(ok, err)` is called from poll(). Returns the id or nil.
function Conn:request(op, args, cb, p)
  p = p or {}
  p.cb, p.op = cb, op
  if not self.proc or (self.state ~= "ready" and self.state ~= "connecting") then
    local err = { code = "disconnected", msg = self.reason or "not connected" }
    p.done, p.err = true, err
    if cb then cb(nil, err) end
    return nil, err
  end
  local id = self.next_id
  self.next_id = id + 1
  self.pending[id] = p
  self.npending = self.npending + 1
  p.id = id
  local ok, e = pcall(self.send, self, { id = id, op = op, args = args or {} })
  if not ok then
    self.pending[id] = nil
    self.npending = self.npending - 1
    local err = { code = "bad_request", msg = tostring(e) }
    p.done, p.err = true, err
    if cb then cb(nil, err) end
    return nil, err
  end
  return id
end

--- Fire and forget (no response is sent by the server).
function Conn:notify(op, args)
  return self:send({ op = op, args = args or {} })
end

--- Cancels an in-flight request: the callback is dropped, the server told.
function Conn:cancel(id)
  local p = id and self.pending[id]
  if not p then return end
  p.cb = nil
  p.cancelled = true
  self:send({ cancel = id })
end

--- Blocks until `pred()` is true, the connection dies or `timeout` expires.
--- Returns true, or nil and a reason.
function Conn:wait(pred, timeout, noyield, only)
  local deadline = now() + (timeout or options.get("request_timeout", self.label))
  local can_yield = not noyield and in_core_thread()
  while not pred() do
    if self.state == "closed" or self.state == "failed" then
      return nil, self.reason or "disconnected"
    end
    if now() > deadline then return nil, "timeout" end
    self:poll(not can_yield and only or nil)
    if pred() then break end
    if can_yield then
      coroutine.yield(0.002)
    else
      system.sleep(0.0005)
    end
  end
  return true
end

--- Blocking request. Returns ok_value or nil, err_table. `opts.noyield`
--- must be set when the caller cannot yield into the scheduler (inside the
--- buffer's sync fetch callback).
function Conn:call(op, args, timeout, opts)
  local p = {}
  local id, err = self:request(op, args, nil, p)
  if not id then return nil, err end
  local noyield = opts and opts.noyield
  local ok, why = self:wait(function() return p.done end, timeout, noyield, id)
  if not p.done then
    self:cancel(id)
    if self.pending[id] then
      self.pending[id] = nil
      self.npending = self.npending - 1
    end
    return nil, { code = (why == "timeout") and "timeout" or "disconnected", msg = tostring(why) .. " (" .. op .. ")" }
  end
  if p.err then return nil, p.err end
  return p.ok
end

--- Waits for the handshake. Returns true or nil, reason.
function Conn:wait_ready(timeout)
  if self.state == "ready" then return true end
  if self.state ~= "connecting" then return nil, self.reason or self.state end
  local ok, why = self:wait(function() return self.state ~= "connecting" end,
    timeout or options.get("hello_timeout", self.label), false)
  if self.state == "ready" then return true end
  if why == "timeout" and self.state == "connecting" then
    self:fail("timed out waiting for the server (" .. tostring(self.desc) .. ")")
  end
  return nil, self.reason or why or self.state
end

---------------------------------------------------------------------------
-- Ticker: polling, heartbeat, reconnect
---------------------------------------------------------------------------

function Conn:tick()
  local t = now()
  -- core.run sleeps without a timeout while the window is unfocused and idle:
  -- a long gap between ticks means we were not scheduled, not that the server died
  if t - (self.last_tick or t) > 3 then self.last_rx = t end
  self.last_tick = t
  if self.proc and (self.state == "ready" or self.state == "connecting") then
    self:poll()
    if self.state == "ready" then
      local ping_interval = options.get("ping_interval", self.label)
      local ping_timeout = options.get("ping_timeout", self.label)
      if self.ping_id and not self.pending[self.ping_id] then self.ping_id = nil end
      if t - self.last_rx > ping_timeout then
        self:fail("no response from server for " .. math.floor(t - self.last_rx) .. "s")
      elseif t - self.last_rx > ping_interval and not self.ping_id then
        self.ping_id = self:request("ping", {}, function() end)
      end
    elseif self.state == "connecting" then
      if t - self.started > options.get("hello_timeout", self.label) then
        self:fail("timed out waiting for the server (" .. tostring(self.desc) .. ")")
      end
    end
  elseif self.reconnect_at and t >= self.reconnect_at and not self.no_reconnect
         and options.get("auto_reconnect", self.label) then
    self.reconnect_at = nil
    self:reconnect(true)
  end
  return self.npending > 0 or next(self.streams) ~= nil or self.state == "connecting"
end

--- Starts a fresh transport for the same host (state, watches and caches are
--- restored by the listeners of "ready").
function Conn:reconnect(automatic)
  self.reconnect_attempt = self.reconnect_attempt + 1
  self.no_reconnect = nil
  self.reconnecting = true
  local ok, msg = self:start()
  if not ok and automatic then
    local delays = options.get("reconnect_delays", self.label)
    local d = delays[math.min(self.reconnect_attempt, #delays)]
    if d and self.reconnect_attempt <= #delays then self.reconnect_at = now() + d end
  end
  return ok, msg
end

local function on_state_change(conn, state)
  if state == "failed" and conn.reconnecting then
    local delays = options.get("reconnect_delays", conn.label)
    local d = delays[math.min(conn.reconnect_attempt, #delays)]
    if d and conn.reconnect_attempt <= #delays and not conn.no_reconnect
       and options.get("auto_reconnect", conn.label) then
      conn.reconnect_at = now() + d
    end
  end
end
Conn.listeners[#Conn.listeners + 1] = on_state_change

function Conn.ensure_ticker()
  if Conn.ticker then return end
  local core = require "core"
  if not core.add_thread or not core.threads then return end
  Conn.ticker = core.add_thread(function()
    while true do
      local busy = false
      for _, c in pairs(Conn.all) do
        local ok, r = pcall(c.tick, c)
        if ok then busy = busy or r
        else log("warn", "thither: connection tick failed: %s", tostring(r)) end
      end
      coroutine.yield(busy and 0.004 or 0.05)
    end
  end)
end

--- Stops ticking (tests / restart).
function Conn.shutdown_all()
  for label, c in pairs(Conn.all) do
    c:close("shutdown")
    Conn.all[label] = nil
  end
  local core = package.loaded["core"]
  if Conn.ticker and core and core.threads then core.threads[Conn.ticker] = nil end
  Conn.ticker = nil
end

return Conn
