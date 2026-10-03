-- Shared helpers for the buffer tests.
local buffer = require "buffer"

local U = {}

U.PH = "\xe2\x80\xa6\n" -- placeholder returned for lines that are not loaded

local checks = 0
function U.check(cond, msg, ...)
  checks = checks + 1
  if not cond then
    error(string.format("CHECK FAILED: " .. (msg or "?"), ...), 2)
  end
end
function U.checks() return checks end

function U.eq(a, b, msg)
  checks = checks + 1
  if a ~= b then
    local function show(s) s = tostring(s); return #s > 80 and (s:sub(1, 80) .. "...(" .. #s .. ")") or s end
    error(string.format("CHECK FAILED: %s: got <%s> expected <%s>", msg or "?", show(a), show(b)), 2)
  end
end

function U.count_lf(s)
  local n, pos = 0, 1
  while true do
    local p = s:find("\n", pos, true)
    if not p then return n end
    n = n + 1
    pos = p + 1
  end
end

-- Document text as the editor sees it (same rule as buffer.open on a file).
function U.model_text(data)
  if #data == 0 then return "\n" end
  if data:sub(-1) ~= "\n" then return data .. "\n" end
  return data
end

-- Lines of a text, each keeping its "\n".
function U.split_lines(s)
  local t, pos = {}, 1
  while true do
    local p = s:find("\n", pos, true)
    if not p then break end
    t[#t + 1] = s:sub(pos, p)
    pos = p + 1
  end
  return t
end

-- Random text. opts: crlf, final_nl (default true), longline (every n lines a very long one)
function U.gen_text(nbytes, opts)
  opts = opts or {}
  local eol = opts.crlf and "\r\n" or "\n"
  local t, total, i = {}, 0, 0
  while total < nbytes do
    i = i + 1
    local len = math.random(0, 70)
    if opts.longline and i % opts.longline == 0 then len = math.random(3000, 9000) end
    local chars = {}
    for k = 1, len do chars[k] = string.char(math.random(97, 122)) end
    local line = table.concat(chars) .. eol
    t[#t + 1] = line
    total = total + #line
  end
  local s = table.concat(t)
  if opts.final_nl == false then s = s:gsub("\r?\n$", "") end
  return s
end

function U.chunk_table(data, cs)
  local t = {}
  local pos = 1
  while pos <= #data do
    local piece = data:sub(pos, pos + cs - 1)
    t[#t + 1] = { #piece, U.count_lf(piece) }
    pos = pos + #piece
  end
  return t
end

function U.write_file(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

function U.open_remote(data, cs, extra)
  local t = { size = #data, chunks = U.chunk_table(data, cs), chunk_size = cs,
              ends_with_nl = (#data == 0) or data:sub(-1) == "\n" }
  for k, v in pairs(extra or {}) do t[k] = v end
  return buffer.open_remote(t)
end

-- Fake server: answers every queued request from `data`.
function U.pump(buf, data, max)
  local n = 0
  for _, m in ipairs(buf:missing(max or 100000)) do
    local ok, err = buf:supply(m[1], data:sub(m[2] + 1, m[2] + m[3]))
    U.check(ok, "supply failed: %s", tostring(err))
    n = n + 1
  end
  return n
end

-- Read line i, fetching whatever is needed.
function U.line(buf, data, i)
  for _ = 1, 1000 do
    local s = buf[i]
    if buf:is_resident(i) then return s end
    U.pump(buf, data)
  end
  error("line " .. i .. " never became resident")
end

function U.fulltext(buf, data)
  for _ = 1, 100000 do
    local s, err = buf:get_text(1, 1, #buf + 1, 1)
    if s then return s end
    U.check(err == "not loaded", "unexpected get_text error %s", tostring(err))
    U.pump(buf, data)
  end
  error("fulltext never loaded")
end

-- Apply an edit script to the original file contents.
function U.apply(script, inserts, orig)
  local out = {}
  for _, op in ipairs(script) do
    if op.keep then
      U.check(op.len > 0 and op.off >= 0 and op.off + op.len <= #orig, "bad keep range")
      out[#out + 1] = orig:sub(op.off + 1, op.off + op.len)
    else
      out[#out + 1] = assert(inserts[op.ins], "bad ins index")
    end
  end
  return table.concat(out)
end

function U.rss_kb()
  local f = io.open("/proc/self/status")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return tonumber(s:match("VmRSS:%s*(%d+)"))
end

return U
