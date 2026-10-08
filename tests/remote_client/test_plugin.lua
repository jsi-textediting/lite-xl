-- The client as a plugin: version-aware override of bundled plugins (core),
-- the plugin's own header, its path handler, and opening a remote project in
-- place without touching the recent projects.
return function(T)
  local core = require "core"
  local common = require "core.common"

  local tmp_root = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp") .. PATHSEP .. "lxc-plugin-" .. tostring(os.time())
  local function mkdirs(path)
    local acc = ""
    for part in path:gmatch("[^\\/]+") do
      acc = acc == "" and (path:match("^[\\/]") and PATHSEP or "") .. part or acc .. PATHSEP .. part
      if not system.get_file_info(acc) then system.mkdir(acc) end
    end
  end
  local function write(path, text)
    mkdirs(common.dirname(path))
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  -- a directory plugin `name` in `root`/plugins with a submodule that tells
  -- which copy it is
  local function fake_plugin(root, name, header, who)
    local dir = root .. PATHSEP .. "plugins" .. PATHSEP .. name
    write(dir .. PATHSEP .. "init.lua", header .. "\nreturn { who = require('.sub') }\n")
    write(dir .. PATHSEP .. "sub.lua", "return " .. string.format("%q", who) .. "\n")
  end
  local function pick(list, name)
    for _, d in ipairs(list) do if d.name == name then return d end end
  end

  T.test("plugin: version comparison and the -- version header", function()
    T.eq(core.compare_versions("0.2.0", "0.1.9"), 1)
    T.eq(core.compare_versions("1.10", "1.9"), 1)
    T.eq(core.compare_versions("1", "1.0.0"), 0)
    T.eq(core.compare_versions("0.1", "0.1.1"), -1)
    local d = core.get_plugin_details(DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "thither")
    T.ok(d, "thither plugin details")
    T.eq(d.plugin_version, "0.1.0")
    T.eq(d.priority, 0)
    T.ok(d.version_match, "mod-version matches")
    local up = core.get_plugin_details(DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "use_package")
    T.eq(up.plugin_version, "0.2.0")
    T.eq(up.priority, 0)
  end)

  T.test("plugin: an older user copy is ignored, require follows the bundled copy", function()
    local user, data = tmp_root .. PATHSEP .. "user", tmp_root .. PATHSEP .. "data"
    local name = "lxcfake" .. tostring(os.time())
    fake_plugin(data, name, "-- mod-version:4 -- version:0.2.0", "bundled")
    fake_plugin(user, name, "-- mod-version:4 -- version:0.1.0", "user")
    local list, roots = core.discover_plugins(user .. PATHSEP .. "plugins", data .. PATHSEP .. "plugins")
    local d = pick(list, name)
    T.eq(d.dir, data .. PATHSEP .. "plugins", "bundled copy chosen")
    T.eq(roots[name], data .. PATHSEP .. "plugins")
    -- the user copy comes first on package.path, as USERDIR does
    local saved_path = package.path
    package.path = user .. PATHSEP .. "?.lua;" .. user .. PATHSEP .. "?" .. PATHSEP .. "init.lua;" .. package.path
    core.use_bundled_plugin(name, roots[name])
    local ok, mod = pcall(require, "plugins." .. name)
    package.path = saved_path
    core.plugin_roots[name] = nil
    T.ok(ok, tostring(mod))
    T.eq(mod.who, "bundled", "submodule resolved in the bundled copy")
  end)

  T.test("plugin: a newer or unversioned user copy wins", function()
    local user, data = tmp_root .. PATHSEP .. "user2", tmp_root .. PATHSEP .. "data2"
    fake_plugin(data, "lxcnewer", "-- mod-version:4 -- version:0.2.0", "bundled")
    fake_plugin(user, "lxcnewer", "-- mod-version:4 -- version:0.3.0", "user")
    fake_plugin(data, "lxcnover", "-- mod-version:4 -- version:0.2.0", "bundled")
    fake_plugin(user, "lxcnover", "-- mod-version:4", "user")
    fake_plugin(data, "lxcequal", "-- mod-version:4 -- version:0.2.0", "bundled")
    fake_plugin(user, "lxcequal", "-- mod-version:4 -- version:0.2", "user")
    local list, roots = core.discover_plugins(user .. PATHSEP .. "plugins", data .. PATHSEP .. "plugins")
    for _, n in ipairs { "lxcnewer", "lxcnover", "lxcequal" } do
      T.eq(pick(list, n).dir, user .. PATHSEP .. "plugins", n .. ": user copy chosen")
      T.eq(roots[n], nil, n)
    end
    local count = 0
    for _, d in ipairs(list) do if d.name == "lxcnewer" then count = count + 1 end end
    T.eq(count, 1, "one entry per plugin name")
  end)

  T.test("plugin: remote paths have a path handler; local paths do not", function()
    local path_handlers = require "core.path_handlers"
    local paths = require "plugins.thither.paths"
    local mount = paths.make(T.label, "/tmp")
    T.ok(path_handlers.is_virtual(mount), "mount path is virtual")
    T.ok(not path_handlers.is_virtual(DATADIR), "local path is not virtual")
    local h = path_handlers.find(mount)
    T.ok(h and h.async_save and h.load and h.save and h.release, "handler with load/save/release")
  end)

  T.test("plugin: opening a remote project switches in place and skips the recent projects", function()
    if not T.real then io.stdout:write("      (skipped outside -Real mode: needs core.init)\n") return end
    T.connect()
    local commands = require "plugins.thither.commands"
    local paths = require "plugins.thither.paths"
    local dir, mount = T.tmpdir("proj")
    local saved_projects, saved_recents = core.projects, core.recent_projects
    core.projects = {}
    core.recent_projects = { DATADIR }
    local ok, err = pcall(commands.switch_project, mount)
    local root = core.projects[1] and core.projects[1].path
    local recents = core.recent_projects
    core.projects, core.recent_projects = saved_projects, saved_recents
    T.ok(ok, tostring(err))
    T.eq(root, mount, "root project is the remote directory")
    T.eq(#recents, 1, "recent projects unchanged")
    T.eq(recents[1], DATADIR)
    T.ok(paths.is_remote(root))
  end)

  T.test("cleanup: plugin tests", function()
    local function rm(path)
      local info = system.get_file_info(path)
      if not info then return end
      if info.type == "dir" then
        for _, f in ipairs(system.list_dir(path) or {}) do rm(path .. PATHSEP .. f) end
        system.rmdir(path)
      else
        os.remove(path)
      end
    end
    rm(tmp_root)
  end)
end
