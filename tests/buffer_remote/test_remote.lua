-- Deterministic tests for BUFFER_SRC_REMOTE.
local buffer = require "buffer"
local U = require "util"

math.randomseed(42)
local TMP = os.getenv("TMPDIR") or "/tmp"
local PH = U.PH

local function timeit(f)
  local t = os.clock()
  local r = f()
  return os.clock() - t, r
end

local function same_as_local(data, cs, label)
  local path = TMP .. "/buffer_remote_local.txt"
  U.write_file(path, data)
  local lb = buffer.open(path)
  local rb = U.open_remote(data, cs)
  U.eq(#rb, #lb, label .. ": line count parity with local buffer")
  for i = 1, #lb do U.eq(U.line(rb, data, i), lb[i], label .. ": line " .. i) end
  U.eq(U.fulltext(rb, data), lb:get_text(1, 1, #lb + 1, 1), label .. ": full text")
  os.remove(path)
  return rb
end

-- 1. Reading every line, parity with the local engine --------------------------------
for _, cs in ipairs({ 4096, 997, 64, 1 + 4093 }) do
  same_as_local(U.gen_text(200000), cs, "plain cs=" .. cs)
  same_as_local(U.gen_text(100000, { final_nl = false }), cs, "no final nl cs=" .. cs)
  same_as_local(U.gen_text(100000, { crlf = true }), cs, "crlf cs=" .. cs)
  same_as_local(U.gen_text(100000, { crlf = true, final_nl = false }), cs, "crlf no nl cs=" .. cs)
  same_as_local(U.gen_text(60000, { longline = 7 }), cs, "long lines cs=" .. cs)
end
same_as_local("", 4096, "empty file")
same_as_local("\n", 4096, "single newline")
same_as_local("\n\n\n", 2, "newlines only")
same_as_local("x", 4096, "one char")
same_as_local("abc", 1, "one byte chunks, no nl")
do -- a file that is a single line spanning many chunks
  local data = string.rep("0123456789", 5000)
  local rb = same_as_local(data, 100, "single huge line")
  U.eq(#rb, 1, "one line")
end

-- 2. Lazy open: no data access, placeholders, queue, dedupe --------------------------
do
  local data = U.gen_text(100000)
  local cs = 4096
  local rb = U.open_remote(data, cs)
  local st = rb:stats()
  U.eq(st.resident, 0, "nothing resident after open")
  U.eq(st.queued, 0, "nothing queued after open")
  U.eq(st.chunks, math.ceil(#data / cs), "chunk count")
  U.check(rb:is_remote(), "is_remote")
  U.check(not rb:is_resident(1), "line 1 not resident")
  U.eq(st.queued, 0, "is_resident never queues")
  U.eq(rb:stats().queued, 0, "is_resident did not queue")

  U.eq(rb[1], PH, "placeholder for line 1")
  U.check(PH:sub(-1) == "\n", "placeholder ends in newline")
  U.eq(rb[1], PH, "placeholder again")
  local miss = rb:missing()
  U.eq(#miss, 1, "line 1 requests exactly chunk 1 (deduped)")
  U.eq(miss[1][1], 1, "idx is 1-based"); U.eq(miss[1][2], 0, "orig_off"); U.eq(miss[1][3], cs, "len")
  U.eq(#rb:missing(), 0, "queue drained")
  U.eq(rb[1], PH, "still placeholder while pending")
  U.eq(#rb:missing(), 0, "pending chunk is not re-queued")
  U.eq(U.pump(rb, data), 0, "nothing more to pump")
  -- fulfil it
  U.check(rb:supply(1, data:sub(1, cs)), "supply chunk 1")
  U.eq(rb:stats().resident, 1, "one resident")
  U.eq(rb[1], U.split_lines(data)[1], "line 1 after supply")
  -- cancel & re-request
  U.eq(rb[#rb], PH, "last line is a placeholder")
  local m = rb:missing()
  U.check(#m >= 1, "last line requests chunks")
  for _, e in ipairs(m) do U.check(rb:cancel(e[1]), "cancel") end
  U.eq(rb[#rb], PH, "placeholder after cancel")
  U.eq(#rb:missing(), #m, "cancelled chunks can be requested again")
  -- max
  local rb2 = U.open_remote(data, cs)
  for i = 1, #rb2, 30 do local _ = rb2[i] end
  local a = rb2:missing(2)
  U.eq(#a, 2, "missing(max)")
  U.check(#rb2:missing() >= 1, "rest still queued")
end

-- 3. supply validation ----------------------------------------------------------------
do
  local data = U.gen_text(20000)
  local rb = U.open_remote(data, 1000)
  local good = data:sub(1, 1000)
  local ok, err = rb:supply(1, good:sub(1, 999))
  U.check(ok == false and err:find("length"), "short data rejected: %s", tostring(err))
  local bad = good:gsub("\n", "x", 1)
  if bad == good then bad = good:sub(1, 999) .. "\n" end -- force an lf mismatch
  if U.count_lf(bad) == U.count_lf(good) then bad = good:sub(1, 998) .. "\n\n" end
  ok, err = rb:supply(1, bad)
  U.check(ok == false and err:find("newline"), "lf mismatch rejected: %s", tostring(err))
  ok, err = rb:supply(0, good)
  U.check(ok == false and err:find("index"), "index 0 rejected")
  ok, err = rb:supply(9999, good)
  U.check(ok == false and err:find("index"), "index too big rejected")
  U.eq(rb:stats().resident, 0, "nothing stored by failed supplies")
  U.check(rb:supply(1, good), "valid supply")
  U.check(rb:supply(1, good), "duplicate supply is harmless")
  U.eq(rb:stats().resident_bytes, 1000, "resident bytes")
  local lb = buffer.new()
  ok, err = lb:supply(1, "x")
  U.check(ok == false, "supply on local buffer fails")
  U.check(#lb:missing() == 0, "missing on local buffer is empty")
end

-- 4. A line spanning chunks: placeholder + every covering chunk queued -----------------
do
  local data = "first\n" .. string.rep("a", 3500) .. "\nlast\n"
  local rb = U.open_remote(data, 1000)
  U.eq(rb[2], PH, "long line placeholder")
  local idxs = {}
  for _, m in ipairs(rb:missing()) do idxs[m[1]] = true end
  -- the chunks holding the line's boundary newlines are needed first to locate it
  U.check(idxs[1] and idxs[4], "boundary chunks queued")
  for idx in pairs(idxs) do rb:supply(idx, data:sub((idx - 1) * 1000 + 1, idx * 1000)) end
  -- now that the line is located every covering chunk still missing is queued at once
  U.eq(rb[2], PH, "still a placeholder while the middle is missing")
  idxs = {}
  for _, m in ipairs(rb:missing()) do idxs[m[1]] = true end
  U.check(idxs[2] and idxs[3], "middle chunks queued together")
  for idx in pairs(idxs) do rb:supply(idx, data:sub((idx - 1) * 1000 + 1, idx * 1000)) end
  U.eq(U.line(rb, data, 2), string.rep("a", 3500) .. "\n", "long line content")
  U.eq(rb[1], "first\n", "line 1")
  U.eq(rb[3], "last\n", "line 3")
end

-- 5. Edits that need bytes ---------------------------------------------------------------
do
  local data = U.gen_text(60000)
  local cs = 1000
  local model = data
  local rb = U.open_remote(data, cs)
  -- inserting at the very start needs no data at all
  U.check(rb:insert(1, 1, "HEAD"), "insert at start needs no bytes")
  model = "HEAD" .. model
  U.eq(rb:stats().resident, 0, "still nothing resident")
  -- inserting in the middle of a non-resident chunk is refused and requests the chunk
  local ok, err = rb:insert(30, 3, "zz")
  U.check(ok == false and err == "not loaded", "mid-chunk insert on non-resident chunk: %s", tostring(err))
  U.check(rb:stats().queued >= 1, "failed insert queued chunks")
  local s, e = rb:get_text(1, 1, 2, 1)
  U.check(s == nil and e == "not loaded", "get_text error")
  -- failed edits change nothing
  U.pump(rb, data)
  U.eq(U.fulltext(rb, data), model, "text unchanged by refused edits")
  -- once the chunks are resident the edit works (retry like the fetch pump would)
  local line, col = 30, 3
  local lines = U.split_lines(model)
  local off = 0
  for i = 1, line - 1 do off = off + #lines[i] end
  off = off + col - 1
  local rb_ = rb
  rb_:evict(1)
  local done
  for _ = 1, 10 do
    local ok1, err1 = rb:insert(line, col, "zz")
    if ok1 then done = true break end
    U.eq(err1, "not loaded", "retryable error")
    U.pump(rb, data)
  end
  U.check(done, "insert after fetch")
  model = model:sub(1, off) .. "zz" .. model:sub(off + 1)
  U.eq(U.fulltext(rb, data), model, "text after insert")
  local st = rb:stats()
  U.check(st.pinned >= 1, "edit pinned its chunk")
  -- removal across many chunks needs data only at its two ends
  local rb2 = U.open_remote(data, cs)
  local l1, l2 = 5, #rb2 - 5
  local refused = 0
  local done2
  for _ = 1, 10 do
    local ok2, err2 = rb2:remove(l1, 2, l2, 3)
    if ok2 then done2 = true break end
    U.eq(err2, "not loaded", "retryable error")
    refused = refused + 1
    U.pump(rb2, data)
  end
  U.check(done2 and refused >= 1, "removal refused until its boundary chunks are loaded")
  U.check(rb2:stats().resident <= 6, "middle chunks never loaded (%d resident)", rb2:stats().resident)
  local ls = U.split_lines(data)
  local o1, o2 = 0, 0
  for i = 1, l1 - 1 do o1 = o1 + #ls[i] end
  for i = 1, l2 - 1 do o2 = o2 + #ls[i] end
  o1 = o1 + 1; o2 = o2 + 2
  local m2 = data:sub(1, o1) .. data:sub(o2 + 1)
  U.eq(U.fulltext(rb2, data), U.model_text(m2), "text after big removal")
end

-- 6. sync_fn -----------------------------------------------------------------------------------
do
  local data = U.gen_text(30000)
  local rb = U.open_remote(data, 700)
  local calls = 0
  local function fetch(idx, off, len)
    calls = calls + 1
    return data:sub(off + 1, off + len)
  end
  local s = rb:get_text(1, 1, #rb + 1, 1, fetch)
  U.eq(s, data, "get_text with sync_fn")
  U.eq(calls, math.ceil(#data / 700), "one sync fetch per chunk")
  U.eq(rb:get_text(1, 1, #rb + 1, 1, fetch), data, "second call uses cache")
  U.eq(calls, math.ceil(#data / 700), "no more fetches")
  -- errors
  local rb2 = U.open_remote(data, 700)
  local r, err = rb2:get_text(1, 1, 3, 1, function() error("boom") end)
  U.check(r == nil and err:find("boom"), "sync_fn error reported: %s", tostring(err))
  r, err = rb2:get_text(1, 1, 3, 1, function() return nil end)
  U.check(r == nil and err, "sync_fn returning nil")
  r, err = rb2:get_text(1, 1, 3, 1, function(i, o, l) return string.rep("x", l) end)
  U.check(r == nil and err and err:find("newline"), "sync_fn returning garbage: %s", tostring(err))
  U.eq(rb2:stats().resident, 0, "bad sync data never stored")
  U.eq(rb2:get_text(1, 1, 3, 1, fetch), U.fulltext(rb2, data):sub(1, #table.concat(U.split_lines(data), "", 1, 2)), "recovers")
  -- sync fetch with a budget smaller than the text: the call still returns all of it
  local rb3 = U.open_remote(data, 700, { budget = 1400 })
  U.eq(rb3:get_text(1, 1, #rb3 + 1, 1, fetch), data, "sync get_text larger than budget")
  U.check(rb3:stats().resident_bytes <= 1400, "budget enforced after sync get_text")
end

-- 7. LRU eviction and pinning ----------------------------------------------------------------
do
  local data = U.gen_text(100000)
  local cs = 1000
  local rb = U.open_remote(data, cs, { budget = 5 * cs })
  local lines = U.split_lines(data)
  for i = 1, #lines do
    U.eq(U.line(rb, data, i), lines[i], "line under tiny budget")
    U.check(rb:stats().resident_bytes <= 5 * cs, "budget respected")
  end
  U.check(rb:stats().resident <= 5, "at most 5 resident")
  -- LRU order: touch the oldest chunk, then load others; the touched one must survive
  local rb2 = U.open_remote(data, cs, { budget = 3 * cs })
  for i = 1, 3 do rb2:supply(i, data:sub((i - 1) * cs + 1, i * cs)) end
  local _ = rb2:get_text(1, 1, 2, 1) -- touch chunk 1 (line 1 lies in chunk 1)
  rb2:supply(4, data:sub(3 * cs + 1, 4 * cs))
  U.eq(rb2:stats().resident, 3, "budget keeps 3")
  U.eq(rb2:get_text(1, 1, 2, 1), lines[1], "chunk 1 survived (recently used)")
  -- explicit evict
  U.check(rb2:evict(1), "evict resident chunk")
  U.check(not rb2:get_text(1, 1, 2, 1), "evicted chunk unreadable")
  U.check(rb2:evict(1), "evicting a non-resident chunk is a no-op")
  local ok, err = rb2:evict(0)
  U.check(ok == false, "bad index")
  -- pinned chunks are never evicted
  local rb3 = U.open_remote(data, cs, { budget = 2 * cs })
  U.pump(rb3, data)
  rb3:supply(1, data:sub(1, cs))
  U.check(rb3:pin(1, true), "pin")
  ok, err = rb3:evict(1)
  U.check(ok == false and err == "pinned", "evict refuses pinned chunk")
  for i = 2, 8 do rb3:supply(i, data:sub((i - 1) * cs + 1, i * cs)) end
  U.check(rb3:get_text(1, 1, 2, 1) == lines[1], "pinned chunk survived pressure")
  U.check(rb3:stats().resident_bytes <= 3 * cs, "other chunks evicted")
  rb3:pin(1, false)
  U.check(rb3:evict(1), "evict after unpin")
  -- set_budget evicts immediately
  local rb4 = U.open_remote(data, cs)
  for i = 1, 10 do rb4:supply(i, data:sub((i - 1) * cs + 1, i * cs)) end
  U.eq(rb4:stats().resident, 10, "10 resident")
  rb4:set_budget(4 * cs)
  U.eq(rb4:stats().resident, 4, "set_budget evicts")
  -- edit pin: an edited chunk is not evicted
  local rb5 = U.open_remote(data, cs, { budget = 2 * cs })
  U.line(rb5, data, 40)
  U.check(rb5:insert(40, 1, "abc"), "insert with data")
  local pinned_before = rb5:stats().pinned
  U.eq(pinned_before, 1, "edit pinned a chunk")
  for i = 1, 20 do rb5:supply(i, data:sub((i - 1) * cs + 1, i * cs)) end
  U.check(rb5:stats().resident_bytes <= 3 * cs, "budget (plus pinned) respected")
  U.eq(U.line(rb5, data, 40), "abc" .. lines[40], "edited line survives eviction pressure")
end

-- 8. stale --------------------------------------------------------------------------------------
do
  local data = U.gen_text(20000)
  local rb = U.open_remote(data, 1000)
  U.line(rb, data, 1)
  U.eq(rb[1] ~= PH, true, "readable before stale")
  rb:set_stale(true)
  U.eq(rb[1], PH, "stale reads give placeholders even for resident chunks")
  local ok, err = rb:insert(1, 1, "x")
  U.check(ok == false and err == "stale", "insert refused while stale")
  ok, err = rb:remove(1, 1, 1, 2)
  U.check(ok == false and err == "stale", "remove refused while stale")
  ok, err = rb:supply(2, data:sub(1001, 2000))
  U.check(ok == false and err == "stale", "supply refused while stale")
  U.eq(#rb:missing(), 0, "nothing requested while stale")
  local s, e = rb:get_text(1, 1, 2, 1)
  U.check(s == nil and e == "stale", "get_text while stale")
  rb:set_stale(false)
  U.check(rb[1] ~= PH, "readable again")
  U.check(rb:insert(1, 1, "x"), "edits work again")
end

-- 9. edit_script / rebase ------------------------------------------------------------------------
do
  local data = U.gen_text(80000)
  local cs = 1000
  local rb = U.open_remote(data, cs)
  local script, inserts = rb:edit_script()
  U.eq(#script, 1, "unedited file is one keep")
  U.check(script[1].keep == true and script[1].off == 0 and script[1].len == #data, "keep covers file")
  U.eq(#inserts, 0, "no inserts")
  -- no trailing newline: unedited, the script is the original file (the virtual
  -- newline is not written back); once edited, the virtual newline is an insert
  local d2 = U.gen_text(5000, { final_nl = false })
  local rb2 = U.open_remote(d2, 700)
  local s2, i2 = rb2:edit_script()
  U.eq(#s2, 1, "unedited: one keep"); U.eq(#i2, 0, "unedited: no inserts")
  U.eq(U.apply(s2, i2, d2), d2, "unedited applied")
  U.check(rb2:insert(1, 1, "x"), "edit")
  s2, i2 = rb2:edit_script()
  U.eq(U.apply(s2, i2, d2), "x" .. d2 .. "\n", "edited applied")
  U.eq(i2[#i2], "\n", "virtual newline text")
  U.check(rb2:remove(1, 1, 1, 2), "undo the edit")
  s2, i2 = rb2:edit_script()
  U.eq(#s2, 1, "edit undone: one keep again"); U.eq(U.apply(s2, i2, d2), d2, "undone applied")
  -- the final newline flag is required and checked against the last chunk
  U.check(not pcall(buffer.open_remote, { size = #d2, chunks = U.chunk_table(d2, 700) }), "ends_with_nl required")
  U.check(not pcall(rb2.rebase, rb2, #d2, U.chunk_table(d2, 700)), "rebase needs ends_with_nl")
  local liar = U.open_remote(d2, 700, { ends_with_nl = true })
  local nlast = #U.chunk_table(d2, 700)
  local ok_l, err_l = liar:supply(nlast, d2:sub((nlast - 1) * 700 + 1))
  U.check(not ok_l and err_l == "final newline mismatch", "wrong ends_with_nl detected: %s", tostring(err_l))
  -- empty file
  local rb3 = U.open_remote("", 4096)
  local s3, i3 = rb3:edit_script()
  U.eq(#s3, 1, "empty: one insert"); U.eq(i3[1], "\n", "empty file is a newline")
  U.eq(U.apply(s3, i3, ""), "\n", "empty applied")

  -- edits, then script, then rebase
  U.fulltext(rb, data)
  local model = data
  U.check(rb:insert(10, 1, "INSERTED\n"), "ins")
  U.check(rb:remove(20, 1, 25, 1), "rm")
  U.check(rb:insert(#rb, 1, "tail"), "ins tail")
  local ls = U.split_lines(data)
  local function off_of(l) local o = 0 for i = 1, l - 1 do o = o + #ls[i] end return o end
  -- apply to model by hand: operations in order, offsets of original lines are stable
  -- (ins at line 10 shifts later lines by 9 bytes and 1 line; remove lines 20..24 of the edited doc)
  local o_ins = off_of(10)
  model = model:sub(1, o_ins) .. "INSERTED\n" .. model:sub(o_ins + 1)
  local l20 = U.split_lines(model)
  local a, b = 0, 0
  for i = 1, 19 do a = a + #l20[i] end
  for i = 1, 24 do b = b + #l20[i] end
  model = model:sub(1, a) .. model:sub(b + 1)
  local l3 = U.split_lines(model)
  local last = 0
  for i = 1, #l3 - 1 do last = last + #l3[i] end
  model = model:sub(1, last) .. "tail" .. model:sub(last + 1)
  local script2, inserts2 = rb:edit_script()
  U.eq(U.apply(script2, inserts2, data), model, "script applied equals edited text")
  U.eq(U.fulltext(rb, data), model, "buffer text equals model")
  -- script shape
  for _, op in ipairs(script2) do
    if op.keep then U.check(op.off and op.len and not op.ins, "keep shape")
    else U.check(math.type(op.ins) == "integer" and not op.keep and not op.off, "ins shape") end
  end
  -- adjacent contiguous remote pieces are coalesced: remove a middle byte range then
  -- the script must have no two keeps that are contiguous
  for i = 2, #script2 do
    local p, q = script2[i - 1], script2[i]
    U.check(not (p.keep and q.keep and p.off + p.len == q.off), "contiguous keeps coalesced")
  end
  -- rebase onto the "saved" file
  rb:set_stale(true)
  local new_chunks = U.chunk_table(model, cs)
  U.check(rb:rebase(#model, new_chunks, model:sub(-1) == "\n"), "rebase")
  U.eq(rb:stats().resident, 0, "rebase clears the cache")
  U.eq(rb:stats().pinned, 0, "rebase clears pins")
  U.eq(rb:stats().queued, 0, "rebase clears the queue")
  U.eq(#rb, U.count_lf(model), "line count after rebase")
  local s4, i4 = rb:edit_script()
  U.eq(#s4, 1, "all-remote after rebase"); U.eq(#i4, 0, "no heap after rebase")
  U.eq(U.fulltext(rb, model), model, "text after rebase")
  U.check(rb:insert(1, 1, "again"), "editable after rebase (not stale)")
  -- bad rebase leaves the buffer alone
  local ok = pcall(rb.rebase, rb, 5, { { 3, 0 } }, true)
  U.check(not ok, "inconsistent table rejected")
  U.eq(U.fulltext(rb, model):sub(1, 5), "again", "buffer intact after failed rebase")
end

-- 10. API errors / misc ------------------------------------------------------------------------------
do
  local data = U.gen_text(5000)
  local rb = U.open_remote(data, 1000)
  local ok, err = pcall(rb.save, rb, TMP .. "/should_not_exist.txt")
  U.check(not ok and tostring(err):find("edit_script"), "save is rejected: %s", tostring(err))
  U.check(not io.open(TMP .. "/should_not_exist.txt"), "no file written")
  for _, bad in ipairs({
    { size = 10, chunks = { { 5, 0 } } },                 -- sizes do not add up
    { size = 10, chunks = { { 10, 11 } } },               -- lf > len
    { size = 10, chunks = { { 0, 0 }, { 10, 0 } } },      -- empty chunk
    { size = 10, chunks = {} },                           -- no chunks for non-empty
    { size = 0, chunks = { { 1, 0 } } },                  -- chunks for empty
    { size = 10, chunks = { { 5, 0 }, { "x", 0 } } },     -- bad type
    { size = 10, chunks = { { 10, 0 } }, chunk_size = 5 },-- longer than chunk_size
    { size = -1, chunks = {} },
    { size = 10, chunks = { 10, 0, 5 } },                 -- odd flat table
  }) do
    local ok2 = pcall(buffer.open_remote, bad)
    U.check(not ok2, "open_remote must reject bad table")
  end
  U.check(not pcall(buffer.open_remote, {}), "missing fields")
  -- flat chunk table
  local flat = {}
  for _, c in ipairs(U.chunk_table(data, 1000)) do flat[#flat + 1] = c[1]; flat[#flat + 1] = c[2] end
  local fb = buffer.open_remote { size = #data, chunks = flat, ends_with_nl = true }
  U.eq(U.fulltext(fb, data), data, "flat chunk table")
end

-- 11. huge sparse table ------------------------------------------------------------------------------
do
  local N = tonumber(os.getenv("SPARSE_CHUNKS")) or 1000000
  local LINE = 64
  local flat = {}
  for i = 1, N do flat[2 * i - 1] = LINE; flat[2 * i] = 1 end
  local size = N * LINE
  collectgarbage()
  local rss0 = U.rss_kb()
  local t, rb = timeit(function()
    return buffer.open_remote { size = size, chunks = flat, ends_with_nl = true, chunk_size = LINE }
  end)
  local rss1 = U.rss_kb()
  flat = nil
  collectgarbage()
  print(string.format("  open_remote %d chunks (%.1f MB virtual): %.3f s, RSS +%s MB", N, size / 1e6, t,
    rss0 and string.format("%.0f", (rss1 - rss0) / 1024) or "?"))
  U.check(t < (os.getenv("SAN") == "0" and 2 or 10), "open of %d chunks took %.2fs", N, t)
  U.eq(#rb, N, "line count of sparse file")
  local function content(k) return string.format("%063d\n", k - 1) end
  local function data_of(idx) return content(idx) end -- chunk i == line i
  -- jump to the end / middle / start
  for _, k in ipairs({ N, math.floor(N / 2), 1, N - 1, 777777 > N and 1 or 777777 }) do
    U.eq(rb[k], PH, "sparse placeholder")
    local m = rb:missing()
    U.check(#m >= 1 and #m <= 2, "jump requested %d chunks", #m)
    for _, e in ipairs(m) do U.check(rb:supply(e[1], data_of(e[1]))) end
    U.eq(rb[k], content(k), "sparse line " .. k)
  end
  -- scrolling a window
  for k = 5000, 5100 do
    local s = rb[k]
    if s == PH then
      for _, e in ipairs(rb:missing()) do rb:supply(e[1], data_of(e[1])) end
      s = rb[k]
    end
    U.eq(s, content(k), "window line " .. k)
  end
  -- edit near the end of a huge file, then the script is tiny
  U.check(rb:insert(N, 5, "XY"), "edit at end of sparse file")
  local script, inserts = rb:edit_script()
  U.eq(#script, 3, "keep(prefix), ins, keep(rest)")
  U.eq(#inserts, 1, "one insert")
  U.eq(inserts[1], "XY", "insert text")
  U.check(script[1].keep and script[1].off == 0 and script[1].len == (N - 1) * LINE + 4, "prefix keep")
  U.check(script[2].ins == 1, "ins")
  U.check(script[3].keep and script[3].off == (N - 1) * LINE + 4 and script[3].len == LINE - 4, "suffix keep")
  U.check(rb:stats().resident < 150, "memory stays small")
end

-- 12. working sets larger than the budget ------------------------------------------------------------
do
  local cs = 1000
  -- a line of 10 chunks under a 3 chunk budget becomes readable (no endless refetch)
  local data = "first\n" .. string.rep("b", 10 * cs) .. "\n" .. string.rep("tail\n", 1000)
  local nch = #U.chunk_table(data, cs)
  local rb = U.open_remote(data, cs, { budget = 3 * cs })
  local rounds = 0
  while rb[2] == PH do
    rounds = rounds + 1
    U.check(rounds < 20, "long line never became readable")
    U.pump(rb, data)
  end
  U.eq(rb[2], string.rep("b", 10 * cs) .. "\n", "line larger than the budget")
  -- it stays readable while it is being read, even with other chunks arriving
  for i = nch - 3, nch do
    rb:missing()
    U.check(rb:supply(i, data:sub((i - 1) * cs + 1, i * cs)))
    U.eq(rb[2], string.rep("b", 10 * cs) .. "\n", "still readable")
  end
  -- once nothing reads it any more the hold lapses and the budget applies again
  for _ = 1, 6 do rb:missing() end
  rb:set_budget(3 * cs)
  U.check(rb:stats().resident_bytes <= 3 * cs, "budget applies after the hold lapses (%d)", rb:stats().resident_bytes)
  U.eq(rb:stats().held_bytes, 0, "nothing held")

  -- a line straddling a chunk boundary under a one chunk budget
  local d2 = string.rep("x", cs - 10) .. "\n" .. string.rep("y", 30) .. "\n" .. string.rep("z", 2 * cs) .. "\n"
  local rb2 = U.open_remote(d2, cs, { budget = cs })
  U.eq(U.line(rb2, d2, 2), string.rep("y", 30) .. "\n", "straddling line under a tiny budget")

  -- a sync read followed by a remove of the same range: the remove never fails
  -- for bytes the read just had (the editor saves removed text for undo first)
  local d3 = U.gen_text(20000)
  local lines = U.split_lines(d3)
  local rb3 = U.open_remote(d3, 700, { budget = 700 })
  local function fetch(_, off, len) return d3:sub(off + 1, off + len) end
  local l1, l2 = 3, #lines - 3
  local text = rb3:get_text(l1, 2, l2, 2, fetch)
  U.check(text, "sync read")
  local ok, err = rb3:remove(l1, 2, l2, 2)
  U.check(ok, "remove right after the sync read: %s", tostring(err))
  U.eq(rb3[l1], lines[l1]:sub(1, 1) .. lines[l2]:sub(2), "removed")
end

-- 13. fingerprints of loaded chunks (overwrite after a server change) -------------------------------
do
  local cs = 1000
  local data = U.gen_text(10000)
  local rb = U.open_remote(data, cs, { budget = 2 * cs })
  local function chunk(i, d) return (d or data):sub((i - 1) * cs + 1, i * cs) end
  U.eq(#rb:loaded_chunks(), 0, "nothing loaded")
  for i = 1, 5 do U.check(rb:supply(i, chunk(i))) end -- the budget evicts most of them again
  U.check(rb:stats().resident <= 2, "evicted")
  local loaded = rb:loaded_chunks()
  U.eq(#loaded, 5, "evicted chunks are still known")
  for _, i in ipairs(loaded) do U.eq(rb:chunk_matches(i, chunk(i)), true, "same bytes " .. i) end
  -- same length and newline count, different bytes
  local other = chunk(1):gsub("[a-y]", function(c) return string.char(c:byte() + 1) end, 1)
  U.eq(#other, cs, "same length")
  U.eq(rb:chunk_matches(1, other), false, "changed bytes (evicted chunk)")
  local c5 = chunk(5)
  U.eq(rb:chunk_matches(5, c5:sub(1, -2) .. (c5:sub(-1) == "q" and "r" or "q")), false, "changed bytes (resident chunk)")
  U.eq(rb:chunk_matches(5, chunk(5) .. "q"), false, "different length")
  U.eq(rb:chunk_matches(7, chunk(7)), nil, "never loaded")
  U.eq(rb:chunk_matches(99, "x"), nil, "bad index")
  -- chunk_hash: the 64-bit FNV-1a the server's hash_ranges computes
  local function fnv(str)
    local h = -3750763034362895579 -- 14695981039346656037 as a signed integer
    for k = 1, #str do h = (h ~ str:byte(k)) * 1099511628211 end
    return h
  end
  for _, i in ipairs(loaded) do
    local h, len = rb:chunk_hash(i)
    U.eq(h, fnv(chunk(i)), "chunk_hash " .. i)
    U.eq(len, #chunk(i), "chunk_hash len " .. i)
  end
  U.eq(rb:chunk_hash(7), nil, "chunk_hash never loaded")
  U.check(rb:rebase(#data, U.chunk_table(data, cs), true), "rebase")
  U.eq(#rb:loaded_chunks(), 0, "rebase forgets fingerprints")
end

print(string.format("test_remote OK (%d checks)", U.checks()))
