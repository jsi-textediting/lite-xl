local core = require 'core'
local command = require 'core.command'
local common = require 'core.common'
local Doc = require 'core.doc'
local config = require 'plugins.treesit.config'
local util = require 'plugins.treesit.util'
local ts = require 'libraries.tree_sitter'

local M = {
  defs = {},
  langCache = {},
  queryCache = {
    highlights = {},
  },
}

local soExt = PLATFORM == 'Windows' and '.dll' or '.so'

-- Grammars to try, in order, when the parser for a language is not installed.
local LANGUAGE_FALLBACKS = {
  objcpp          = { 'objc', 'cpp', 'c' },
  objc            = { 'c' },
  cpp             = { 'c' },
  cuda            = { 'cpp', 'c' },
  arduino         = { 'cpp', 'c' },
  typescript      = { 'javascript' },
  tsx             = { 'typescript', 'javascript' },
  jsx             = { 'javascript' },
  vimdoc          = { 'vim' },
  markdown_inline = { 'markdown' },
  json5           = { 'json' },
  jsonc           = { 'json' },
  kotlin          = { 'java' },
  c_sharp         = { 'csharp' },
  csharp          = { 'c_sharp' },
  php_only        = { 'php' },
}

-- Search for a compiled parser in the configured and bundled directories.
local function findParser(dir, name)
  for _, d in ipairs(util.getParserSearchDirs(dir, config)) do
    for _, ext in ipairs { soExt, '.so', '.dylib' } do
      local path = d .. '/' .. name .. ext
      if system.get_file_info(path) then return path end
    end
  end
  return nil
end

-- Locate the grammar and highlights query of an addLang() definition. Done on
-- first use (getLang/getQuery) so startup does no filesystem lookups per language.
local function resolve(def)
  local opts = def._lazy
  if not opts then return end
  def._lazy = nil

  local name = def.name
  local parserName = opts.parserName or name
  local queryName  = opts.queryName or parserName
  local fallbacks  = LANGUAGE_FALLBACKS[name]
  local soFile     = findParser(nil, parserName)

  -- No grammar for this language: borrow a compatible one (e.g. cpp -> c).
  if not soFile and not opts.parserName and fallbacks then
    for _, fb in ipairs(fallbacks) do
      local fbFile = findParser(nil, fb)
      if fbFile then
        soFile     = fbFile
        parserName = fb
        queryName  = opts.queryName or fb
        break
      end
    end
  end

  local queryPath = util.findQuery(config, queryName, 'highlights')
  if not queryPath and fallbacks then
    for _, fb in ipairs(fallbacks) do
      queryPath = util.findQuery(config, fb, 'highlights')
      if queryPath then
        queryName = fb
        break
      end
    end
  end

  def.langName   = parserName
  def.soFile     = soFile
  def.queryFiles = { highlights = queryPath }
end

--- Register a language whose grammar and queries are looked up (lazily) in the
--- parser/query search path.
--- @param opts table `name` (required), `files` (list of filename patterns),
---   `parserName` and `queryName` to override the grammar/query name.
function M.addLang(opts)
  local name = opts.name
  assert(name, 'name is required for addLang')
  assert(not M.defs[name], 'Duplicate language name: ' .. name)

  local def = {
    name          = name,
    langName      = opts.parserName or name,
    files         = opts.files,
    queryFiles    = {},
    fallbackChain = LANGUAGE_FALLBACKS[name],
    _lazy         = opts,
  }

  M.defs[#M.defs + 1] = def
  M.defs[def.name] = def
end

--- Register a language from explicit paths.
--- @param defOptions table `name`, `path` (directory), `files`, `soFile`, `queryFiles.highlights`.
function M.addDef(defOptions)
  local def = {}

  assert(defOptions.name, 'Name is required for language definition')
  assert(not M.defs[defOptions.name], 'Duplicate language name')
  assert(defOptions.path, 'Path is required for language definition')

  def.name = defOptions.name
  def.files = defOptions.files

  local path = util.expandPath(defOptions.path)

  if defOptions.files and #defOptions.files > 0 then
    def.soFile = util.joinPath {
      path,
      defOptions.soFile and
        defOptions.soFile:gsub('{SOEXT}', soExt) or
        'parser' .. soExt
    }
  end

  def.queryFiles = {}

  -- queryFiles.highlights may be a string or an ordered list of strings
  local hl = defOptions.queryFiles and defOptions.queryFiles.highlights
  if type(hl) == 'table' then
    def.queryFiles.highlights = {}
    for _, p in ipairs(hl) do
      def.queryFiles.highlights[#def.queryFiles.highlights + 1] =
        util.joinPath { path, p }
    end
  else
    def.queryFiles.highlights = util.joinPath {
      path,
      hl or 'queries/highlights.scm'
    }
  end

  M.defs[#M.defs + 1] = def
  M.defs[def.name] = def
end

function M.findDef(filename)
  if not filename then return nil end
  local bestScore = 0
  local bestDef

  for i = #M.defs, 1, -1 do
    local def = M.defs[i]
    if not def.files then goto continue end

    for _, pattern in ipairs(def.files) do
      local s, e = filename:find(pattern)
      if not s then goto continue end

      local score = e - s
      if score > bestScore then
        bestScore = score
        bestDef = def
      end

      ::continue::
    end

    ::continue::
  end

  return bestDef
end

function M.getLang(def)
  local lang = M.langCache[def.name]
  if lang then
    return lang
  end
  resolve(def)

  local soFile = def.soFile
  local langName = def.langName or def.name

  if not soFile or not system.get_file_info(soFile) then
    -- Dynamic check in case the parser was installed after startup
    local freshFile = findParser(def.parserDir, def.name)
    if freshFile then
      soFile = freshFile
      langName = def.name
      def.soFile = soFile
      def.langName = langName
    elseif def.fallbackChain then
      for _, fb in ipairs(def.fallbackChain) do
        local fbFile = findParser(def.parserDir, fb)
        if fbFile then
          soFile = fbFile
          langName = fb
          def.soFile = soFile
          def.langName = langName
          break
        end
      end
    end
  end

  if not soFile or not system.get_file_info(soFile) then
    core.log_quiet('treesit: parser not found for %s, falling back to built-in syntax', def.name)
    return nil
  end

  local ok, result = pcall(ts.Language.load, soFile, langName)
  if not ok then
    core.log_quiet('treesit: error loading language %s from %s: %s', def.name, tostring(soFile), tostring(result))
    return nil
  end

  M.langCache[def.name] = result
  core.log_quiet('treesit: loaded language %s (using parser %s)', def.name, langName)

  return result
end

-- Append the query at `path` to the builder, preceded by the queries of the
-- languages named in its `; inherits: lang1,lang2` header.
local function loadQueryFile(path, builder, queryType, visited)
  local f = io.open(path)
  if not f then return false end
  local content = f:read '*a'
  f:close()

  -- Header comment block with modelines
  for head in content:gmatch '[^\r\n]*' do
    if not head:match '^%s*;' then break end

    local rest = head:match '^%s*;+%s*inherits%s*:%s*(.*)'
    if rest then
      for name in rest:gmatch '[%l%d_]+' do
        local parentPath = util.findQuery(config, name, queryType)
        if not parentPath then
          core.warn(
            'Could not find language %s to inherit queries from. \z
            Syntax highlighting may be incomplete.',
            name
          )
        elseif not visited[parentPath] then
          visited[parentPath] = true
          builder[#builder + 1] = '; TREESIT: INHERIT ' .. name .. '\n'
          loadQueryFile(parentPath, builder, queryType, visited)
        end
      end
    end
  end

  builder[#builder + 1] = content
  builder[#builder + 1] = '\n'
  return true
end

function M.getQuery(def, queryType)
  local query = M.queryCache[queryType][def.name]
  if query then
    return query
  end
  resolve(def)

  local paths = def.queryFiles[queryType]
  -- Normalise to a list
  if type(paths) == 'string' then
    paths = { paths }
  end

  if not paths or #paths == 0 then
    core.log_quiet('treesit: no %s query configured for %s', queryType, def.name)
    return nil
  end

  local builder = { '; TREESIT: BEGIN ' .. def.name .. '\n' }

  for _, path in ipairs(paths) do
    if not loadQueryFile(path, builder, queryType, { [path] = true }) then
      core.error('Error loading ' .. def.name .. ' ' .. queryType .. ' query: ' .. path)
      return nil
    end
  end

  builder[#builder + 1] = '; TREESIT: END ' .. def.name .. '\n'

  query = table.concat(builder)
  M.queryCache[queryType][def.name] = query
  core.log_quiet('treesit: loaded %s %s query', def.name, queryType)

  return query
end

local queryRecents = {}

command.add(nil, {
  ['treesit:view-highlights-query'] = function()
    core.command_view:enter('View highlights query for language', {
      submit = function(name)
        local def = M.defs[name]
        if not def then
          core.error('No such language %s', name)
          return
        end

        local query = M.getQuery(def, 'highlights')
        if not query then
          core.error('No highlights query for %s', name)
          return
        end
        -- scratch doc without a filename: never touches a real highlights.scm
        local doc = Doc()
        doc:insert(1, 1, query)
        doc:clean()
        core.root_view:open_doc(doc)
      end,

      suggest = function(name)
        local names = {}
        for _, def in ipairs(M.defs) do
          names[#names + 1] = def.name
        end

        return common.fuzzy_match_with_recents(names, queryRecents, name)
      end,
    })
  end,
})

return M
