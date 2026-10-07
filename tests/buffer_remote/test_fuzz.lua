-- Randomised edit sequences on remote buffers compared against a plain string
-- model, with a fake lazy fetcher, tiny cache budgets, random eviction,
-- cancelled/partial fetches, stale toggling, edit-script and rebase round trips.
local buffer = require "buffer"
local U = require "util"

local STEPS = tonumber(os.getenv("FUZZ_STEPS")) or 300
local SEEDS = tonumber(os.getenv("FUZZ_SEEDS")) or 2

local configs = {
  { cs = 97,   budget = 10, size = 60000 },
  { cs = 777,  budget = 10, size = 120000 },
  { cs = 4096, budget = 10, size = 150000 },
  { cs = 997,  budget = 60, size = 120000, longline = 9 },
  { cs = 500,  budget = 12, size = 80000, crlf = true, final_nl = false },
  { cs = 333,  budget = 100000, size = 50000 },
  { cs = 64,   budget = 12, size = 4000, small = true },
  { cs = 1,    budget = 6000, size = 300, small = true },
}

local function make_starts(model)
  local starts, pos = { 0 }, 1
  while true do
    local p = model:find("\n", pos, true)
    if not p then break end
    starts[#starts + 1] = p
    pos = p + 1
  end
  starts[#starts] = nil -- last start would be past the final newline
  return starts
end

local function locate(starts, off)
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if starts[mid] <= off then lo = mid else hi = mid - 1 end
  end
  return lo, off - starts[lo] + 1
end

local function run(cfg, seed)
  math.randomseed(seed * 7919 + cfg.cs)
  local data = U.gen_text(cfg.size, cfg)
  local model = U.model_text(data)
  local cs = cfg.cs
  local buf = U.open_remote(data, cs, { budget = cfg.budget * cs })
  local stats = { refused = 0, edits = 0, rebases = 0 }

  local function partial_pump()
    local m = buf:missing(1000)
    for i, e in ipairs(m) do
      if i == 1 or math.random() < 0.7 then
        U.check(buf:supply(e[1], data:sub(e[2] + 1, e[2] + e[3])))
      else
        buf:cancel(e[1])
      end
    end
  end

  -- run an edit, retrying like the fetch pump would; refused attempts must change nothing
  local function edit(f)
    for _ = 1, 200 do
      local size0, lines0 = buf:stats().size, #buf
      local ok, err = f()
      if ok then return true end
      U.last_err = err
      U.eq(err, "not loaded", "only retryable failure expected")
      U.eq(buf:stats().size, size0, "refused edit changed size")
      U.eq(#buf, lines0, "refused edit changed lines")
      stats.refused = stats.refused + 1
      partial_pump()
    end
    error(string.format("edit never succeeded (cs=%d seed=%d last err=%s)", cs, seed, tostring(U.last_err)))
  end

  local function check_all(tag)
    local mlines = U.split_lines(model)
    U.eq(#buf, #mlines, tag .. ": line count")
    U.eq(buf:stats().size, #model, tag .. ": size")
    for _ = 1, 15 do
      local i = math.random(#mlines)
      U.eq(U.line(buf, data, i), mlines[i], tag .. ": line " .. i)
    end
    U.eq(U.line(buf, data, 1), mlines[1], tag .. ": first line")
    U.eq(U.line(buf, data, #mlines), mlines[#mlines], tag .. ": last line")
    local st = buf:stats()
    U.check(st.resident_bytes <= st.budget + st.pinned_bytes + st.held_bytes,
      "resident bytes %d over budget %d (+%d pinned, +%d held)", st.resident_bytes, st.budget, st.pinned_bytes,
      st.held_bytes)
    local script, inserts = buf:edit_script()
    U.eq(U.apply(script, inserts, data), model, tag .. ": edit script applied to the original file")
    for i = 2, #script do
      local p, q = script[i - 1], script[i]
      U.check(not (p.keep and q.keep and p.off + p.len == q.off), "uncoalesced keeps")
    end
  end

  for step = 1, STEPS do
    local starts = make_starts(model)
    local r = math.random()
    if r < 0.40 then
      -- insert
      local off = math.random(0, #model - 1)
      if math.random() < 0.1 then off = 0 elseif math.random() < 0.1 then off = #model - 1 end
      local l, c = locate(starts, off)
      local txt = ({ "x", "hello\nworld\n", "\n", "", "abc", "\n\n", string.rep("q", math.random(1, 3 * cs)),
                     "mixed\r\n", "tail\nno" })[math.random(9)]
      edit(function() return buf:insert(l, c, txt) end)
      model = model:sub(1, off) .. txt .. model:sub(off + 1)
      stats.edits = stats.edits + 1
    elseif r < 0.85 then
      -- remove (never the final newline, as the document model guarantees)
      local o1 = math.random(0, #model - 1)
      local span = ({ 0, 1, 5, 60, 200, 3 * cs, 40 * cs })[math.random(7)]
      local o2 = math.min(#model - 1, o1 + math.random(0, span))
      if math.random() < 0.15 then -- whole line(s)
        local li = locate(starts, o1)
        o1 = starts[li]
        local lj = math.min(#starts, li + math.random(0, 3))
        o2 = math.min(#model - 1, (starts[lj + 1] or #model) )
      end
      local l1, c1 = locate(starts, o1)
      local l2, c2 = locate(starts, o2)
      edit(function() return buf:remove(l1, c1, l2, c2) end)
      model = model:sub(1, o1) .. model:sub(o2 + 1)
      stats.edits = stats.edits + 1
    elseif r < 0.90 then
      -- random eviction / pin churn
      local idx = math.random(1, buf:stats().chunks)
      local ok, err = buf:evict(idx)
      U.check(ok or err == "pinned", "evict result %s", tostring(err))
    elseif r < 0.93 then
      -- stale window
      buf:set_stale(true)
      local ok, err = buf:insert(1, 1, "z")
      U.check(ok == false and err == "stale", "stale insert")
      local sc = buf:edit_script()
      local has_keep = false
      for _, op in ipairs(sc) do if op.keep then has_keep = true end end
      if has_keep then
        local gt, ge = buf:get_text(1, 1, #buf + 1, 1)
        U.check(gt == nil and ge == "stale", "stale full read")
      end
      U.eq(#buf:missing(), 0, "stale: no requests")
      buf:set_stale(false)
    elseif r < 0.95 and #model > 0 then
      -- "save": script must reproduce the model, then rebase onto it
      local script, inserts = buf:edit_script()
      U.eq(U.apply(script, inserts, data), model, "pre-rebase script")
      data = model
      U.check(buf:rebase(#data, U.chunk_table(data, cs), true), "rebase")
      stats.rebases = stats.rebases + 1
      U.eq(buf:stats().resident, 0, "rebase drops cache")
    else
      -- just scroll somewhere
      local i = math.random(#buf)
      U.line(buf, data, i)
    end
    if step % 25 == 0 then check_all("seed " .. seed .. " cs " .. cs .. " step " .. step) end
  end
  check_all("final")
  -- final full text through get_text, both ways
  -- (a plain get_text can only succeed when the whole range fits the budget)
  if cfg.budget * cs >= #model + cs then U.eq(U.fulltext(buf, data), model, "final get_text") end
  local calls = 0
  local buf2 = buf
  U.eq(buf2:get_text(1, 1, #buf2 + 1, 1, function(i, o, l) calls = calls + 1; return data:sub(o + 1, o + l) end), model,
    "final get_text with sync_fn")
  return stats
end

for _, cfg in ipairs(configs) do
  for seed = 1, SEEDS do
    local st = run(cfg, seed)
    print(string.format("  cs=%-5d seed=%d edits=%d refused(retried)=%d rebases=%d", cfg.cs, seed, st.edits, st.refused, st.rebases))
  end
end
print(string.format("test_fuzz OK (%d checks)", U.checks()))
