-- mod-version:4 --priority:0 -- version:0.2.0
local core        = require 'core'
local common      = require 'core.common'
local config      = require 'core.config'
local command     = require 'core.command'
local keymap      = require 'core.keymap'
local store       = require 'plugins.use_package.store'
local util        = require 'plugins.use_package.util'
local manifestlib = require 'plugins.use_package.manifest'
local installer   = require 'plugins.use_package.installer'

store.init()

-- WARNING: auto_update pulls the latest commits of every declared plugin and
-- repo on each startup and then loads them, i.e. it runs unpinned, unreviewed
-- code. Pin repos to a tag ("url:tag") and leave auto_update off if that matters.
config.plugins.use_package = common.merge({
  auto_install   = false,
  auto_update    = false,
  -- repo URL (without tag) -> local path to use instead, e.g. a checkout
  repo_overrides = {},
}, config.plugins.use_package)

local M = {
  VERSION = "0.2.0"
}

function M.setup(opts)
  opts = opts or {}
  if opts.auto_install ~= nil then
    config.plugins.use_package.auto_install = opts.auto_install and true or false
  end
  if opts.auto_update ~= nil then
    config.plugins.use_package.auto_update = opts.auto_update and true or false
  end
end

setmetatable(M, {
  __index = function(t, k)
    if k == 'auto_install' then
      return config.plugins.use_package.auto_install
    elseif k == 'auto_update' then
      return config.plugins.use_package.auto_update
    end
    return rawget(t, k)
  end,
  __newindex = function(t, k, v)
    if k == 'auto_install' then
      config.plugins.use_package.auto_install = v and true or false
    elseif k == 'auto_update' then
      config.plugins.use_package.auto_update = v and true or false
    else
      rawset(t, k, v)
    end
  end,
})

-- Internal registry — populated by use() calls in the user's init.lua
local _plugins  = {}
local _repos    = {}

-- True until core.load_plugins() has finished (threads only run afterwards).
local _startup = true
core.add_thread(function() _startup = false end)

-- True if core.load_plugins() is going to load the plugin itself, at its own
-- priority.  use() runs from the user module (priority -2), so requiring such
-- a plugin there would load it before every core plugin: later plugins that
-- replace a method without chaining (e.g. linewrapping's draw_line_text) then
-- silently bypass its hooks.
local function coreWillLoad(name)
  if not _startup then return false end
  for _, p in ipairs(core.plugin_list) do
    if p.name == name and p.priority >= 0 then return true end
  end
  return false
end

-- Deferred :config / :bind hooks, flushed via core.add_thread after startup
local _pending   = {}
local _scheduled = false

local function runHook(fn)
  local ok, err = pcall(fn)
  if not ok then
    core.error('[use-package] hook error: %s', err)
  end
end

local function runOrDefer(fn)
  if not _startup then
    runHook(fn)
  else
    table.insert(_pending, fn)
    if not _scheduled then
      _scheduled = true
      core.add_thread(function()
        coroutine.yield()   -- let the rest of init.lua and plugin auto-load settle
        while #_pending > 0 do
          local hook = table.remove(_pending, 1)
          runHook(hook)
        end
      end)
    end
  end
end

-- ---------------------------------------------------------------------------
-- pluginExists — check for directory or single .lua file in plugins dir
-- ---------------------------------------------------------------------------
local function pluginExistsInUserdir(name)
  return util.fileExists(USERDIR .. '/plugins/' .. name)
      or util.fileExists(USERDIR .. '/plugins/' .. name .. '.lua')
end

local function pluginExists(name)
  return pluginExistsInUserdir(name)
      or util.fileExists(DATADIR .. '/plugins/' .. name)
      or util.fileExists(DATADIR .. '/plugins/' .. name .. '.lua')
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Register multi-plugin repo URLs (format: "url:tag" or local dir).
-- Called before any use() declarations.
function M.repos(list)
  for _, r in ipairs(list) do
    local o = manifestlib.override(r)
    table.insert(_repos, o)
    local url = util.repoURL(r)
    if o ~= r then
      -- overridden: the local path stands in for the repo's clone, so its
      -- plugins are only installed when declared
      manifestlib.downloadRepo(o)
    elseif util.isLocalPath(url) then
      manifestlib.downloadRepo(r)
      M.linkLocalRepo(r)
    else
      local dir = manifestlib.repoLocalDir(r)
      if util.fileExists(dir) then
        manifestlib.updateManifestCache(r)
      end
    end
  end
end

function M.getRepos()
  return _repos
end

-- Applies repo_overrides set after up.repos() ran (e.g. in a local config
-- loaded later): replaces the registered repos and caches their manifests.
local function applyRepoOverrides()
  for i, r in ipairs(_repos) do
    local o = manifestlib.override(r)
    if o ~= r then
      _repos[i] = o
      local out, code = manifestlib.downloadRepo(o)
      if code ~= 0 then
        core.error('[use-package] repo override for %s: %s', util.repoURL(r), out)
      else
        core.log_quiet('[use-package] using %s for %s', o, util.repoURL(r))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- linkLocalRepo — synchronously link all addons from a local repository
-- ---------------------------------------------------------------------------
function M.linkLocalRepo(repo)
  local url = util.repoURL(repo)
  if not util.isLocalPath(url) then return end
  local hex = util.repoDir(repo)
  local manifest = store.manifests()[hex]
  if not manifest or not manifest.addons then return end

  local config = require 'core.config'
  for _, addon in ipairs(manifest.addons) do
    if addon.id == 'use_package' then
      if addon.version and util.compareVersions(addon.version, M.VERSION) > 0 then
        local ok, err = installer.linkAddonSync(addon, hex)
        if ok then
          core.log('[use-package] upgraded use_package to newer version from repo: %s (built-in was %s)', addon.version, M.VERSION)
        else
          core.error('[use-package] failed to link newer use_package: %s', err or '?')
        end
      end
    elseif config.plugins[addon.id] ~= false then
      local stored = store.getPlugin(addon.id)
      local is_disabled = (stored and stored.enabled == false and config.plugins[addon.id] ~= true)
      if not is_disabled then
        local file_name = addon.path and (addon.path:match('[^\\/]+$') or addon.id) or addon.id
        if not pluginExistsInUserdir(file_name) then
          local ok, err = installer.linkAddonSync(addon, hex)
          if ok then
            store.addPlugin({
              plugin = addon.id,
              name = file_name,
              enabled = true,
              fullyInstalled = true,
              installMethod = 'repo',
              repo_hex = hex,
            })
          else
            core.error('[use-package] failed to link %s: %s', addon.id, err or '?')
          end
        end
      end
    end
  end
end

-- Declare a plugin.
-- plugin: string slug/URL/name, or table { plugin = '...', ... }
-- opts keys:
--   name         string   override install dir name
--   dependencies table    list of plugin specs to install first
--   run          string   post-install shell command
--   repo         string   pin to a specific registered repo URL
--   enabled      boolean  set false to disable plugin (default: true)
--   disabled     boolean  alternative to enabled = false
--   config       function runs after all plugins have loaded
--   bind         table    keybindings registered after load  { [key] = cmd }
function M.use(plugin, opts)
  opts = opts or {}
  local spec = type(plugin) == 'table' and plugin or { plugin = plugin }
  spec.plugin = spec.plugin or spec[1]
  spec.name   = spec.name or opts.name or util.plugName(spec.plugin)
  if not util.validName(spec.name) then
    core.error('[use-package] invalid plugin name: %s', tostring(spec.name))
    return
  end
  for _, k in ipairs({'run', 'repo', 'dependencies'}) do
    if opts[k] ~= nil then spec[k] = opts[k] end
  end

  local is_enabled = true
  if opts.enabled ~= nil then
    is_enabled = opts.enabled and true or false
  elseif type(plugin) == 'table' and plugin.enabled ~= nil then
    is_enabled = plugin.enabled and true or false
  elseif opts.disabled ~= nil then
    is_enabled = not opts.disabled
  elseif type(plugin) == 'table' and plugin.disabled ~= nil then
    is_enabled = not plugin.disabled
  end
  spec.enabled = is_enabled

  -- Check if already registered in _plugins; if so, update spec in place
  local found = false
  for i, s in ipairs(_plugins) do
    if s.name == spec.name or s.plugin == spec.plugin then
      _plugins[i] = spec
      found = true
      break
    end
  end
  if not found then
    table.insert(_plugins, spec)
  end

  if not is_enabled then
    local config = require 'core.config'
    config.plugins[spec.name] = false
    if pluginExists(spec.name) then
      installer.unlink(spec)
    end
    store.addPlugin(spec)
    return
  else
    local config = require 'core.config'
    if config.plugins[spec.name] == false then
      config.plugins[spec.name] = true
    end

    if not pluginExists(spec.name) then
      if util.isLocalPath(spec.plugin) then
        local ok, err = installer.linkLocalSync(spec)
        if ok then
          spec.fullyInstalled = true
          spec.installMethod = 'local'
          store.addPlugin(spec)
        else
          core.error('[use-package] failed to link %s: %s', spec.name, err or '?')
        end
      else
        local addon, hex = manifestlib.searchAddon(spec.name, nil, _repos)
        if addon and hex then
          local repo_url = util.dehexify(hex)
          local repo_dir = manifestlib.repoLocalDir(repo_url)
          if util.fileExists(repo_dir) then
            local ok, err = installer.linkAddonSync(addon, hex)
            if ok then
              spec.fullyInstalled = true
              spec.installMethod = 'repo'
              spec.repo_hex = hex
              store.addPlugin(spec)
            else
              core.error('[use-package] failed to link %s: %s', spec.name, err or '?')
            end
          end
        end
      end
    end

    if pluginExists(spec.name) and not package.loaded['plugins.' .. spec.name]
       and not coreWillLoad(spec.name) then
      pcall(require, 'plugins.' .. spec.name)
    end
  end

  -- normalise onto spec so installSingle can access them after a hot-install
  if opts.bind then spec.bind = opts.bind end
  local configFn = (type(plugin) == 'table' and plugin.config) or opts.config
  spec.config = configFn  -- nil if none; table-form already carries it

  if spec.bind then
    runOrDefer(function() keymap.add(spec.bind) end)
  end
  if configFn then
    runOrDefer(configFn)
  end
end

-- Disable a plugin concisely
function M.disable(plugin, opts)
  opts = opts or {}
  opts.enabled = false
  return M.use(plugin, opts)
end

-- Enable a plugin concisely
function M.enable(plugin, opts)
  opts = opts or {}
  opts.enabled = true
  return M.use(plugin, opts)
end

-- ---------------------------------------------------------------------------
-- Install method auto-detection
-- ---------------------------------------------------------------------------
local function detectMethod(spec)
  if spec.installMethod then return spec.installMethod end
  if util.isLocalPath(spec.plugin) then return 'local' end
  if (util.slugify(spec.plugin) or util.isURL(spec.plugin)) and not spec.repo then return 'git' end
  return 'repo'
end

-- ---------------------------------------------------------------------------
-- installSingle — install one plugin, dispatching to the right backend
-- ---------------------------------------------------------------------------
function M.installSingle(spec)
  local name = spec.name
  if not util.validName(name) then
    core.error('[use-package] invalid plugin name: %s', tostring(name))
    return
  end
  spec.installMethod = detectMethod(spec)

  local didpost = false
  local function onDone()
    if spec.run and not didpost then
      didpost = true
      installer.postRun(spec):done(onDone):fail(function(err)
        core.error('[use-package] post-run failed for %s: %s', name, err)
        spec.fullyInstalled = false
        store.addPlugin(spec)
      end)
      return
    end
    core.log('[use-package] installed %s', name)
    spec.fullyInstalled = true
    if spec.installMethod == 'repo' then
      -- record which repo hex this came from so updateRepo can find it
      local _, hex = manifestlib.searchAddon(name)
      spec.repo_hex = hex
    end
    store.addPlugin(spec)
    -- force a fresh load even if a previous attempt left a stale cache entry
    package.loaded['plugins.' .. name] = nil
    local ok, err = pcall(require, 'plugins.' .. name)
    if not ok then
      core.log('[use-package] %s loaded with warning: %s', name, err)
    end
    -- run config callback
    if spec.config then
      local ok2, err2 = pcall(spec.config)
      if not ok2 then
        core.error('[use-package] config error for %s: %s', name, err2)
      end
    end
    -- register keybindings
    if spec.bind then
      keymap.add(spec.bind)
    end
  end

  local function onFail(err)
    core.error('[use-package] failed to install %s: %s', name, err or '?')
    spec.fullyInstalled = false
    store.addPlugin(spec)
  end

  local method = spec.installMethod
  if method == 'git' then
    installer.fromGit(spec):done(onDone):fail(onFail)
  elseif method == 'local' then
    installer.fromLocal(spec):done(onDone):fail(onFail)
  else
    installer.fromRepo(spec):done(onDone):fail(onFail)
  end
end

-- ---------------------------------------------------------------------------
-- install — fetch repos, then install all missing plugins
-- ---------------------------------------------------------------------------
function M.install()
  core.add_thread(function()
    applyRepoOverrides()
    -- Step 1: download / update every registered repo manifest
    for _, repo in ipairs(_repos) do
      core.log('[use-package] setting up repo %s…', util.repoURL(repo))
      local out, code = manifestlib.downloadRepo(repo)
      if code ~= 0 then
        core.error('[use-package] could not fetch repo %s\n%s', repo, out)
      end
    end

    -- Step 2: install declared plugins
    local function installSpec(spec)
      if spec.enabled == false then
        if pluginExists(spec.name) then
          installer.unlink(spec)
        end
        return
      end

      local stored = store.getPlugin(spec.plugin) or {}
      local already = stored.fullyInstalled and pluginExists(spec.name)
      if already then
        local method = stored.installMethod or detectMethod(spec)
        local function onDone(up_to_date)
          if up_to_date then
            core.log('[use-package] %s already up to date', spec.name)
          else
            core.log('[use-package] updated %s', spec.name)
          end
        end
        local function onFail(err)
          core.error('[use-package] update failed for %s: %s', spec.name, err or '?')
        end
        if method == 'git' then
          installer.updateGit(spec):done(onDone):fail(onFail)
        elseif method == 'repo' then
          installer.updateRepo(spec):done(onDone):fail(onFail)
        end
        -- 'local' plugins are managed by the dotfile repo; no-op
        return
      end
      M.installSingle(spec)
    end

    for _, spec in ipairs(_plugins) do
      if spec.dependencies then
        for _, dep in ipairs(spec.dependencies) do
          local dspec = type(dep) == 'string' and {plugin=dep} or dep
          dspec.name  = dspec.name or util.plugName(dspec.plugin)
          installSpec(dspec)
        end
      end
      installSpec(spec)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- update — update all installed plugins
-- ---------------------------------------------------------------------------
function M.update()
  core.add_thread(function()
    applyRepoOverrides()
    -- Check if any repo provides a newer version of use_package itself
    local up_addon, up_hex = manifestlib.searchAddon('use_package', nil, _repos)
    if up_addon and up_addon.version and util.compareVersions(up_addon.version, M.VERSION) > 0 then
      local ok, err = installer.linkAddonSync(up_addon, up_hex)
      if ok then
        core.log('[use-package] updated use_package to %s', up_addon.version)
      else
        core.error('[use-package] failed to update use_package: %s', err or '?')
      end
    end

    for _, spec in ipairs(_plugins) do
      if spec.enabled ~= false then
        local name   = spec.name
        local stored = store.getPlugin(spec.plugin)

        if not pluginExists(name) then
          M.installSingle(spec)
        elseif stored then
          local method = stored.installMethod or detectMethod(spec)
          core.log('[use-package] updating %s…', name)

          local function onDone(already)
            if already then
              core.log('[use-package] %s already up to date', name)
            else
              core.log('[use-package] updated %s', name)
              spec.fullyInstalled = true
              spec.installMethod  = method
              store.addPlugin(spec)
            end
          end
          local function onFail(err)
            core.error('[use-package] update failed for %s: %s', name, err or '?')
          end

          if method == 'repo' then
            installer.updateRepo(spec):done(onDone):fail(onFail)
          elseif method == 'git' then
            installer.updateGit(spec):done(onDone):fail(onFail)
          end
          -- 'local' plugins are managed by the dotfile repo; skip
        end
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- reinstall — remove then re-install a single plugin by name
-- ---------------------------------------------------------------------------
function M.reinstall(spec)
  M.remove(spec)
  M.installSingle(spec)
end

-- ---------------------------------------------------------------------------
-- reinstallAll — reinstall every plugin that is tracked in the store
-- ---------------------------------------------------------------------------
function M.reinstallAll()
  for _, spec in ipairs(_plugins) do
    local stored = store.getPlugin(spec.plugin)
    if stored and stored.installMethod ~= 'local' and pluginExists(spec.name) then
      M.reinstall(spec)
    end
  end
end

-- ---------------------------------------------------------------------------
-- remove — delete installed files and drop from store
-- ---------------------------------------------------------------------------
function M.remove(spec)
  local name = spec.name or util.plugName(spec.plugin)
  installer.unlink(spec)
  store.removePlugin(spec.plugin or spec.name)
  core.log('[use-package] removed %s', name)
end

-- ---------------------------------------------------------------------------
-- Lite-XL commands
-- ---------------------------------------------------------------------------
command.add(nil, {
  ['use-package:install'] = function() M.install() end,
  ['use-package:update']  = function() M.update() end,
  ['use-package:reinstall'] = function() M.reinstallAll() end,

  ['use-package:disable-plugin'] = function()
    local names = {}
    for _, spec in ipairs(_plugins) do
      if spec.enabled ~= false and pluginExists(spec.name) then
        table.insert(names, spec.name)
      end
    end
    core.command_view:enter('Disable plugin', {
      submit = function(name)
        M.disable(name)
        core.log('[use-package] disabled %s (restart Lite-XL if already loaded)', name)
      end,
      suggest = function(text)
        local common = require 'core.common'
        return common.fuzzy_match(names, text)
      end,
    })
  end,

  ['use-package:enable-plugin'] = function()
    local names = {}
    local seen = {}
    for _, spec in ipairs(_plugins) do
      if spec.enabled == false or not pluginExists(spec.name) then
        if not seen[spec.name] then
          table.insert(names, spec.name)
          seen[spec.name] = true
        end
      end
    end
    for hex, manifest in pairs(store.manifests()) do
      if manifest.addons then
        for _, addon in ipairs(manifest.addons) do
          if not seen[addon.id] and (not pluginExists(addon.id) or not (store.getPlugin(addon.id) or {}).fullyInstalled) then
            table.insert(names, addon.id)
            seen[addon.id] = true
          end
        end
      end
    end
    core.command_view:enter('Enable plugin', {
      submit = function(name)
        M.enable(name)
        M.installSingle({ plugin = name, name = name, enabled = true })
        core.log('[use-package] enabled %s', name)
      end,
      suggest = function(text)
        local common = require 'core.common'
        return common.fuzzy_match(names, text)
      end,
    })
  end,

  ['use-package:toggle-plugin'] = function()
    local items = {}
    local seen = {}
    for _, spec in ipairs(_plugins) do
      local is_active = (spec.enabled ~= false and pluginExists(spec.name))
      local status = is_active and '[enabled] ' or '[disabled] '
      table.insert(items, status .. spec.name)
      seen[spec.name] = true
    end
    for hex, manifest in pairs(store.manifests()) do
      if manifest.addons then
        for _, addon in ipairs(manifest.addons) do
          if not seen[addon.id] then
            local status = pluginExists(addon.id) and '[enabled] ' or '[disabled] '
            table.insert(items, status .. addon.id)
            seen[addon.id] = true
          end
        end
      end
    end
    core.command_view:enter('Toggle plugin', {
      submit = function(item)
        local is_en = item:match('^%[enabled%]')
        local name = item:match('^%[[^%]]+%]%s*(.+)$')
        if not name then return end
        if is_en then
          M.disable(name)
          core.log('[use-package] disabled %s (restart Lite-XL if already loaded)', name)
        else
          M.enable(name)
          M.installSingle({ plugin = name, name = name, enabled = true })
          core.log('[use-package] enabled %s', name)
        end
      end,
      suggest = function(text)
        local common = require 'core.common'
        return common.fuzzy_match(items, text)
      end,
    })
  end,
})

-- ---------------------------------------------------------------------------
-- autoStartup — handle auto_install and auto_update on startup
-- ---------------------------------------------------------------------------
local _auto_startup_running = false

function M.autoStartup()
  if _auto_startup_running then return end
  core.add_thread(function()
    coroutine.yield()   -- wait for init.lua and initial plugin loading to settle

    applyRepoOverrides()

    local auto_install = config.plugins.use_package.auto_install
    local auto_update  = config.plugins.use_package.auto_update
    if not auto_install and not auto_update then return end

    _auto_startup_running = true

    -- Update repos if auto_update is enabled, or download if missing and auto_install or auto_update is enabled
    for _, repo in ipairs(_repos) do
      local url = util.repoURL(repo)
      if not util.isLocalPath(url) then
        local dir = manifestlib.repoLocalDir(repo)
        if not util.fileExists(dir) then
          if auto_install or auto_update then
            manifestlib.downloadRepo(repo)
          end
        elseif auto_update then
          manifestlib.updateRepo(repo)
        end
      end
    end

    -- Check if use_package itself can be upgraded from repos
    if auto_update then
      local up_addon, up_hex = manifestlib.searchAddon('use_package', nil, _repos)
      if up_addon and up_addon.version and util.compareVersions(up_addon.version, M.VERSION) > 0 then
        local ok, err = installer.linkAddonSync(up_addon, up_hex)
        if ok then
          core.log('[use-package] auto-updated use_package to %s', up_addon.version)
        else
          core.error('[use-package] failed to auto-update use_package: %s', err or '?')
        end
      end
    end

    -- Process declared plugins
    for _, spec in ipairs(_plugins) do
      if spec.enabled ~= false then
        local name = spec.name
        local exists = pluginExists(name)

        if not exists and auto_install then
          core.log('[use-package] auto-installing missing plugin: %s', name)
          if spec.dependencies then
            for _, dep in ipairs(spec.dependencies) do
              local dspec = type(dep) == 'string' and {plugin=dep} or dep
              dspec.name  = dspec.name or util.plugName(dspec.plugin)
              if not pluginExists(dspec.name) then
                M.installSingle(dspec)
              end
            end
          end
          M.installSingle(spec)
        elseif exists and auto_update then
          local stored = store.getPlugin(spec.plugin)
          local method = stored and stored.installMethod or detectMethod(spec)
          if stored or method == 'repo' or method == 'git' then
            local function onDone(already)
              if not already then
                core.log('[use-package] auto-updated %s', name)
                spec.fullyInstalled = true
                spec.installMethod  = method
                store.addPlugin(spec)
              end
            end
            local function onFail(err)
              core.error('[use-package] auto-update failed for %s: %s', name, err or '?')
            end

            if method == 'repo' then
              installer.updateRepo(spec):done(onDone):fail(onFail)
            elseif method == 'git' then
              installer.updateGit(spec):done(onDone):fail(onFail)
            end
          end
        end
      end
    end

    _auto_startup_running = false
  end)
end

-- Schedule autoStartup on module load
M.autoStartup()

return M
