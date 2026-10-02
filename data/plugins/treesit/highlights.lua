local core = require 'core'
local config = require 'plugins.treesit.config'
local languages = require 'plugins.treesit.languages'
local util = require 'plugins.treesit.util'
local ts = require 'libraries.tree_sitter'

local M = {}

-- Set by init.lua: called with a doc whose first parse did not finish in time.
M.onPending = nil

local regexCache = {}
local function getCompiledRegex(pattern)
  local r = regexCache[pattern]
  if not r then
    local ok, compiled = pcall(regex.compile, pattern)
    if ok and compiled then
      r = compiled
      regexCache[pattern] = r
    end
  end
  return r
end

local function predicatesFor(doc)
  local function getSource(n)
    local startPt = n:start_point()
    local endPt   = n:end_point()
    local startRow, startCol = startPt:row() + 1, startPt:column() + 1
    local endRow, endCol     = endPt:row() + 1, endPt:column() + 1

    return doc:get_text(startRow, startCol, endRow, endCol)
  end

  local function coerceToStr(n)
    if type(n) ~= 'string' then
      return getSource(n:one_node())
    else
      return n
    end
  end

  local predicates = {
    ['eq?'] = function(ns, m)
      local str = coerceToStr(m)

      for _, n in ipairs(ns:nodes()) do
        if getSource(n) ~= str then return false end
      end
      return true
    end,

    ['any-eq?'] = function(ns, m)
      local str = coerceToStr(m)

      for _, n in ipairs(ns:nodes()) do
        if getSource(n) == str then return true end
      end

      return false
    end,

    ['match?'] = function(ns, s)
      local r = getCompiledRegex(s)
      if not r then return false end

      for _, n in ipairs(ns:nodes()) do
        if not r:cmatch(getSource(n), 0, 0) then return false end
      end

      return true
    end,

    ['any-match?'] = function(ns, s)
      local r = getCompiledRegex(s)
      if not r then return false end

      for _, n in ipairs(ns:nodes()) do
        if r:cmatch(getSource(n), 0, 0) then return true end
      end

      return false
    end,

    ['lua-match?'] = function(ns, p)
      for _, n in ipairs(ns:nodes()) do
        if not getSource(n):match(p) then return false end
      end

      return true
    end,

    ['any-lua-match?'] = function(ns, p)
      for _, n in ipairs(ns:nodes()) do
        if getSource(n):match(p) then return true end
      end

      return false
    end,

    ['contains?'] = function(ns, ...)
      local ts = {...}

      for _, n in ipairs(ns:nodes()) do
        local s = getSource(n)

        for _, t in ipairs(ts) do
          if not s:find(t, 1, true) then return false end
        end
      end

      return true
    end,

    ['any-contains?'] = function(ns, ...)
      local ts = {...}

      for _, n in ipairs(ns:nodes()) do
        local s = getSource(n)

        for _, t in ipairs(ts) do
          if s:find(t, 1, true) then return true end
        end
      end

      return false
    end,

    ['any-of?'] = function(ns, ...)
      local ts = {}
      for _, t in ipairs {...} do
        ts[t] = true
      end

      for _, n in ipairs(ns:nodes()) do
        if not ts[getSource(n)] then return false end
      end

      return true
    end,

    ['has-ancestor?'] = function(n, ...)
      local ts = {}
      for _, t in ipairs {...} do
        ts[t] = true
      end

      local a = n:one_node():parent()
      while a do
        if ts[a:type()] then return true end
        a = a:parent()
      end

      return false
    end,

    ['has-parent?'] = function(n, ...)
      -- fix: guard against nil when node is the root (has no parent)
      local parent = n:one_node():parent()
      if not parent then return false end
      local p = parent:type()

      for _, t in ipairs {...} do
        if p == t then return true end
      end

      return false
    end,

    ['set!'] = function()
      return true
    end,

    ['offset!'] = function()
      return true
    end,

    ['trim!'] = function()
      return true
    end,

    ['downcase!'] = function()
      return true
    end,

    ['gsub!'] = function()
      return true
    end,

    ['is-not?'] = function(ns, m)
      local str = coerceToStr(m)
      for _, n in ipairs(ns:nodes()) do
        if getSource(n) == str then return false end
      end
      return true
    end,

    -- Neovim Vim-regex predicate; alias to lua-match? (close enough for common patterns)
    ['vim-match?'] = function(ns, p)
      for _, n in ipairs(ns:nodes()) do
        if not getSource(n):match(p) then return false end
      end
      return true
    end,

    ['any-vim-match?'] = function(ns, p)
      for _, n in ipairs(ns:nodes()) do
        if getSource(n):match(p) then return true end
      end
      return false
    end,

    -- nvim-treesitter predicate: check node kind (AST type)
    ['kind-eq?'] = function(ns, ...)
      local kinds = {}
      for _, k in ipairs {...} do kinds[k] = true end
      for _, n in ipairs(ns:nodes()) do
        if not kinds[n:one_node():type()] then return false end
      end
      return true
    end,

    ['any-kind-eq?'] = function(ns, ...)
      local kinds = {}
      for _, k in ipairs {...} do kinds[k] = true end
      for _, n in ipairs(ns:nodes()) do
        if kinds[n:one_node():type()] then return true end
      end
      return false
    end,
  }

  local ret = {}

  for name, fn in pairs(predicates) do
    ret[name] = fn

    if name:sub(-1) == '?' then
      ret['not-' .. name] = function(...)
        return not fn(...)
      end
    end
  end

  setmetatable(ret, {
    __index = function(_, k)
      if type(k) == 'string' and k:sub(-1) == '!' then
        return function() return true end
      end
      return nil
    end,
  })

  return ret
end

local disabledCaptures = {
  'spell',
  'nospell',
  'conceal',
}

--- @param doc core.doc
function M.init(doc)
  -- Drop any previous state: the document may have changed file type or size.
  doc.treesit = false
  doc.ts = nil

  local fname = doc.abs_filename or doc.filename
  if not fname then return end
  if not config.enabled then return end

  -- Large documents keep the built-in highlighter: they may be backed by the
  -- native piece-tree buffer, which has no cheap byte-offset lookup.
  if doc.large_file or doc.buffer or #doc.lines > config.maxLines then
    core.log_quiet('treesit: %s is too large, skipping', doc.filename or fname)
    return
  end

  local langDef = languages.findDef(fname)
  if not langDef then
    core.log_quiet('treesit: no lang def for %s', fname)
    return
  end

  local lang = languages.getLang(langDef)
  if not lang then
    core.log_quiet('treesit: failed to load parser for %s (%s)', doc.filename, langDef.name)
    return
  end

  local queryStr = languages.getQuery(langDef, 'highlights')
  if not queryStr then
    core.log_quiet('treesit: failed to load query for %s (%s)', doc.filename, langDef.name)
    return
  end

  local okQ, query = pcall(ts.Query.new, lang, queryStr)
  if not okQ or not query then
    core.log_quiet('treesit: failed to compile query for %s: %s', doc.filename, tostring(query))
    return
  end
  for _, name in ipairs(disabledCaptures) do
    query:disable_capture(name)
  end

  local parser = ts.Parser.new()
  parser:set_language(lang)
  parser:set_timeout_micros(config.maxParseTime)

  doc.treesit = true
  doc.ts = {
    parser = parser,
    -- nil when parsing did not finish within maxParseTime, see M.onPending
    tree = parser:parse(nil, util.input(doc.lines)),
    query = query,
    runner = ts.Query.Runner.new(predicatesFor(doc)),
  }
  doc.ts.reparse = doc.ts.tree == nil
  if doc.ts.reparse and M.onPending then M.onPending(doc) end

  core.log_quiet('treesit: highlight enabled for %s (%s)', doc.filename, langDef.name)
end


return M
