local core        = require 'core'
local common      = require 'core.common'
local Promise     = require 'plugins.use_package.promise'
local util        = require 'plugins.use_package.util'
local manifestlib = require 'plugins.use_package.manifest'

local M = {}

-- ---------------------------------------------------------------------------
-- fromGit — clone a single-repo plugin from GitHub (or any git URL)
-- ---------------------------------------------------------------------------
function M.fromGit(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local url
    if util.isURL(spec.plugin) then
      url = spec.plugin
    elseif spec.plugin:match('^[%w_.-]+/[%w_.-]+$') then
      url = 'https://github.com/' .. spec.plugin
    end
    if not url or not util.validCloneURL(url) then
      promise:reject('[use-package] unsupported repository URL: ' .. tostring(spec.plugin))
      return
    end
    local dest, derr = util.destPath(spec.name)
    if not dest then
      promise:reject(derr)
      return
    end
    if util.fileExists(dest) then
      promise:resolve()
      return
    end
    local out, code = util.exec({'git', 'clone', '--quiet', '--', url, dest})
    if code ~= 0 then
      promise:reject(out)
      return
    end
    promise:resolve()
  end)
  return promise
end

-- Update a git-cloned plugin via git pull.
function M.updateGit(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local dir, derr = util.destPath(spec.name)
    if not dir then
      promise:reject(derr)
      return
    end
    local before = util.gitHead(dir)
    local out, code = util.gitCmd({'pull', '--quiet', '--ff-only'}, dir)
    if code ~= 0 then
      promise:reject(out)
      return
    end
    -- compare commits instead of matching git's (localized) output
    promise:resolve(before ~= nil and before == util.gitHead(dir))
  end)
  return promise
end

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- linkLocalSync — synchronously symlink/copy a local path into plugins/libraries
-- spec.refresh: replace an existing copy (Windows copies instead of linking,
-- so without it an installed plugin never changes).
-- ---------------------------------------------------------------------------
local refreshed = {}       -- dest -> time of the last refresh copy
local REFRESH_REUSE = 60   -- seconds; dependencies shared by several plugins are copied once

function M.linkLocalSync(spec)
  local src      = util.normPath(common.home_expand(spec.plugin))
  local dest_dir = util.normPath(USERDIR .. (spec.library and '/libraries' or '/plugins'))
  local name     = spec.name or util.plugName(common.basename(spec.plugin))
  local dest, derr = util.destPath(name, spec.library)
  if not dest then return false, derr end

  system.mkdir(dest_dir)

  if src == dest then
    return true
  end

  if not util.fileExists(src) then
    return false, string.format('[use-package] source does not exist: %s', src)
  end

  if PLATFORM == 'Windows' then
    local refresh = spec.refresh and util.fileExists(dest)
      and system.get_time() - (refreshed[dest] or -math.huge) > REFRESH_REUSE
    if refresh then
      -- drop files removed upstream; copy below overwrites anything left
      util.rmrf(dest)
      refreshed[dest] = system.get_time()
    end
    if refresh or not util.fileExists(dest) then
      core.log_quiet('[use-package] copy %s -> %s', src, dest)
      local ok, err = util.copy(src, dest)
      if not ok then
        return false, '[use-package] copy failed: ' .. (err or 'unknown')
      end
    end
    return true
  end

  -- Unix: remove existing dest to handle stale or broken symlinks cleanly
  local removed = os.remove(dest)
  if not removed and util.fileExists(dest) then
    local info = system.get_file_info(dest)
    if info and not info.symlink then
      util.rmrf(dest)
    else
      os.remove(dest)
    end
  end

  if not util.execSync({'ln', '-sfn', '--', src, dest}) then
    return false, string.format('[use-package] failed to symlink %s to %s', src, dest)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- linkAddonSync — synchronously link an addon and its dependencies from a local repo
-- ---------------------------------------------------------------------------
-- refresh: replace existing copies of the addon and its dependencies.
function M.linkAddonSync(addon, hex, refresh)
  local repo_url = util.dehexify(hex)
  local repo_dir = manifestlib.repoLocalDir(repo_url)
  if not util.isLocalPath(repo_dir) then
    return false, 'not a local repo'
  end

  if not util.validName(addon.id) or (addon.path and not util.validRelPath(addon.path)) then
    return false, string.format('[use-package] invalid addon id/path: %s', tostring(addon.id))
  end

  -- Auto-install manifest dependencies if not present (refresh: also when present)
  if addon.dependencies then
    for dep_id, _ in pairs(addon.dependencies) do
      if not util.validName(dep_id) then goto continue end
      local dep_dest = util.normPath(USERDIR .. '/plugins/' .. dep_id)
      local dep_dest_lua = dep_dest .. '.lua'
      local dep_lib = util.normPath(USERDIR .. '/libraries/' .. dep_id)
      if refresh or (not util.fileExists(dep_dest) and not util.fileExists(dep_dest_lua) and not util.fileExists(dep_lib)) then
        -- prefer the dependency from the addon's own repo
        local dep_addon, dep_hex = manifestlib.searchAddon(dep_id, hex)
        if not dep_addon then dep_addon, dep_hex = manifestlib.searchAddon(dep_id) end
        if dep_addon and dep_hex and util.validName(dep_addon.id)
           and (not dep_addon.path or util.validRelPath(dep_addon.path)) then
          local d_repo_dir  = manifestlib.repoLocalDir(util.dehexify(dep_hex))
          local d_src_path  = dep_addon.path and (d_repo_dir .. '/' .. dep_addon.path) or d_repo_dir
          local d_file_name = dep_addon.path and (dep_addon.path:match('[^\\/]+$') or dep_id) or dep_id
          M.linkLocalSync({
            plugin  = d_src_path,
            name    = d_file_name,
            library = (dep_addon.type == 'library'),
            refresh = refresh,
          })
        end
      end
      ::continue::
    end
  end

  local src_path  = addon.path and (repo_dir .. '/' .. addon.path) or repo_dir
  local file_name = addon.path and (addon.path:match('[^\\/]+$') or addon.id) or addon.id

  return M.linkLocalSync({
    plugin  = src_path,
    name    = file_name,
    library = (addon.type == 'library'),
    refresh = refresh,
  })
end

-- ---------------------------------------------------------------------------
-- fromLocal — symlink a local filesystem path into the plugins dir
-- ---------------------------------------------------------------------------
function M.fromLocal(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local ok, err = M.linkLocalSync(spec)
    if ok then
      promise:resolve()
    else
      promise:reject(err)
    end
  end)
  return promise
end

-- ---------------------------------------------------------------------------
-- fromRepo — install a plugin from a multi-plugin repo manifest
-- ---------------------------------------------------------------------------
function M.fromRepo(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local search_hex = spec.repo and util.repoDir(manifestlib.override(spec.repo)) or nil
    local ok_up0, up0 = pcall(require, 'plugins.use_package')
    -- registered repos first, in order, so an overridden repo wins over a stale clone
    local repos_list = ok_up0 and up0.getRepos and up0.getRepos() or nil
    local addon, hex = manifestlib.searchAddon(spec.name, search_hex, repos_list)

    if not addon then
      local ok_up, up = pcall(require, 'plugins.use_package')
      if ok_up and up.getRepos then
        for _, r in ipairs(up.getRepos()) do
          manifestlib.updateRepo(r)
        end
        addon, hex = manifestlib.searchAddon(spec.name, search_hex)
      end
    end

    if not addon then
      promise:reject(string.format(
        '[use-package] no addon "%s" found in any registered repo', spec.name))
      return
    end

    -- If the addon lives in its own sub-repo, fetch it first then re-search.
    if addon.remote then
      local remote_url = addon.remote
      local out, code = manifestlib.downloadRepo(remote_url)
      if code ~= 0 then
        promise:reject(out)
        return
      end
      -- re-search in the newly downloaded sub-repo
      local sub_hex = util.repoDir(remote_url)
      addon, hex = manifestlib.searchAddon(spec.name, sub_hex)
      if not addon then
        promise:reject(string.format(
          '[use-package] addon "%s" not found in sub-repo %s', spec.name, remote_url))
        return
      end
    end

    if not util.validName(addon.id) or (addon.path and not util.validRelPath(addon.path)) then
      promise:reject(string.format('[use-package] addon "%s" has invalid id or path', tostring(addon.id)))
      return
    end

    if addon.type and addon.type ~= 'plugin' and addon.type ~= 'library' then
      promise:reject(string.format(
        '[use-package] addon "%s" has unsupported type "%s"', spec.name, addon.type))
      return
    end

    local repo_url = util.dehexify(hex)
    local repo_dir = manifestlib.repoLocalDir(repo_url)
    if not util.fileExists(repo_dir) and not util.isLocalPath(repo_url) then
      local out, code = manifestlib.downloadRepo(repo_url)
      if code ~= 0 then
        promise:reject(string.format(
          '[use-package] failed to download repo %s: %s', repo_url, out))
        return
      end
    end

    if util.isLocalPath(repo_dir) then
      local ok, err = M.linkAddonSync(addon, hex)
      if ok then
        promise:resolve()
      else
        promise:reject(err)
      end
      return
    end

    -- Auto-install manifest dependencies if not present
    if addon.dependencies then
      for dep_id, _ in pairs(addon.dependencies) do
        local dep_dest = util.normPath(USERDIR .. '/plugins/' .. dep_id)
        local dep_dest_lua = dep_dest .. '.lua'
        local dep_lib = util.normPath(USERDIR .. '/libraries/' .. dep_id)
        if util.validName(dep_id) and not util.fileExists(dep_dest) and not util.fileExists(dep_dest_lua) and not util.fileExists(dep_lib) then
          local dep_addon, dep_hex = manifestlib.searchAddon(dep_id)
          if dep_addon and dep_hex and util.validName(dep_addon.id)
             and (not dep_addon.path or util.validRelPath(dep_addon.path)) then
            local d_repo_dir  = manifestlib.repoLocalDir(util.dehexify(dep_hex))
            local d_src_path  = dep_addon.path and (d_repo_dir .. '/' .. dep_addon.path) or d_repo_dir
            local d_file_name = dep_addon.path and (dep_addon.path:match('[^\\/]+$') or dep_id) or dep_id
            local dep_done = false
            M.fromLocal({
              plugin  = d_src_path,
              name    = d_file_name,
              library = (dep_addon.type == 'library'),
            }):done(function() dep_done = true end):fail(function() dep_done = true end)
            while not dep_done do
              coroutine.yield(0.05)
            end
          end
        end
      end
    end

    local src_path  = addon.path and (repo_dir .. '/' .. addon.path) or repo_dir
    local file_name = addon.path and (addon.path:match('[^\\/]+$') or spec.name) or spec.name

    M.fromLocal({
      plugin  = src_path,
      name    = file_name,
      library = (addon.type == 'library'),
    }):forward(promise)
  end)
  return promise
end

-- ---------------------------------------------------------------------------
-- unlink — remove symlink/installed files for a plugin
-- ---------------------------------------------------------------------------
function M.unlink(spec)
  local name = spec.name or util.plugName(spec.plugin)
  local dest, derr = util.destPath(name, spec.library)
  if not dest then
    core.error('%s', derr)
    return
  end
  local dest_lua = dest .. '.lua'

  -- Attempt simple file/symlink removal first (safe on POSIX symlinks)
  os.remove(dest)
  os.remove(dest_lua)

  if util.fileExists(dest) then
    local info = system.get_file_info(dest)
    if info and not info.symlink and info.type == 'dir' then
      util.rmrf(dest)
    else
      os.remove(dest)
    end
  end
  if util.fileExists(dest_lua) then
    os.remove(dest_lua)
  end
end

-- Update a repo-installed plugin:
-- pull the cached repo clone, then re-run fromLocal to refresh the file.
function M.updateRepo(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local store = require('plugins.use_package.store')
    local stored = store.getPlugin(spec.plugin)
    if not stored or not stored.repo_hex then
      local addon, hex = manifestlib.searchAddon(spec.name)
      if hex then
        stored = { plugin = spec.plugin, name = spec.name, repo_hex = hex, installMethod = 'repo', fullyInstalled = true }
        store.addPlugin(stored)
      else
        promise:reject(string.format(
          '[use-package] no cached repo info for "%s"', spec.name))
        return
      end
    end

    -- an override replaces the repo the plugin was installed from
    local repo_hex = manifestlib.overrideHex(stored.repo_hex)
    local repo_url = util.dehexify(repo_hex)
    local out, code, changed = manifestlib.updateRepo(repo_url)
    if code ~= 0 then
      promise:reject(out)
      return
    end

    -- Refresh the installed file by re-running fromLocal or linkAddonSync
    local addon = manifestlib.searchAddon(spec.name, repo_hex)
    if not addon then
      promise:resolve(true)  -- already up to date, file unchanged
      return
    end

    local repo_dir = manifestlib.repoLocalDir(repo_url)
    if util.isLocalPath(repo_dir) then
      -- re-copy (Windows) unless a pulled clone is unchanged; a local repo
      -- reports no change state, so it is always refreshed
      local refresh = changed ~= false
      local ok, err = M.linkAddonSync(addon, repo_hex, refresh)
      if ok then
        promise:resolve(changed ~= true)  -- only a pulled change is reported as an update
      else
        promise:reject(err)
      end
      return
    end

    local src_path  = addon.path and (repo_dir .. '/' .. addon.path) or repo_dir
    local file_name = addon.path and (addon.path:match('[^\\/]+$') or spec.name) or spec.name

    -- Safely remove existing symlink/file before re-linking
    if not util.validName(addon.id) or (addon.path and not util.validRelPath(addon.path)) then
      promise:reject(string.format('[use-package] addon "%s" has invalid id or path', tostring(addon.id)))
      return
    end
    local dest, derr = util.destPath(file_name, addon.type == 'library')
    if not dest then
      promise:reject(derr)
      return
    end
    local dest_lua = dest .. '.lua'
    os.remove(dest)
    os.remove(dest_lua)

    M.fromLocal({
      plugin  = src_path,
      name    = file_name,
      library = (addon.type == 'library'),
      refresh = changed ~= false,
    }):forward(promise)
  end)
  return promise
end

-- ---------------------------------------------------------------------------
-- postRun — run spec.run inside the installed plugin directory
-- ---------------------------------------------------------------------------
function M.postRun(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local dir, derr = util.destPath(spec.name)
    if not dir then
      promise:reject(derr)
      return
    end
    local out, code = util.runInDir(spec.run, dir)
    if code ~= 0 then
      promise:reject(out)
    else
      promise:resolve()
    end
  end)
  return promise
end

return M
