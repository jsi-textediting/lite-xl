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
  if r == nil then
    local ok, compiled = pcall(regex.compile, pattern)
    r = (ok and compiled) or false
    regexCache[pattern] = r
  end
  return r or nil
end

local function predicatesFor(doc)
  local function getSource(n)
    if not n then return '' end
    local startPt = n:start_point()
    local endPt   = n:end_point()
    local startRow, startCol = startPt:row() + 1, startPt:column() + 1
    local endRow, endCol     = endPt:row() + 1, endPt:column() + 1

    return doc:get_text(startRow, startCol, endRow, endCol)
  end

  local function coerceToStr(n)
    if type(n) ~= 'string' then
      local node = n:one_node()
      return node and getSource(node) or ''
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
      local node = n:one_node()
      if not node then return false end
      local ts = {}
      for _, t in ipairs {...} do
        ts[t] = true
      end

      local a = node:parent()
      while a do
        if ts[a:type()] then return true end
        a = a:parent()
      end

      return false
    end,

    ['has-parent?'] = function(n, ...)
      local node = n:one_node()
      if not node then return false end
      local parent = node:parent()
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

    -- nvim: `(#is-not? local)` asserts a node *property* (set by locals/set!),
    -- not a text comparison. No properties are tracked here, so it holds.
    ['is-not?'] = function()
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
        local node = n:one_node()
        if not node or not kinds[node:type()] then return false end
      end
      return true
    end,

    ['any-kind-eq?'] = function(ns, ...)
      local kinds = {}
      for _, k in ipairs {...} do kinds[k] = true end
      for _, n in ipairs(ns:nodes()) do
        local node = n:one_node()
        if node and kinds[node:type()] then return true end
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

local queryCache = {}

local disabledCaptures = {
  'spell',
  'nospell',
  'conceal',
}

-- Compiled queries are immutable and shared by every doc of the language.
local function compileQuery(langDef, lang, queryStr)
  local query = queryCache[langDef.name]
  if query ~= nil then return query or nil end
  local okQ, q = pcall(ts.Query.new, lang, queryStr)
  if not okQ or not q then
    queryCache[langDef.name] = false  -- report once per language
    core.error('treesit: failed to compile %s highlights query: %s', langDef.name, tostring(q))
    return nil
  end
  for _, name in ipairs(disabledCaptures) do
    q:disable_capture(name)
  end
  queryCache[langDef.name] = q
  return q
end

local function loadLang(langDef)
  local lang = languages.getLang(langDef)
  if not lang then
    core.log_quiet('treesit: failed to load parser for %s', langDef.name)
    return nil
  end

  local queryStr = languages.getQuery(langDef, 'highlights')
  if not queryStr then
    core.log_quiet('treesit: failed to load query for %s', langDef.name)
    return nil
  end

  local query = compileQuery(langDef, lang, queryStr)
  if not query then return nil end
  return lang, query
end

-- Languages parsed inside the nodes of another one (nvim-treesitter injections.scm).
-- The injected nodes are parsed together, as one tree using included ranges.
local INJECTIONS = {
  markdown = { lang = 'markdown_inline', nodes = '[(inline) (pipe_table_cell)] @injection' },
}

local nodesQueryCache = {}
local nodesRunner = ts.Query.Runner.new({})

local function initInjection(doc, langDef, lang)
  local inj = INJECTIONS[langDef.name]
  if not inj then return nil end
  local injDef = languages.defs[inj.lang]
  if not injDef then return nil end
  local injLang, injQuery = loadLang(injDef)
  if not injLang then return nil end

  local nodesQuery = nodesQueryCache[langDef.name]
  if nodesQuery == nil then
    local okQ, q = pcall(ts.Query.new, lang, inj.nodes)
    if not okQ or not q then
      core.error('treesit: failed to compile %s injection query: %s', langDef.name, tostring(q))
      q = false
    end
    nodesQuery = q
    nodesQueryCache[langDef.name] = nodesQuery
  end
  if not nodesQuery then return nil end

  local parser = ts.Parser.new()
  parser:set_language(injLang)
  parser:set_timeout_micros(config.maxParseTime)

  return {
    parser     = parser,
    query      = injQuery,
    runner     = ts.Query.Runner.new(predicatesFor(doc)),
    nodesQuery = nodesQuery,
    tree       = nil,
    pending    = false,
  }
end

-- Ranges of the injected nodes of `tree`, minus their named children (as nvim does
-- by default, e.g. the `> ` block continuations of a quote are not inline content).
function M.injectionRanges(inj, tree)
  local ranges = {}
  local lastEnd = -1
  local function add(sb, sp, eb, ep)
    if eb <= sb or sb < lastEnd then return end
    ranges[#ranges + 1] = ts.Range.new(sp, ep, sb, eb)
    lastEnd = eb
  end

  local cursor = ts.Query.Cursor.new(inj.nodesQuery, tree:root_node())
  for capture in nodesRunner:iter_captures(cursor) do
    local node = capture:node()
    local sb, sp = node:start_byte(), node:start_point()
    for i = 0, node:named_child_count() - 1 do
      local child = node:named_child(i)
      add(sb, sp, child:start_byte(), child:start_point())
      sb, sp = child:end_byte(), child:end_point()
    end
    add(sb, sp, node:end_byte(), node:end_point())
  end

  return ranges
end

--- @param doc core.doc
function M.findDef(doc)
  local fname = doc.abs_filename or doc.filename
  if not fname then return nil end
  return languages.findDef(fname, doc.lines[1])
end

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

  local langDef = M.findDef(doc)
  if not langDef then
    core.log_quiet('treesit: no lang def for %s', fname)
    return
  end

  local lang, query = loadLang(langDef)
  if not lang then return end

  local parser = ts.Parser.new()
  parser:set_language(lang)
  parser:set_timeout_micros(config.maxParseTime)

  doc.treesit = true
  doc.ts = {
    def = langDef,
    parser = parser,
    tree = nil,
    query = query,
    runner = ts.Query.Runner.new(predicatesFor(doc)),
    inject = initInjection(doc, langDef, lang),
    reparse = true,
  }
  -- may leave the parse pending when it does not finish within maxParseTime
  if M.onPending then M.onPending(doc) end

  core.log_quiet('treesit: highlight enabled for %s (%s)', doc.filename, langDef.name)
end


return M
