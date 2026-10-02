local store = require 'plugins.use_package.store'
local util  = require 'plugins.use_package.util'

local M = {}

local REPOS_DIR = util.normPath(USERDIR .. '/up-repos')

local function repoLocalDir(repo)
  local url = util.repoURL(repo)
  if util.isLocalPath(url) then
    return url
  end
  return util.join({REPOS_DIR, util.repoDir(repo)})
end

-- Read manifest.json from the cloned or local repo and cache it in the store.
local function updateManifestCache(repo)
  local dir = repoLocalDir(repo)
  local f = io.open(dir .. '/manifest.json')
  if not f then return end
  local content = f:read('*a')
  f:close()
  store.addRepo(util.repoDir(repo), content)
end

-- Clone the repo if remote and not present, then checkout the pinned tag.
-- For local paths, directly validates and caches manifest.json.
-- Returns (output, exit_code).
function M.downloadRepo(repo)
  local url = util.repoURL(repo)
  local tag = util.repoTag(repo)
  local dir = repoLocalDir(repo)

  if tag and tag:sub(1, 1) == '-' then
    return '[use-package] invalid tag: ' .. tag, -1
  end

  if util.isLocalPath(url) then
    if not util.fileExists(url .. '/manifest.json') then
      return string.format('[use-package] local manifest not found: %s/manifest.json', url), -1
    end
    updateManifestCache(repo)
    return '', 0
  end

  system.mkdir(REPOS_DIR)   -- ensure parent exists on first run

  if not util.fileExists(dir) then
    if not util.validCloneURL(url) then
      return '[use-package] unsupported repository URL: ' .. url, -1
    end
    local out, code = util.exec({'git', 'clone', '--quiet', '--', url, dir})
    if code ~= 0 then
      return out, code
    end
  end

  if tag then
    -- cross-platform checkout using git -C instead of sh -c
    local out, code = util.gitCmd({'checkout', '--quiet', tag, '--'}, dir)
    if code ~= 0 then
      return out, code
    end
  end

  updateManifestCache(repo)
  return '', 0
end

-- Pull the latest changes for an already-cloned repo, then re-cache the manifest.
-- If repo is not yet cloned, downloads it first.
-- For local paths, simply refreshes the cached manifest.
local updating = {}   -- repo dir -> true while an update runs
local updated  = {}   -- repo dir -> {time=, res={...}} of the last successful update
local RECENT   = 60   -- seconds a successful update is reused

local doUpdateRepo

-- Several plugins share one repo and are updated from separate threads at
-- startup. Concurrent git fetches on one repo interleave their FETCH_HEAD
-- writes, and `pull --ff-only` then fails with "Cannot fast-forward to
-- multiple branches". So run one update per repo at a time and let the
-- others reuse its result.
function M.updateRepo(repo)
  local dir = repoLocalDir(repo)
  while updating[dir] do coroutine.yield() end
  local last = updated[dir]
  if last and system.get_time() - last.time < RECENT then
    return table.unpack(last.res, 1, 3)
  end
  updating[dir] = true
  local res = table.pack(pcall(doUpdateRepo, repo))
  updating[dir] = nil
  if not res[1] then error(res[2], 0) end
  if res[3] == 0 then
    updated[dir] = { time = system.get_time(), res = { res[2], res[3], res[4] } }
  end
  return res[2], res[3], res[4]
end

doUpdateRepo = function(repo)
  local url = util.repoURL(repo)
  if util.isLocalPath(url) then
    updateManifestCache(repo)
    return '', 0
  end
  local dir = repoLocalDir(repo)
  if not util.fileExists(dir) then
    return M.downloadRepo(repo)
  end
  local tag = util.repoTag(repo)
  local before = util.gitHead(dir)
  local out, code
  if tag then
    -- A pinned tag leaves HEAD detached, where `git pull` fails: fetch, then checkout.
    out, code = util.gitCmd({'fetch', '--quiet', '--tags', '--prune'}, dir)
    if code == 0 then
      out, code = util.gitCmd({'checkout', '--quiet', tag, '--'}, dir)
    end
    if code == 0 then
      -- if the pin is a branch, move it forward; harmless failure on a tag
      util.gitCmd({'merge', '--quiet', '--ff-only', '@{u}'}, dir)
    end
  else
    out, code = util.gitCmd({'pull', '--quiet', '--ff-only'}, dir)
  end
  if code == 0 then
    updateManifestCache(repo)
  end
  return out, code, before ~= util.gitHead(dir)
end

M.updateManifestCache = updateManifestCache

-- Search all cached manifests (or a specific one if repo_hex is given) for an
-- addon whose id matches `name`.  Returns (addon_table, repo_hex) or (nil, nil).
function M.searchAddon(name, repo_hex, repos_list)
  local all = store.manifests()
  local function search_one(hex, manifest)
    if not manifest or not manifest.addons then return nil end
    for _, addon in ipairs(manifest.addons) do
      if addon.id == name then
        return addon
      end
    end
  end

  if repo_hex then
    local addon = search_one(repo_hex, all[repo_hex])
    return addon, addon and repo_hex or nil
  end

  if repos_list then
    for _, r in ipairs(repos_list) do
      local hex = util.repoDir(r)
      local addon = search_one(hex, all[hex])
      if addon then return addon, hex end
    end
  end

  for hex, manifest in pairs(all) do
    local addon = search_one(hex, manifest)
    if addon then return addon, hex end
  end
  return nil, nil
end

-- Return the filesystem path for the root of a cached repo clone.
function M.repoLocalDir(repo)
  return repoLocalDir(repo)
end

return M
