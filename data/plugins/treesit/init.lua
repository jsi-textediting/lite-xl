-- mod-version:4 --priority:200

local core = require 'core'
local command = require 'core.command'
local Doc = require 'core.doc'
local Highlight = require 'core.doc.highlighter'

-- The native tree-sitter module may be missing from this build: stay inert.
local okTs, ts = pcall(require, 'libraries.tree_sitter')
if not okTs then
  core.log('treesit: libraries.tree_sitter not available, plugin disabled (%s)', tostring(ts))
  return
end

local highlights = require 'plugins.treesit.highlights'
local util = require 'plugins.treesit.util'
require 'plugins.treesit.style'
require 'plugins.treesit.builtin'()


--- @class core.doc
--- @field treesit boolean
--- @field ts table

local oldDocNew = Doc.new
function Doc:new(filename, abs_filename, new_file)
  -- Doc:new calls set_filename() before the file is loaded; initialize once afterwards.
  self._treesitNew = true
  oldDocNew(self, filename, abs_filename, new_file)
  self._treesitNew = nil
  highlights.init(self)

  self.lenAccul = { #self.lines[1] }
  self.lenAcculIdx = 1
end

local oldDocSetFilename = Doc.set_filename
function Doc:set_filename(filename, abs_filename)
  oldDocSetFilename(self, filename, abs_filename)
  if self._treesitNew or not filename then return end
  self._treesitTried = true
  -- Doc:save calls this on every save: keep the tree while the language is the same.
  if self.ts and self.ts.def == highlights.findDef(self) then return end
  highlights.init(self)
  self:invalidateLen()
  self.highlighter:reset()
end

function Doc:invalidateLen(idx)
  if not self.lenAccul or not idx or idx == 1 then
    -- (docs created before this plugin was loaded have no cache yet)
    self.lenAccul = self.lenAccul or {}
    self.lenAccul[1] = #self.lines[1]
    self.lenAcculIdx = 1
    return
  end

  -- lenAccul[idx] itself includes the changed line: keep only the entries before it.
  if self.lenAcculIdx < idx then return end

  self.lenAcculIdx = idx - 1
end

function Doc:lenLines(s, e)
  if e < s then return 0 end

  if self.lenAcculIdx < e then
    for i = self.lenAcculIdx + 1, e do
      self.lenAccul[i] = self.lenAccul[i - 1] + #self.lines[i]
    end

    self.lenAcculIdx = e
  end

  return s == 1 and self.lenAccul[e] or self.lenAccul[e] - self.lenAccul[s - 1]
end

local function isPending(doc)
  local inject = doc.ts.inject
  return doc.ts.reparse or (inject and inject.pending) or false
end

-- After the main tree is parsed, the injected language (if any) is parsed in
-- the ranges of its nodes.
local function startInjection(doc)
  local inject = doc.ts.inject
  local ok, err = pcall(function()
    local ranges = highlights.injectionRanges(inject, doc.ts.tree)
    inject.parser:reset()
    if #ranges > 0 then
      inject.parser:set_included_ranges(ts.Range.Array.new(ranges))
      inject.pending = true
    else
      -- no ranges would mean the whole document to tree-sitter
      inject.tree = nil
      inject.pending = false
    end
  end)
  if not ok then
    doc.ts.inject = nil
    core.error('treesit: injection disabled for %s: %s', doc.filename or 'document', tostring(err))
  end
end

-- One time boxed (maxParseTime) parse step; returns true while parsing is not done.
local function reparseStep(doc)
  local dts = doc.ts
  if dts.reparse then
    local newTree = dts.parser:parse(dts.tree, util.input(doc.lines))
    if not newTree then return true end

    dts.tree = newTree
    dts.reparse = false
    if dts.inject then startInjection(doc) end
  end

  local inject = dts.inject
  if inject and inject.pending then
    local newTree = inject.parser:parse(nil, util.input(doc.lines))
    if not newTree then return true end

    inject.tree = newTree
    inject.pending = false
  end

  dts.running = false
  doc.highlighter:reset()
  return false
end

-- Keep resuming the parse from a thread until it completes.
local function ensureReparseThread(doc)
  if doc.ts.running or core.threads[doc] then return end
  doc.ts.running = true

  core.add_thread(function()
    while doc.treesit and doc.ts and isPending(doc) and reparseStep(doc) do
      coroutine.yield(0)
    end
    if doc.ts then doc.ts.running = false end
  end, doc)
end

highlights.onPending = function(doc)
  -- try parsing once immediately, so if the document is not too large,
  -- the highlighting is ready for the first frame
  if reparseStep(doc) then ensureReparseThread(doc) end
end

-- Edits only update the trees: the reparse (and the highlighter reset) runs
-- once for all the edits of an operation (replace all, multi-cursor, undo
-- groups), on the next highlighter get_line or reparse thread step.
local function scheduleReparse(doc)
  doc.ts.reparse = true
  doc.ts.stepped = false
  doc.ts.parser:reset()
  ensureReparseThread(doc)
end

local function editTrees(doc, ...)
  if doc.ts.tree then doc.ts.tree:edit(...) end
  local inject = doc.ts.inject
  if inject and inject.tree then inject.tree:edit(...) end
end

local function getEndPoint(startLine, startCol, text)
  local nlCount = 0
  local lastNl = 0
  while true do
    local pos = text:find('\n', lastNl + 1, true)
    if not pos then break end
    nlCount = nlCount + 1
    lastNl = pos
  end
  if nlCount == 0 then
    return ts.Point.new(startLine, startCol + #text)
  else
    local lastLineLen = #text - lastNl
    return ts.Point.new(startLine + nlCount, lastLineLen)
  end
end

local oldDocInsert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo, time)
  local res = oldDocInsert(self, line, col, text, undo, time)
  -- refused (remote document): nothing changed
  if res == false then return false end

  if self.treesit then
    self:invalidateLen(line)

    line, col = self:sanitize_position(line, col)

    local tsByte = self:lenLines(1, line - 1) + col - 1
    local tsLine, tsCol = line - 1, col - 1
    local startPoint = ts.Point.new(tsLine, tsCol)

    editTrees(self,
      --[[start_byte   ]] tsByte,
      --[[old_end_byte ]] tsByte,
      --[[new_end_byte ]] tsByte + #text,
      --[[start_point  ]] startPoint,
      --[[old_end_point]] startPoint,
      --[[new_end_point]] getEndPoint(tsLine, tsCol, text)
    )

    scheduleReparse(self)
  end
  return res
end

local function sortPositions(line1, col1, line2, col2)
  if line1 > line2 or line1 == line2 and col1 > col2 then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end

local oldDocRemove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo, time)
  if not self.treesit then
    return oldDocRemove(self, line1, col1, line2, col2, undo, time)
  end

  line1, col1 = self:sanitize_position(line1, col1)
  line2, col2 = self:sanitize_position(line2, col2)
  line1, col1, line2, col2 = sortPositions(line1, col1, line2, col2)

  local len = line1 == line2 and
    col2 - col1 or
    #self.lines[line1] - col1 + self:lenLines(line1 + 1, line2 - 1) + col2

  local res = oldDocRemove(self, line1, col1, line2, col2, undo, time)
  -- refused (remote document): nothing changed
  if res == false then return false end

  self:invalidateLen(line1)

  local tsByte = self:lenLines(1, line1 - 1) + col1 - 1
  local startPoint = ts.Point.new(line1 - 1, col1 - 1)

  editTrees(self,
    --[[start_byte   ]] tsByte,
    --[[old_end_byte ]] tsByte + len,
    --[[new_end_byte ]] tsByte,
    --[[start_point  ]] startPoint,
    --[[old_end_point]] ts.Point.new(line2 - 1, col2 - 1),
    --[[new_end_point]] startPoint
  )

  scheduleReparse(self)
  return res
end

local oldDocReload = Doc.reload
function Doc:reload()
  oldDocReload(self)

  -- The file type or size may have changed: start over.
  highlights.init(self)
  self:invalidateLen()
  self.highlighter:reset()
end

local oldStart = Highlight.start
function Highlight:start(...)
  local doc = self.doc

  if not doc.treesit then return oldStart(self, ...) end
  if isPending(doc) then ensureReparseThread(doc) end
end

local function pushToken(toks, type, text)
  if not text or #text == 0 then return end
  local n = #toks
  if n > 0 and toks[n - 1] == type then
    toks[n] = toks[n] .. text
  else
    toks[n + 1] = type
    toks[n + 2] = text
  end
end

-- Append the captures of `tree` intersecting `row` as { startPos, endPos, name, layer, seq },
-- with 1-based inclusive columns clipped to the line.
local function collectCaptures(out, query, tree, runner, row, txt, layer)
  local cursor = ts.Query.Cursor.new(query, tree:root_node())
  cursor:set_point_range(ts.Point.new(row, 0), ts.Point.new(row, #txt - 1))

  for capture in runner:iter_captures(cursor) do
    local name = capture:name()

    -- only skip captures whose name begins with '_', not any capture containing '_'
    if name:sub(1, 1) == '_' then goto continue end

    local node    = capture:node()
    local startPt = node:start_point()
    local endPt   = node:end_point()

    if row > endPt:row() then goto continue end
    if row < startPt:row() then break end

    local startPos = startPt:row() < row and 1 or (startPt:column() + 1)
    local endPos   = endPt:row() > row and #txt or endPt:column()

    if startPos > #txt then goto continue end
    if endPos < startPos then goto continue end

    out[#out + 1] = { startPos, endPos, name, layer, #out + 1 }

    ::continue::
  end
end

-- Captures start in order; at the same start the outer (main) layer comes first,
-- so the injected captures nest inside it.
local function captureOrder(a, b)
  if a[1] ~= b[1] then return a[1] < b[1] end
  if a[4] ~= b[4] then return a[4] < b[4] end
  return a[5] < b[5]
end

-- (here and not in tokenize_line: the highlighter thread calls tokenize_line
-- in a loop that would overwrite the state of a highlighter reset)
local oldGetLine = Highlight.get_line
function Highlight:get_line(idx)
  local doc = self.doc
  -- Lazy retry: if Doc:new ran before use-package config registered languages,
  -- attempt init once on the first render.
  if not doc.treesit and not doc._treesitTried then
    doc._treesitTried = true
    highlights.init(doc)
    if doc.treesit then
      doc:invalidateLen()
      self:reset()
    end
  end

  -- Edits are batched: parse once (time boxed) before tokenizing their lines,
  -- the reparse thread finishes the job if needed.
  if doc.treesit and not doc.ts.stepped and isPending(doc) then
    doc.ts.stepped = true
    if reparseStep(doc) then ensureReparseThread(doc) end
  end
  return oldGetLine(self, idx)
end

local oldTokenize = Highlight.tokenize_line
function Highlight:tokenize_line(idx, state, resume)
  local doc = self.doc
  if not doc.treesit or not doc.ts.tree then return oldTokenize(self, idx, state, resume) end

  local txt      = doc.lines[idx]
  local row      = idx - 1
  local toks     = {}
  state = state or string.char(0)

  if not txt or #txt == 0 then
    return {
      init_state = state,
      state      = state,
      text       = txt or '',
      tokens     = toks
    }
  end

  -- Stack of active scopes: array of { [1] = type_1, [2] = end_col_1, ... }
  -- Bottom scope is 'normal' covering the entire line
  local buf      = { 'normal', #txt }
  local startBuf = 1

  local okIter, iterErr = pcall(function()
    local caps = {}
    collectCaptures(caps, doc.ts.query, doc.ts.tree, doc.ts.runner, row, txt, 1)
    local inject = doc.ts.inject
    if inject and inject.tree then
      collectCaptures(caps, inject.query, inject.tree, inject.runner, row, txt, 2)
      table.sort(caps, captureOrder)
    end

    for _, cap in ipairs(caps) do
      local startPos, endPos, name = cap[1], cap[2], cap[3]

      -- Pop expired scopes from the stack
      while #buf > 2 and buf[#buf] < startPos do
        local topEnd = buf[#buf]
        local topType = buf[#buf - 1]
        buf[#buf] = nil
        buf[#buf] = nil
        if topEnd >= startBuf then
          pushToken(toks, topType, txt:sub(startBuf, topEnd))
          startBuf = topEnd + 1
        end
      end

      -- Emit text under current top scope up to startPos - 1
      if startPos > startBuf then
        pushToken(toks, buf[#buf - 1], txt:sub(startBuf, startPos - 1))
        startBuf = startPos
      end

      buf[#buf + 1] = name
      buf[#buf + 1] = endPos
    end
  end)

  if not okIter then
    -- A bad predicate/pattern must not break rendering: use the built-in
    -- highlighter for this doc (toggle treesit to retry) and report once.
    doc.treesit = false
    core.error('treesit: highlighting disabled for %s: %s', doc.filename or 'document', tostring(iterErr))
    core.add_thread(function() doc.highlighter:reset() end)
    return oldTokenize(self, idx, state, resume)
  end

  -- Pop and flush remaining scopes
  while #buf >= 2 do
    local topEnd = buf[#buf]
    local topType = buf[#buf - 1]
    buf[#buf] = nil
    buf[#buf] = nil
    local finish = math.min(topEnd, #txt)
    if finish >= startBuf then
      pushToken(toks, topType, txt:sub(startBuf, finish))
      startBuf = finish + 1
    end
  end

  if startBuf <= #txt then
    pushToken(toks, 'normal', txt:sub(startBuf, #txt))
  end

  return {
    init_state = state,
    state      = state,
    text       = txt,
    tokens     = toks
  }
end

command.add('core.docview!', {
  ['treesit:toggle-highlighting'] = function(dv)
    local doc = dv.doc
    if doc.treesit then
      doc.treesit = false
    elseif doc.ts then
      -- Edits were not tracked while off: the old tree is stale, rebuild it.
      highlights.init(doc)
    else
      return
    end
    doc.highlighter:reset()
    doc:invalidateLen()
  end
})
