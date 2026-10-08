-- mod-version:4 -- priority:0 -- version:0.1.0
--- thither: edit files on other machines through thither-server (README.md).
---
--- Loading the plugin only wraps a few global functions with a path-prefix
--- check: paths below the mount root (see paths.lua) are served by the
--- server, everything else goes straight to the original function. Remote
--- projects and files are never reopened at startup.
---
---   remote.is_remote(path)  remote.parse(path) -> host, posix path
---   remote.open_project("host:/dir")   remote.call(host, service, method, args)
local core = require "core"

-- needs the fork's core hooks and remote buffer natives
local has_handlers, path_handlers = pcall(require, "core.path_handlers")
if not has_handlers or not (buffer and buffer.open_remote) then
  core.warn("thither: this Lite XL has no remote editing support (core.path_handlers / buffer.open_remote); plugin disabled")
  return
end

local paths = require "plugins.thither.paths"

local remote = { VERSION = "0.1.0" }

remote.paths = paths
remote.is_remote = paths.is_remote
remote.parse = paths.parse
remote.make = paths.make

local is_remote = paths.is_remote

local V
local function vfs()
  if not V then V = require "plugins.thither.vfs" end
  return V
end

--- Lazily loaded sub modules.
function remote.vfs() return vfs() end
function remote.docs() return require "plugins.thither.docs" end
function remote.client() return require "plugins.thither.client" end

local installed = false

--- Wraps system / io / os / loadfile / dofile / process.start / buffer.open.
--- Idempotent. The originals are kept in locals of the wrappers (and in
--- `remote.original`) so local paths cost one byte comparison.
function remote.install()
  if installed then return end
  installed = true

  local orig = {
    get_file_info = system.get_file_info, list_dir = system.list_dir,
    absolute_path = system.absolute_path, mkdir = system.mkdir, rmdir = system.rmdir,
    chdir = system.chdir, get_fs_type = system.get_fs_type,
    io_open = io.open, io_lines = io.lines, io_type = io.type,
    os_remove = os.remove, os_rename = os.rename,
    loadfile = loadfile, dofile = dofile,
  }
  remote.original = orig

  local o_get_file_info, o_list_dir, o_absolute_path = orig.get_file_info, orig.list_dir, orig.absolute_path
  local o_mkdir, o_rmdir, o_chdir, o_fs = orig.mkdir, orig.rmdir, orig.chdir, orig.get_fs_type

  system.get_file_info = function(path)
    if is_remote(path) then return vfs().get_file_info(path) end
    return o_get_file_info(path)
  end
  system.list_dir = function(path)
    if is_remote(path) then return vfs().list_dir(path) end
    return o_list_dir(path)
  end
  system.absolute_path = function(path)
    if is_remote(path) then return vfs().absolute_path(path) end
    return o_absolute_path(path)
  end
  system.mkdir = function(path)
    if is_remote(path) then return vfs().mkdir(path) end
    return o_mkdir(path)
  end
  system.rmdir = function(path)
    if is_remote(path) then return vfs().rmdir(path) end
    return o_rmdir(path)
  end
  system.chdir = function(path)
    if is_remote(path) then return end   -- the process cwd is always local
    return o_chdir(path)
  end
  if o_fs then
    system.get_fs_type = function(path)
      if is_remote(path) then return "unknown" end
      return o_fs(path)
    end
  end

  local o_open, o_lines, o_type = orig.io_open, orig.io_lines, orig.io_type
  io.open = function(path, mode)
    if is_remote(path) then return vfs().io_open(path, mode) end
    return o_open(path, mode)
  end
  io.lines = function(path, ...)
    if path ~= nil and is_remote(path) then return vfs().io_lines(path, ...) end
    return o_lines(path, ...)
  end
  io.type = function(obj)
    if type(obj) == "table" and getmetatable(obj) == vfs().File then
      return obj.closed and "closed file" or "file"
    end
    return o_type(obj)
  end

  local o_remove, o_rename = orig.os_remove, orig.os_rename
  os.remove = function(path)
    if is_remote(path) then return vfs().remove(path) end
    return o_remove(path)
  end
  os.rename = function(a, b)
    if is_remote(a) or is_remote(b) then return vfs().rename(a, b) end
    return o_rename(a, b)
  end

  local o_loadfile, o_dofile = orig.loadfile, orig.dofile
  loadfile = function(path, ...)
    if path ~= nil and is_remote(path) then return vfs().loadfile(path, ...) end
    return o_loadfile(path, ...)
  end
  dofile = function(path)
    if path ~= nil and is_remote(path) then return vfs().dofile(path) end
    return o_dofile(path)
  end

  -- process.start: runs on the server when cwd / an argument is a mount path.
  -- (core.process has already replaced process.start with its Lua wrapper.)
  local o_start = process.start
  orig.process_start = o_start
  local function wrap(raw)
    local self = setmetatable({ process = raw }, process)
    self.stdout = process.stream.new(self, process.STREAM_STDOUT)
    self.stderr = process.stream.new(self, process.STREAM_STDERR)
    self.stdin  = process.stream.new(self, process.STREAM_STDIN)
    return self
  end
  local function maybe_remote(a)
    return type(a) == "string" and (is_remote(a) or a:find("lxl-remote", 1, true) ~= nil)
  end
  process.start = function(command, options)
    local candidate = false
    if type(options) == "table" and maybe_remote(options.cwd) then
      candidate = true
    elseif type(command) == "table" then
      for i = 1, #command do
        if maybe_remote(command[i]) then candidate = true; break end
      end
    elseif maybe_remote(command) then
      candidate = true
    end
    if candidate then
      local v = vfs()
      if v.wants_exec(command, options) then return v.process_start(command, options, wrap) end
    end
    return o_start(command, options)
  end

  -- buffer.open on a mount path must never reach the OS (on Windows the
  -- UNC name would trigger a network name lookup)
  local ok, buffer_lib = pcall(require, "buffer")
  if ok and type(buffer_lib) == "table" and buffer_lib.open then
    local o_buffer_open = buffer_lib.open
    orig.buffer_open = o_buffer_open
    buffer_lib.open = function(path, ...)
      if is_remote(path) then return nil, "remote files are opened through plugins.thither.docs" end
      return o_buffer_open(path, ...)
    end
  end

  -- dirwatch backend and commands are installed on first use of a remote
  -- path, see remote.activate()
end

--- Backend for core.dirwatch: remote paths go to the server watch events,
--- everything else to the original methods. Patching the module table also
--- reaches dirwatch instances created before (they resolve methods through it).
local function patch_dirwatch()
  local dirwatch = require "core.dirwatch"
  local o_watch, o_unwatch, o_scan, o_check = dirwatch.watch, dirwatch.unwatch, dirwatch.scan, dirwatch.check
  function dirwatch:watch(path, unwatch)
    if is_remote(path) then return vfs().dirwatch_watch(self, path, unwatch) end
    return o_watch(self, path, unwatch)
  end
  function dirwatch:unwatch(path)
    if is_remote(path) then return vfs().dirwatch_watch(self, path, false) end
    return o_unwatch(self, path)
  end
  function dirwatch:scan(path, unwatch)
    if is_remote(path) then return vfs().dirwatch_watch(self, path, unwatch) end
    return o_scan(self, path, unwatch)
  end
  function dirwatch:check(cb, scan_time, wait_time)
    local had = o_check(self, cb, scan_time, wait_time)
    if rawget(self, "rwatched") and vfs().dirwatch_check(self, cb) then had = true end
    return had
  end
end

--- Sets up the status bar item once the first remote connection exists
--- (called by the plugin and by tests).
local activated = false
function remote.activate()
  if activated then return end
  activated = true
  vfs()
  require("plugins.thither.commands").setup()
end

--- Registers the user facing parts: the commands, and the path handler that
--- lets core.doc load and save remote documents. The status item is added
--- by remote.activate() on the first handshake (client.lua). Costs nothing
--- until a remote host is used.
local registered = false
function remote.register()
  if registered then return end
  registered = true
  require("plugins.thither.commands").add_commands()
  local function docs() return require "plugins.thither.docs" end
  remote.path_handler = path_handlers.register({
    claims = is_remote,
    load = function(doc, filename) return docs().load(doc, filename) end,
    loaded = function(doc, filename) return docs().loaded_small(doc, filename) end,
    save = function(doc, abs_filename) return docs().save(doc, abs_filename) end,
    release = function(doc) return docs().release(doc) end,
    async_save = true,
  })
end

--- Remote projects are not restored at startup: drops mount-root entries from
--- the recent projects and, if core started with one (a session written
--- before this rule), switches back to the most recent local project.
local function forget_remote_projects()
  local recents = core.recent_projects or {}
  for i = #recents, 1, -1 do
    if is_remote(recents[i]) then table.remove(recents, i) end
  end
  local root = core.projects and core.projects[1]
  if root and is_remote(root.path) then
    local dir = recents[1] and system.get_file_info(recents[1]) and recents[1] or system.absolute_path(".")
    pcall(core.set_project, dir)
  end
end

--- Opens a remote project: "host:/path". Async (use inside commands).
function remote.open_project(location, done)
  remote.activate()
  return require("plugins.thither.commands").open_project(location, done)
end

--- Calls a server plugin: remote.call(host, service, method, args) -> ok | nil, err
function remote.call(host, service, method, args)
  local label = paths.sanitize_host(host)
  local v = vfs()
  local c, err = v.conn_for(label)
  if not c then return nil, err end
  return c:call("call", { service = service, method = method, args = args or {} })
end

remote.install()
patch_dirwatch()
remote.register()
forget_remote_projects()

return remote
