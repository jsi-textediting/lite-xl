-- Regression tests for the existing local buffer API (mmap + heap pieces).
local buffer = require "buffer"
local U = require "util"

math.randomseed(1234)
local TMP = os.getenv("TMPDIR") or "/tmp"
local path = TMP .. "/buffer_remote_basic.txt"

-- offset (0-based) -> line, col of a model text
local function locate(text, off)
  local line, start = 1, 0
  local pos = 1
  while true do
    local p = text:find("\n", pos, true)
    if not p or p > off then break end
    line = line + 1
    start = p
    pos = p + 1
  end
  return line, off - start + 1
end

-- 1. open / read / empty / no trailing newline
do
  local data = U.gen_text(300000)
  U.write_file(path, data)
  local b = buffer.open(path)
  local lines = U.split_lines(data)
  U.eq(#b, #lines, "line count")
  for i = 1, #lines, 7 do U.eq(b[i], lines[i], "line " .. i) end
  U.eq(b:get_text(1, 1, #b + 1, 1), data, "full text")
  U.check(b[0] == nil and b[#b + 1] == nil, "out of range is nil")
end
do
  U.write_file(path, "")
  local b = buffer.open(path)
  U.eq(#b, 1, "empty file lines"); U.eq(b[1], "\n", "empty file line")
  U.write_file(path, "abc")
  b = buffer.open(path)
  U.eq(#b, 1, "no-nl lines"); U.eq(b[1], "abc\n", "no-nl text")
  local nb = buffer.new()
  U.eq(#nb, 1, "new() lines")
end

-- 2. random edits against a model, including removals spanning several pieces
for seed = 1, 3 do
  math.randomseed(seed)
  local data = U.gen_text(250000)
  U.write_file(path, data)
  local b = buffer.open(path)
  local model = data
  for step = 1, 400 do
    local r = math.random()
    if r < 0.5 or #model < 5000 then
      local off = math.random(0, #model - 1)
      local l, c = locate(model, off)
      local txt = ({ "x", "hello\nworld\n", "\n", "abc", string.rep("q", 100) })[math.random(5)]
      U.check(b:insert(l, c, txt), "insert")
      model = model:sub(1, off) .. txt .. model:sub(off + 1)
    else
      local o1 = math.random(0, #model - 2)
      local o2 = math.min(#model - 1, o1 + math.random(0, r < 0.8 and 200 or 150000))
      local l1, c1 = locate(model, o1)
      local l2, c2 = locate(model, o2)
      U.check(b:remove(l1, c1, l2, c2), "remove")
      model = model:sub(1, o1) .. model:sub(o2 + 1)
    end
    if step % 50 == 0 then
      U.eq(b:get_text(1, 1, #b + 1, 1), model, "seed " .. seed .. " step " .. step)
      U.eq(#b, U.count_lf(model), "line count after edits")
    end
  end
  -- save round trip
  U.check(b:save(path), "save")
  local f = assert(io.open(path, "rb")); local saved = f:read("a"); f:close()
  U.eq(saved, model, "saved file")
end

os.remove(path)
print(string.format("test_basic OK (%d checks)", U.checks()))
