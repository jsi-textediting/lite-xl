local common = require 'core.common'
local M = {}

function M.expandPath(p)
  if not p then return nil end

  -- Expand Windows environment variables: %VAR%
  p = p:gsub('%%([%a_][%w_]*)%%', function(var)
    local val = os.getenv(var)
    return (val and #val > 0) and val:gsub('\\', '/') or ('%' .. var .. '%')
  end)

  -- Expand Unix environment variables: ${VAR} and $VAR with XDG fallbacks
  local function getUnixEnv(var)
    local val = os.getenv(var)
    if val and #val > 0 then
      return val:gsub('\\', '/')
    elseif var == 'XDG_DATA_HOME' then
      local h = os.getenv('HOME')
      return h and (h:gsub('\\', '/') .. '/.local/share') or '~/.local/share'
    elseif var == 'XDG_CONFIG_HOME' then
      local h = os.getenv('HOME')
      return h and (h:gsub('\\', '/') .. '/.config') or '~/.config'
    end
    return nil
  end

  p = p:gsub('%${([%a_][%w_]*)}', function(var)
    local val = getUnixEnv(var)
    return val or ('${' .. var .. '}')
  end)
  p = p:gsub('%$([%a_][%w_]*)', function(var)
    local val = getUnixEnv(var)
    return val or ('$' .. var)
  end)

  -- Expand ~
  p = common.home_expand(p)

  -- Normalize slashes
  p = p:gsub('\\', '/')
  return p
end

-- Directory this plugin was loaded from (<datadir>/plugins/treesit or <userdir>/plugins/treesit).
local pluginDir = (debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\][^/\\]+$') or ''):gsub('\\', '/')

--- Directories searched for compiled grammars, in priority order:
--- user configured ones first, then the ones bundled with the editor.
function M.getParserSearchDirs(extraDir, cfg)
  local dirs = {}
  local seen = {}
  local function add(p)
    if not p then return end
    local exp = M.expandPath(p)
    if exp and not seen[exp] then
      seen[exp] = true
      dirs[#dirs + 1] = exp
    end
  end

  add(extraDir)
  for _, d in ipairs(cfg and cfg.parserDirs or {}) do add(d) end
  add(USERDIR .. '/libraries/treesitter/parser')
  add(DATADIR .. '/libraries/treesitter/parser')

  return dirs
end

--- Directories holding `<lang>/highlights.scm`, in priority order.
function M.getQueryDirs(cfg)
  local dirs = {}
  local seen = {}
  local function add(p)
    if not p then return end
    local exp = M.expandPath(p)
    if exp and not seen[exp] then
      seen[exp] = true
      dirs[#dirs + 1] = exp
    end
  end

  for _, d in ipairs(cfg and cfg.queryDirs or {}) do add(d) end
  add(USERDIR .. '/plugins/treesit/queries')
  add(pluginDir .. '/queries')
  add(DATADIR .. '/plugins/treesit/queries')

  return dirs
end

--- Locate `<lang>/<queryType>.scm` in the query search path.
function M.findQuery(cfg, lang, queryType)
  for _, d in ipairs(M.getQueryDirs(cfg)) do
    local path = d .. '/' .. lang .. '/' .. queryType .. '.scm'
    if system.get_file_info(path) then return path end
  end
  return nil
end

function M.joinPath(parts)
  local str = ''
  local sepPattern = string.format('%s$', '%' .. PATHSEP)
  for i, part in ipairs(parts) do
    local sepMatch = part:match(sepPattern)
    str = str .. part .. (sepMatch or i == #parts and '' or PATHSEP)
  end
  str = str:gsub(string.format('%s$', '%' .. PATHSEP), '')

  return str
end

function M.flatten(parts, dest)
  dest = dest or {}

  for _, part in ipairs(parts) do
    if type(part) == 'table' then
      M.flatten(part, dest)
    else
      dest[#dest + 1] = part
    end
  end

  return dest
end

function M.input(lines)
  return function(_, point)
    if point:row() < #lines then
      return lines[point:row() + 1], point:column() + 1
    else
      return nil
    end
  end
end

return M
