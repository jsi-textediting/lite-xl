local common = require 'core.common'
local json   = require 'plugins.use_package.json'
local util   = require 'plugins.use_package.util'

local STORE_FILE = USERDIR .. '/.use-package-store'

-- in-memory manifests keyed by hex-encoded repo URL (without tag)
local manifests = {}

local data = {
  plugins = {},
  repos   = {},
}

local M = {}

function M.init()
  if util.fileExists(STORE_FILE) then
    local ok, loaded = pcall(dofile, STORE_FILE)
    if ok and loaded then
      data = loaded
      -- Reload any previously cached manifest JSON
      for hex, entry in pairs(data.repos or {}) do
        if entry.manifest_json then
          local ok2, decoded = pcall(json.decode, entry.manifest_json)
          if ok2 then manifests[hex] = decoded end
        end
      end
    end
  end
end

-- Only plain-data fields are persisted; specs also carry functions (config)
-- and tables (bind, dependencies) that must stay in memory only.
local PERSIST_FIELDS = {
  'plugin', 'name', 'enabled', 'fullyInstalled', 'installMethod',
  'repo', 'repo_hex', 'run', 'library',
}

local function snapshot()
  local plugins = {}
  for id, spec in pairs(data.plugins or {}) do
    local t = {}
    for _, k in ipairs(PERSIST_FIELDS) do
      local v = spec[k]
      local tv = type(v)
      if tv == 'string' or tv == 'boolean' or tv == 'number' then t[k] = v end
    end
    plugins[id] = t
  end
  return { plugins = plugins, repos = data.repos or {} }
end

function M.write()
  local ok, text = pcall(common.serialize, snapshot())
  if not ok then return end
  -- write to a temp file then rename so a crash never leaves a truncated store
  local tmp = STORE_FILE .. '.tmp'
  local f = io.open(tmp, 'wb')
  if not f then return end
  local wrote = f:write('return ' .. text)
  f:close()
  if not wrote then os.remove(tmp) return end
  if not os.rename(tmp, STORE_FILE) then
    os.remove(STORE_FILE)  -- Windows cannot rename over an existing file
    if not os.rename(tmp, STORE_FILE) then os.remove(tmp) end
  end
end

function M.addPlugin(spec)
  data.plugins[spec.plugin] = spec
  M.write()
end

function M.getPlugin(id)
  return data.plugins[id]
end

function M.removePlugin(id)
  data.plugins[id] = nil
  M.write()
end

-- Cache a parsed manifest for a repo. `hex` is the hex-encoded URL without tag.
-- `manifest_text` is the raw JSON string (stored so it survives restarts).
function M.addRepo(hex, manifest_text)
  if not data.repos then data.repos = {} end
  -- unchanged manifest: already decoded at init/previous call, skip the rewrite
  local cur = data.repos[hex]
  if cur and cur.manifest_json == manifest_text and manifests[hex] then return end
  local ok, decoded = pcall(json.decode, manifest_text)
  if not ok then return end
  data.repos[hex] = { manifest_json = manifest_text }
  manifests[hex] = decoded
  M.write()
end

-- Returns all in-memory parsed manifests keyed by hex.
function M.manifests()
  return manifests
end

return M
