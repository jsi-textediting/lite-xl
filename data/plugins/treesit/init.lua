-- mod-version:4 --priority:200

local core = require 'core'
local command = require 'core.command'
local Doc = require 'core.doc'
local Highlight = require 'core.doc.highlighter'
local highlights = require 'plugins.treesit.highlights'
local util = require 'plugins.treesit.util'
local ts = require 'libraries.tree_sitter'
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
  highlights.init(self)
  self:invalidateLen()
  self.highlighter:reset()
end

function Doc:invalidateLen(idx)
  if not idx or idx == 1 then
    self.lenAccul[1] = #self.lines[1]
    self.lenAcculIdx = 1
    return
  end

  if self.lenAcculIdx <= idx then return end

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

local function reparseStep(doc)
  local newTree = doc.ts.parser:parse(doc.ts.tree, util.input(doc.lines))

  if not newTree then return true end

  doc.ts.tree = newTree
  doc.ts.reparse = false
  doc.ts.running = false

  doc.highlighter:reset()
  return false
end

-- Parsing is time boxed (maxParseTime); keep resuming it from a thread until it completes.
local function ensureReparseThread(doc)
  if doc.ts.running or core.threads[doc] then return end
  doc.ts.running = true

  core.add_thread(function()
    while doc.treesit and doc.ts.reparse and reparseStep(doc) do
      coroutine.yield(0)
    end
    doc.ts.running = false
  end, doc)
end

highlights.onPending = ensureReparseThread

local function reparse(doc)
  doc.ts.reparse = true
  doc.ts.parser:reset()
  -- try parsing once immediately, so if the document is not too large,
  -- the highlighting can be updated before the next frame
  if reparseStep(doc) then ensureReparseThread(doc) end
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
  oldDocInsert(self, line, col, text, undo, time)

  if self.treesit then
    self:invalidateLen(line)

    line, col = self:sanitize_position(line, col)

    local tsByte = self:lenLines(1, line - 1) + col - 1
    local tsLine, tsCol = line - 1, col - 1
    local endPoint = getEndPoint(tsLine, tsCol, text)

    if self.ts.tree then
      self.ts.tree:edit(
        --[[start_byte   ]] tsByte,
        --[[old_end_byte ]] tsByte,
        --[[new_end_byte ]] tsByte + #text,
        --[[start_point  ]] ts.Point.new(tsLine, tsCol),
        --[[old_end_point]] ts.Point.new(tsLine, tsCol),
        --[[new_end_point]] endPoint
      )
    end

    reparse(self)
  end
end

local function sortPositions(line1, col1, line2, col2)
  if line1 > line2 or line1 == line2 and col1 > col2 then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end

local oldDocRemove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo, time)
  if self.treesit then
    line1, col1 = self:sanitize_position(line1, col1)
    line2, col2 = self:sanitize_position(line2, col2)
    line1, col1, line2, col2 = sortPositions(line1, col1, line2, col2)

    local len = line1 == line2 and
      col2 - col1 or
      #self.lines[line1] - col1 + self:lenLines(line1 + 1, line2 - 1) + col2

    oldDocRemove(self, line1, col1, line2, col2, undo, time)
    self:invalidateLen(line1)

    local tsByte = self:lenLines(1, line1 - 1) + col1 - 1

    if self.ts.tree then
      self.ts.tree:edit(
        --[[start_byte   ]] tsByte,
        --[[old_end_byte ]] tsByte + len,
        --[[new_end_byte ]] tsByte,
        --[[start_point  ]] ts.Point.new(line1 - 1, col1 - 1),
        --[[old_end_point]] ts.Point.new(line2 - 1, col2 - 1),
        --[[new_end_point]] ts.Point.new(line1 - 1, col1 - 1)
      )
    end

    reparse(self)
  else
    oldDocRemove(self, line1, col1, line2, col2, undo, time)
  end
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
  if doc.ts.reparse then ensureReparseThread(doc) end
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

local oldTokenize = Highlight.tokenize_line
function Highlight:tokenize_line(idx, state)
  -- Lazy retry: if Doc:new ran before use-package config registered languages,
  -- attempt init once on the first render.
  if not self.doc.treesit and not self.doc._treesitTried then
    self.doc._treesitTried = true
    highlights.init(self.doc)
    if self.doc.treesit then
      self.doc.highlighter:reset()
    end
  end
  if not self.doc.treesit or not self.doc.ts.tree then return oldTokenize(self, idx, state) end

  local txt      = self.doc.lines[idx]
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

  local cursor = ts.Query.Cursor.new(self.doc.ts.query, self.doc.ts.tree:root_node())
  cursor:set_point_range(ts.Point.new(row, 0), ts.Point.new(row, #txt - 1))

  for capture in self.doc.ts.runner:iter_captures(cursor) do
    local node = capture:node()
    local name = capture:name()

    -- fix: only skip captures whose name begins with '_', not any capture containing '_'
    if name:sub(1, 1) == '_' then goto continue end

    local startPt = node:start_point()
    local endPt   = node:end_point()

    if row > endPt:row() then goto continue end
    if row < startPt:row() then break end

    local startPos = startPt:row() < row and 1 or (startPt:column() + 1)
    local endPos   = endPt:row() > row and #txt or endPt:column()

    if startPos > #txt then goto continue end
    if endPos < startPos then goto continue end

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

    ::continue::
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
    if dv.doc.ts then
      dv.doc.treesit = not dv.doc.treesit
      dv.doc.highlighter:reset()
      dv.doc:invalidateLen()
    end
  end
})
