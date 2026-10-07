--- Commands (remote:open-project, remote:disconnect, remote:reconnect) and
--- the status bar indicator of the remote client.
local paths = require "core.remote.paths"
-- vfs and client are only loaded when a command runs (the plugin that
-- registers the commands must cost nothing for purely local use)
local function lazy(name)
  return setmetatable({}, { __index = function(_, k) return require(name)[k] end })
end
local vfs = lazy("core.remote.vfs")
local Conn = lazy("core.remote.client")

local M = {}

local function core() return require "core" end

--- Opens "host:/path" as the project (restarts the editor like core.open_project
--- does). Runs the connect in a core thread so the UI stays responsive.
--- `done(ok, err)` is called when connected (before the restart).
function M.open_project(location, done)
  local core = core()
  local spec, rpath = paths.split_location(location)
  if not spec then
    core.error("remote: expected host:/path, got \"%s\"", tostring(location))
    if done then done(false, "bad location") end
    return
  end
  core.add_thread(function()
    local label = paths.sanitize_host(spec)
    core.log("Connecting to %s ...", spec)
    local h, err = vfs.connect(spec, false)
    if not h then
      core.error("remote: cannot connect to %s: %s", spec, tostring(err))
      if done then done(false, err) end
      return
    end
    local ok, why = h.conn:wait_ready()
    if not ok then
      core.error("remote: cannot connect to %s: %s", spec, tostring(why))
      if done then done(false, why) end
      return
    end
    local home = h.conn.hello and h.conn.hello.home or "/"
    if not rpath or rpath == "" then rpath = home end
    if rpath:sub(1, 1) == "~" then rpath = home .. rpath:sub(2) end
    local real, rerr = h.conn:call("realpath", { path = rpath })
    if not real then
      core.error("remote: %s: %s", rpath, tostring(rerr and (rerr.msg or rerr.code)))
      if done then done(false, rerr) end
      return
    end
    local st, serr = h.conn:call("stat", { path = real })
    if not st or st.type ~= "dir" then
      core.error("remote: %s is not a directory", real)
      if done then done(false, serr or "not a directory") end
      return
    end
    h.root = real   -- sent again after a reconnect (see vfs.attach)
    h.conn:notify("set_root", { path = real })
    vfs.remember_host(spec, label, real)
    if done then done(true, paths.make(label, real)) return end
    core.open_project(paths.make(label, real))
  end)
end

local function host_items()
  local items = {}
  for _, r in ipairs(vfs.recent_hosts()) do
    local text = r.spec .. ":" .. (r.path ~= "" and r.path or "")
    items[#items + 1] = text
  end
  return items
end

local function connected_labels()
  local t = {}
  -- only hosts that are (or were) connected: attempts that never got a
  -- handshake (bad host, auth failure) are not offered to disconnect/reconnect
  for label, c in pairs(Conn.all) do
    if c.hello or c.state == "connecting" or c.state == "ready" then t[#t + 1] = label end
  end
  table.sort(t)
  return t
end

local function current_label()
  local core = core()
  local proj = core.root_project and core.root_project()
  if proj then
    local label = paths.parse(proj.path)
    if label then return label end
  end
  return connected_labels()[1]
end

local function pick_host(prompt, fn)
  local core = core()
  local labels = connected_labels()
  if #labels == 0 then core.error("remote: no remote connections"); return end
  if #labels == 1 then return fn(labels[1]) end
  core.command_view:enter(prompt, {
    text = current_label() or "",
    submit = function(text, item) fn(item and item.text or text) end,
    suggest = function(text)
      local res = {}
      for _, l in ipairs(labels) do
        if l:lower():find(text:lower(), 1, true) then res[#res + 1] = l end
      end
      return res
    end,
  })
end

local state_text = {
  ready = "connected", connecting = "connecting...", closed = "disconnected",
  failed = "failed", idle = "idle",
}

local function status_item()
  local core = core()
  local style = require "core.style"
  local label = current_label()
  local c = label and Conn.all[label]
  if not c then return {} end
  local color = style.dim
  if c.state == "ready" then color = style.good
  elseif c.state == "connecting" then color = style.warn
  else color = style.error end
  local text = state_text[c.state] or c.state
  if c.state ~= "ready" and c.reconnect_at then text = text .. " (reconnecting)" end
  return { color, style.icon_font, "D", style.font, " ", style.text, label, style.dim, " ", color, text }
end

local function add_status_item()
  local core = core()
  if not core.status_view or core.status_view:get_item("remote:status") then return end
  local StatusView = require "core.statusview"
  core.status_view:add_item({
    predicate = function() return next(Conn.all) ~= nil end,
    name = "remote:status",
    alignment = StatusView.Item.RIGHT,
    get_item = status_item,
    command = function(button)
      local command = require "core.command"
      if button == "left" then
        local label = current_label()
        local c = label and Conn.all[label]
        if c and c.state ~= "ready" and c.state ~= "connecting" then command.perform("remote:reconnect") end
      end
    end,
    tooltip = "Remote connection",
    separator = StatusView.separator2,
  })
end

local installed = false
function M.setup()
  if installed then return end
  installed = true
  local core = core()
  if core.add_thread and core.threads then
    -- the status bar may not exist yet while the first remote path is touched
    core.add_thread(function()
      while not core.status_view do coroutine.yield(0.1) end
      add_status_item()
    end)
  end
end

--- Registers the commands (called once at load; needs core.command).
function M.add_commands()
  local command = require "core.command"
  local core = core()
  command.add(nil, {
    ["remote:open-project"] = function()
      core.command_view:enter("Open Remote Project (host:/path)", {
        submit = function(text, item)
          M.open_project(item and item.text or text)
        end,
        suggest = function(text)
          local res = {}
          for _, t in ipairs(host_items()) do
            if t:lower():find(text:lower(), 1, true) then res[#res + 1] = t end
          end
          return res
        end,
      })
    end,
    ["remote:disconnect"] = function()
      pick_host("Disconnect Host", function(label)
        vfs.disconnect(label)
        core.log("Disconnected from %s", label)
      end)
    end,
    ["remote:reconnect"] = function()
      pick_host("Reconnect Host", function(label)
        local h = vfs.get_host(label)
        core.add_thread(function()
          core.log("Reconnecting to %s ...", label)
          h.last_try = nil
          local c = vfs.ensure_conn(h)
          if not c then core.error("remote: cannot reconnect to %s", label) end
        end)
      end)
    end,
  })
end

return M
