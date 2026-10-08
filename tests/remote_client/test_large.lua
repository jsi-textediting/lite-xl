-- Remote large files: open without download, jump/scroll, edit, save (edit
-- script), stale, conflict, search. The file is dense text of 64-byte lines
-- ("x" * 63 + "\n") with sentinel lines, 1 GiB by default (LXC_BIG_MB), kept in
-- /tmp/lxc-big-<MB> inside WSL between runs. Every test works on a hard link
-- of it: the server replaces the inode on save, so the original is never touched.
return function(T)
  local paths = require "plugins.thither.paths"
  local PH = "\xe2\x80\xa6\n"
  local BIG_MB = tonumber(os.getenv("LXC_BIG_MB") or "1024")
  local LINE = 64
  local NLINES = BIG_MB * 1024 * 1024 // LINE
  local SENTINELS = { 1, 100, 5000, 1000000, NLINES // 3, NLINES // 2, NLINES - 100, NLINES }
  local big_dir
  local counter = 0

  local function ensure_big()
    if big_dir then return end
    big_dir = "/tmp/lxc-big-" .. BIG_MB
    local out = T.sh_ok("[ -f " .. big_dir .. "/.done ] && echo yes || echo no")
    if out:find("yes") then return end
    local t0 = system.get_time()
    local script = {
      "set -e", "rm -rf " .. big_dir, "mkdir -p " .. big_dir, "cd " .. big_dir,
      "F=$(head -c 63 /dev/zero | tr '\\0' x)",
      string.format("yes \"$F\" | head -c %d > big.txt", NLINES * LINE),
    }
    for _, k in ipairs(SENTINELS) do
      script[#script + 1] = string.format("printf '%%-63s\\n' 'SENTINEL-%d' | dd of=big.txt bs=64 seek=%d conv=notrunc status=none", k, k - 1)
    end
    script[#script + 1] = "touch .done"
    T.sh_ok(table.concat(script, "\n"), 600)
    io.stdout:write(string.format("      created %d MB test file in %.1f s\n", BIG_MB, system.get_time() - t0))
  end

  local PY = [[
import sys, json
src, dst, edits_path = sys.argv[1:4]
edits = sorted(json.load(open(edits_path)), key=lambda e: e["off"])
def copy(s, d, pos, n):
    s.seek(pos)
    while n > 0:
        b = s.read(min(n, 8 << 20))
        if not b: raise SystemExit("short read")
        d.write(b); n -= len(b)
with open(src, "rb") as s, open(dst, "wb") as d:
    pos = 0
    for e in edits:
        n = e["off"] - pos
        assert n >= 0, "overlapping edits"
        copy(s, d, pos, n)
        d.write(bytes.fromhex(e["ins"]))
        pos = e["off"] + e["del"]
    s.seek(0, 2)
    copy(s, d, pos, s.tell() - pos)
]]

  --- Creates a work copy; returns a context table.
  --- `copy`: a real copy, for tests that modify the file in place on the server
  --- (a hard link would share the damage with big.txt).
  local function work_copy(copy)
    ensure_big()
    counter = counter + 1
    local name = "work" .. counter .. ".txt"
    T.sh_ok(string.format("cd %s && rm -f work*.txt* basework*.txt* expected.txt && %s big.txt %s",
      big_dir, copy and "cp" or "ln", name), 300)
    local f = assert(io.open(paths.make(T.label, big_dir .. "/build.py"), "wb"))
    f:write(PY)
    assert(f:close())
    local ctx = { name = name, dir = big_dir, posix = big_dir .. "/" .. name }
    ctx.mount = paths.make(T.label, ctx.posix)
    ctx.edits = {}
    return ctx
  end

  local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

  --- Records an edit in original-file byte coordinates.
  local function record(ctx, off, del, ins)
    ctx.edits[#ctx.edits + 1] = string.format('{"off":%d,"del":%d,"ins":"%s"}', off, del, hex(ins or ""))
  end

  --- Verifies the server file against the model built independently with python.
  local function verify(ctx, label)
    local json = "[" .. table.concat(ctx.edits, ",") .. "]"
    local f = assert(io.open(paths.make(T.label, ctx.dir .. "/edits.json"), "wb"))
    f:write(json)
    assert(f:close())
    T.sh_ok(string.format("cd %s && python3 build.py %s expected.txt edits.json && cmp expected.txt %s",
      ctx.dir, ctx.base or "big.txt", ctx.name), 300)
    io.stdout:write("      " .. (label or "file") .. ": byte-exact against the model (cmp)\n")
  end

  --- Next round: the saved file becomes the model's base.
  local function rebase_model(ctx)
    T.sh_ok(string.format("cd %s && cp --reflink=auto %s base%s", ctx.dir, ctx.name, ctx.name))
    ctx.base = "base" .. ctx.name
    ctx.edits = {}
  end

  local function open(ctx)
    local Doc = require "core.doc"
    local t0 = system.get_time()
    local doc = Doc(ctx.name, ctx.mount)
    ctx.open_ms = (system.get_time() - t0) * 1000
    return doc
  end

  local function ready(doc, line, timeout)
    T.wait_for(function() return doc.lines[line] ~= PH end, timeout or 20, "chunk of line " .. line)
  end

  local function line_off(k) return (k - 1) * LINE end

  local function sent_bytes(conn)
    -- bytes written to the transport so far
    return conn.sent_total or 0
  end

  local function instrument(conn)
    if conn.sent_total ~= nil then return end
    conn.sent_total = 0
    local orig = conn.send
    conn.send = function(self, msg)
      local frame = require "plugins.thither.frame"
      conn.sent_total = conn.sent_total + #frame.encode(msg)
      return orig(self, msg)
    end
  end

  T.test("large: opens instantly without downloading the file", function()
    local h = T.connect()
    instrument(h.conn)
    local ctx = work_copy()
    local before = sent_bytes(h.conn)
    local rx0 = h.conn.proc and 0
    local doc = open(ctx)
    T.ok(doc.remote and doc.remote.large, "remote large doc")
    T.ok(doc.large_file, "large_file flag")
    T.ok(doc.buffer:is_remote())
    T.eq(#doc.lines, NLINES)      -- a final newline does not start another line
    T.eq(doc.crlf, nil)
    T.ok(doc.syntax == require("core.syntax").plain_text_syntax, "plain text")
    local st = doc.buffer:stats()
    T.eq(st.resident, 1, "only the first chunk is resident")
    io.stdout:write(string.format("      open of %d MB (%d lines, %d chunks): %.0f ms, resident %d KB\n",
      BIG_MB, #doc.lines, st.chunks, ctx.open_ms, st.resident_bytes // 1024))
    T.ok(ctx.open_ms < 3000, "open took " .. ctx.open_ms)
    T.eq(doc.lines[1]:sub(1, 10), "SENTINEL-1")
    -- the first screenful is readable right away
    T.ok(doc.buffer:is_resident(1, 3))
    -- the second open of the same file hits the server's index cache
    local t1 = system.get_time()
    local doc2 = open(ctx)
    io.stdout:write(string.format("      second open (cached index): %.0f ms\n", (system.get_time() - t1) * 1000))
    require("plugins.thither.docs").release(doc2)
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: jump, scroll, prefetch, bounded cache", function()
    local h = T.connect()
    local docs = require "plugins.thither.docs"
    local ctx = work_copy()
    local doc = open(ctx)
    local conn = h.conn
    -- jump to the middle: placeholder first, real text after a round trip
    local mid = NLINES // 2
    T.eq(doc.lines[mid], PH, "not loaded yet")
    local t0 = system.get_time()
    ready(doc, mid)
    local jump_ms = (system.get_time() - t0) * 1000
    T.eq(doc.lines[mid]:sub(1, #("SENTINEL-" .. mid)), "SENTINEL-" .. mid)
    T.eq(#doc.lines[mid], LINE)
    -- a jump to the end
    ready(doc, #doc.lines - 1)
    T.eq(doc.lines[NLINES]:sub(1, #("SENTINEL-" .. NLINES)), "SENTINEL-" .. NLINES)
    T.eq(#doc.lines, NLINES)
    -- scroll down 5000 lines frame by frame (like a drag of the scrollbar thumb): every
    -- frame reads a window of 40 lines; count how many frames show placeholders
    local start = 1000000
    local ph_frames, frames = 0, 0
    local line = start
    local deadline = system.get_time() + 60
    while line < start + 5000 do
      local ph = false
      for i = line, line + 39 do
        if doc.lines[i] == PH then ph = true end
      end
      frames = frames + 1
      if ph then ph_frames = ph_frames + 1 else line = line + 40 end
      T.sleep(0.004)
      T.ok(system.get_time() < deadline, "scroll timeout")
    end
    io.stdout:write(string.format("      jump to middle: %.0f ms; scroll 5000 lines: %d frames, %d with placeholders\n",
      jump_ms, frames, ph_frames))
    -- prefetch ahead of a sequential scroll: the next chunks arrive without being asked for
    local r = doc.remote
    T.ok(r.nhave >= 3, "prefetched chunks: " .. r.nhave)
    -- nothing queued is lost: all pending chunks are owned by the pump
    T.sleep(0.2)
    local st = doc.buffer:stats()
    T.eq(st.queued, 0)
    -- the cache stays inside its budget however much we read
    doc.buffer:set_budget(3 * 262144)
    for i = 0, 40 do
      local l = 1 + i * (NLINES // 41)
      local _ = doc.lines[l]
      T.sleep(0.01)
    end
    T.sleep(0.5)
    st = doc.buffer:stats()
    T.ok(st.resident_bytes <= 3 * 262144 + 262144, "resident " .. st.resident_bytes)
    docs.release(doc)
  end)

  T.test("large: edits in several places, save sends only the edit, result is byte-exact", function()
    local h = T.connect()
    local ctx = work_copy()
    local doc = open(ctx)
    local conn = h.conn
    local docs = require "plugins.thither.docs"
    local etag0 = doc.remote.etag
    local size0 = doc.remote.size
    local UML = "\xc3\xa4\xc3\xb6\xc3\xbc"

    -- edits go bottom-up so the line numbers of the ones still to do stay valid;
    -- the model gets the same edits in original file coordinates
    -- 5) append at the very end (after the last newline)
    -- (a position after the final newline does not exist: insert before it)
    ready(doc, #doc.lines)
    doc:insert(#doc.lines, #doc.lines[#doc.lines], "\nappended at the end")
    record(ctx, size0 - 1, 0, "\nappended at the end")
    -- 4) replace the start of a sentinel line in the middle
    local mid = NLINES // 2
    ready(doc, mid)
    doc:remove(mid, 1, mid, 10)
    doc:insert(mid, 1, "EDITED-" .. UML .. "-")
    record(ctx, line_off(mid), 9, "EDITED-" .. UML .. "-")
    -- 3) remove a block of lines spanning several chunks (13000 lines = 3+ chunks)
    local a, b = 2000001, 2000001 + 13000
    ready(doc, a); ready(doc, b)
    doc:remove(a, 1, b, 1)
    record(ctx, line_off(a), line_off(b) - line_off(a), "")
    -- 2) insert several lines inside line 5000
    ready(doc, 5000)
    doc:insert(5000, 20, "inserted\ntext\nhere\n")
    record(ctx, line_off(5000) + 19, 0, "inserted\ntext\nhere\n")
    -- 1) typed text at the very start
    doc:insert(1, 1, "first line added\n")
    record(ctx, 0, 0, "first line added\n")
    T.ok(doc:is_dirty())
    local before_lines = #doc.lines
    T.eq(before_lines, NLINES + 1 + 3 + 1 - 13000)

    instrument(conn)
    local sent0 = sent_bytes(conn)
    local t0 = system.get_time()
    doc:save()
    local save_ms = (system.get_time() - t0) * 1000
    local sent = sent_bytes(conn) - sent0
    io.stdout:write(string.format("      save of %d MB file with 5 edits: %.0f ms, %d bytes sent\n", BIG_MB, save_ms, sent))
    T.ok(sent < 20000, "sent " .. sent)
    T.ok(not doc:is_dirty())
    T.ok(doc.remote.etag ~= etag0)
    verify(ctx, "after first save")
    -- the document is usable after the rebase
    T.eq(#doc.lines, before_lines)
    ready(doc, 1)
    T.eq(doc.lines[1], "first line added\n")
    ready(doc, 2)               -- chunks are not uniform after a save
    T.eq(doc.lines[2]:sub(1, 10), "SENTINEL-1")
    local mid2 = mid + 4 - 13000
    ready(doc, mid2)
    T.eq(doc.lines[mid2]:sub(1, 14), "EDITED-" .. UML .. "-")

    -- second round on the rebased (non uniform) chunk table; the model now starts from the saved file
    rebase_model(ctx)
    local size1 = doc.remote.size
    ready(doc, #doc.lines)
    doc:insert(#doc.lines, #doc.lines[#doc.lines], "\ntail")
    record(ctx, size1 - 1, 0, "\ntail")
    ready(doc, 3)
    doc:insert(3, 5, "SECOND")                           -- line 3 starts at 17 + 64
    record(ctx, 17 + 64 + 4, 0, "SECOND")
    doc:remove(1, 1, 2, 1)                               -- delete the first line again
    record(ctx, 0, 17, "")
    doc:save()
    T.ok(not doc:is_dirty())
    verify(ctx, "after second save")
    ready(doc, 1)
    T.eq(doc.lines[1]:sub(1, 10), "SENTINEL-1")
    docs.release(doc)
  end)

  T.test("large: undo and redo of remote edits", function()
    local h = T.connect()
    local ctx = work_copy()
    local doc = open(ctx)
    ready(doc, 101)
    local l = doc.lines[101]
    doc:insert(101, 5, "abc")
    T.eq(doc.lines[101]:sub(1, 12), "xxxxabcxxxxx")
    doc:undo()
    T.eq(doc.lines[101], l)
    doc:redo()
    T.eq(doc.lines[101]:sub(1, 12), "xxxxabcxxxxx")
    -- remove across lines, undo restores real text (never placeholders)
    ready(doc, 200); ready(doc, 205)
    local saved = doc:get_text(200, 1, 205, 1)
    T.eq(#saved, 5 * LINE)
    doc:remove(200, 1, 205, 1)
    doc:undo()
    T.eq(doc:get_text(200, 1, 205, 1), saved)
    for i = 200, 204 do T.ok(doc.lines[i] ~= PH, "line " .. i) end
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: edits are refused where nothing can be loaded; undo never records placeholders", function()
    local h = T.connect()
    local ctx = work_copy()
    local doc = open(ctx)
    -- a position far away whose chunk is not resident and cannot be fetched
    local far = 7000000
    T.eq(doc.lines[far], PH)
    local sync_fn = doc.remote.sync_fn
    doc.remote.sync_fn = function() error("no network", 0) end
    local n_before = doc.undo_stack.idx
    doc:insert(far, 1, "refused")
    doc.remote.sync_fn = sync_fn
    T.eq(doc.undo_stack.idx, n_before, "no undo entry for a refused insert")
    T.eq(#doc.lines, NLINES)
    T.ok(not doc:is_dirty())
    -- an explicit insert fetches the line synchronously and succeeds
    doc:insert(far, 1, "fetched")
    T.eq(doc.lines[far]:sub(1, 8), "fetchedx")
    doc:undo()
    T.ok(not doc:is_dirty())
    -- removing a not loaded range uses the sync fetch and succeeds (explicit action)
    doc:remove(far, 1, far + 1, 1)
    T.eq(#doc.lines, NLINES - 1)
    doc:undo()
    T.eq(#doc.lines, NLINES)
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: copy text of a selection fetches missing chunks synchronously", function()
    local h = T.connect()
    local ctx = work_copy()
    local doc = open(ctx)
    local txt = doc:get_text(4000000, 1, 4000003, 1)
    T.eq(txt, string.rep(string.rep("x", 63) .. "\n", 3))
    T.eq(doc:get_text(NLINES, 1, NLINES, 20), "SENTINEL-" .. NLINES .. string.rep(" ", 19 - #("SENTINEL-" .. NLINES)))
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: file changed on the server makes the doc stale; reload recovers", function()
    local h = T.connect()
    local vfs = require "plugins.thither.vfs"
    local ctx = work_copy(true)
    local doc = open(ctx)
    vfs.ensure_watch(h, ctx.dir)
    T.watch_ready(h)
    ready(doc, 1)
    T.sh_ok("sleep 0.05; printf 'appended by someone else\\n' >> " .. ctx.posix)
    T.wait_for(function() return doc.remote and doc.remote.stale end, 15, "stale flag")
    T.ok(T.nag_count("File Changed on Server") >= 1)
    -- reads of unloaded text give placeholders, edits are refused, nothing is corrupted
    doc:insert(1, 1, "blocked")
    T.eq(doc.lines[1], PH, "a stale buffer reads placeholders only")
    T.ok(not doc:is_dirty())
    -- reload from the nag
    T.answer_nag("File Changed on Server", "Reload")
    local okr, errr = pcall(T.wait_for, function() return doc.remote and not doc.remote.stale and #doc.lines == NLINES + 1 end, 20, "reload")
    if not okr then
      local r = doc.remote or {}
      error(string.format("%s [stale=%s lines=%d/%d size=%s reloading=%s conn=%s nags=%d]", tostring(errr), tostring(r.stale), #doc.lines, NLINES + 1,
        tostring(r.size), tostring(r.reloading), tostring(h.conn.state), #T.core.nag_view.shown), 0)
    end
    ready(doc, NLINES + 1)
    T.eq(doc.lines[NLINES + 1], "appended by someone else\n")
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: a stale chunk fetch (no watch) marks the doc stale", function()
    local h = T.connect()
    local ctx = work_copy(true)
    local doc = open(ctx)
    ready(doc, 1)
    T.sh_ok("sleep 0.05; printf 'x' >> " .. ctx.posix)
    T.eq(doc.lines[3000000], PH)
    T.wait_for(function() return doc.remote.stale end, 15, "stale from fetch")
    T.ok(doc.buffer:is_remote())
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: save conflict keeps the edits; overwrite works after a touch; reload otherwise", function()
    local h = T.connect()
    local docs = require "plugins.thither.docs"
    local ctx = work_copy(true)
    local doc = open(ctx)
    ready(doc, 1)
    doc:insert(1, 1, "mine\n")
    record(ctx, 0, 0, "mine\n")
    -- somebody touches the file (same content, new mtime)
    T.sh_ok("sleep 0.05; touch " .. ctx.posix)
    local ok, err = pcall(doc.save, doc)
    T.ok(not ok and type(err) == "table" and err.remote_conflict and err.large, tostring(err))
    T.ok(doc:is_dirty(), "edits are kept")
    local retried
    docs.conflict_nag(doc, err, function() retried = pcall(doc.save, doc) end)
    T.answer_nag("Save Conflict", "Overwrite")
    T.wait_for(function() return retried ~= nil end, 60, "overwrite retry")
    T.ok(retried, "overwrite saved")
    T.ok(not doc:is_dirty())
    verify(ctx, "after overwrite")
    -- now the content really changes: overwrite is refused, reload recovers
    doc:insert(1, 1, "more\n")
    T.sh_ok("sleep 0.05; printf 'zzz\\n' >> " .. ctx.posix)
    ok, err = pcall(doc.save, doc)
    T.ok(not ok and err.remote_conflict)
    docs.conflict_nag(doc, err)
    T.answer_nag("Save Conflict", "Overwrite")
    T.sleep(0.5)
    T.ok(doc:is_dirty(), "overwrite of different content is refused")
    docs.conflict_nag(doc, err)
    T.answer_nag("Save Conflict", "Reload")
    T.wait_for(function() return not doc:is_dirty() and #doc.lines == NLINES + 2 end, 30, "reload after conflict")
    docs.release(doc)
  end)

  T.test("large: server side search (forward, reverse, wrap, case, regex)", function()
    local h = T.connect()
    local ctx = work_copy()
    local doc = open(ctx)
    local search = require "core.doc.search"
    local t0 = system.get_time()
    local l1, c1, l2, c2 = search.find(doc, 1, 1, "SENTINEL-1000000", {})
    local ms = (system.get_time() - t0) * 1000
    T.eq(l1, 1000000); T.eq(c1, 1); T.eq(l2, 1000000); T.eq(c2, 1 + #"SENTINEL-1000000")
    io.stdout:write(string.format("      search in %d MB: %.0f ms\n", BIG_MB, ms))
    -- continues after the cursor
    l1 = search.find(doc, 1000000, 2, "SENTINEL-", {})
    T.eq(l1, NLINES // 3)
    -- reverse from the end finds the previous sentinel
    l1 = search.find(doc, NLINES, 1, "SENTINEL-", { reverse = true })
    T.eq(l1, NLINES - 100)
    -- no match / wrap
    T.eq(search.find(doc, 1, 1, "does-not-occur-anywhere", {}), nil)
    l1 = search.find(doc, NLINES, 2, "SENTINEL-1 ", { wrap = true })
    T.eq(l1, 1)
    -- case-insensitive and regex
    l1, c1 = search.find(doc, 2, 1, "sentinel-5000 ", { no_case = true })
    T.eq(l1, 5000)
    l1, c1, l2, c2 = search.find(doc, 2, 1, "SENTINEL-\\d+0000(?= )", { regex = true })
    T.eq(l1, 1000000)
    T.eq(c2 - c1, #"SENTINEL-1000000")
    -- a doc with unsaved changes is not searched on the server
    doc:insert(1, 1, "x")
    T.eq(search.find(doc, 1, 1, "SENTINEL-100", {}), nil)
    -- the local implementation is untouched for ordinary docs
    local Doc = require "core.doc"
    local small = Doc()
    small:insert(1, 1, "hello world")
    T.eq((search.find(small, 1, 1, "world", {})), 1)
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: insert bigger than a frame goes through blob_put", function()
    local h = T.connect()
    instrument(h.conn)
    local ctx = work_copy()
    local doc = open(ctx)
    ready(doc, 10)
    local chunk = string.rep("0123456789abcdef", 64) .. "\n"       -- 1 KiB line
    local text = string.rep(chunk, 9 * 1024)                       -- 9 MiB
    doc:insert(10, 1, text)
    record(ctx, line_off(10), 0, text)
    doc:save()
    T.ok(not doc:is_dirty())
    verify(ctx, "after a 9 MiB insert")
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: save as writes the edited file to the new path on the server", function()
    local h = T.connect()
    local ctx = work_copy()
    local doc = open(ctx)
    ready(doc, 1)
    doc:insert(1, 1, "copy edit\n")
    local copy_abs = paths.join(paths.make(T.label, ctx.dir), ctx.name .. ".copy")
    doc:save(ctx.name .. ".copy", copy_abs)
    T.eq(T.sh_ok("head -c 10 " .. ctx.posix .. ".copy"), "copy edit\n")
    T.eq(T.sh_ok("head -c 9 " .. ctx.posix), "SENTINEL-")      -- the original file is untouched
    T.eq(doc.abs_filename, copy_abs)
    T.ok(not doc:is_dirty())
    -- the doc now follows the copy
    ready(doc, 2)
    doc:insert(2, 1, "again\n")
    doc:save()
    T.eq(T.sh_ok("head -c 16 " .. ctx.posix .. ".copy"), "copy edit\nagain\n")
    T.fails(function() doc:save("local.txt", os.getenv("TEMP") .. PATHSEP .. "local.txt") end, "local path")
    -- the edit script refers to the original file: another host cannot apply it
    T.fails(function() doc:save("x.txt", paths.make("no-such-host.invalid", "/tmp/x.txt")) end, "host it was opened from")
    T.eq(doc.abs_filename, copy_abs)
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: an undo refused while a save runs keeps the undo history", function()
    local h = T.connect()
    local ctx = work_copy()
    local doc = open(ctx)
    ready(doc, 101)
    local l = doc.lines[101]
    doc:insert(101, 5, "abc")
    local undo_idx, redo_idx = doc.undo_stack.idx, doc.redo_stack.idx
    doc.remote.saving = true
    doc:undo()
    doc.remote.saving = false
    T.eq(doc.lines[101]:sub(1, 12), "xxxxabcxxxxx", "nothing undone")
    T.eq(doc.undo_stack.idx, undo_idx, "undo entry kept")
    T.eq(doc.redo_stack.idx, redo_idx)
    doc:undo()
    T.eq(doc.lines[101], l)
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: a step refused in the middle of an undo group rolls the group back", function()
    -- plugins that wrap raw_insert / raw_remove must pass the refusal on
    require "plugins.linewrapping"
    local h = T.connect()
    local ctx = work_copy()
    local doc = open(ctx)
    ready(doc, 101); ready(doc, 300)
    local l101, l300 = doc.lines[101], doc.lines[300]
    -- one undo group: both inserts within undo_merge_timeout
    doc:insert(101, 5, "abc")
    doc:insert(300, 5, "def")
    local undo_idx, redo_idx = doc.undo_stack.idx, doc.redo_stack.idx
    -- the file turns stale after the first step of the undo (as when a fetch
    -- finds it changed on the server)
    local Doc = getmetatable(doc)
    doc.raw_remove = function(self, ...)
      local res = Doc.raw_remove(self, ...)
      -- what docs.mark_stale does (without its nag)
      self.remote.stale = true
      if self.buffer.set_stale then self.buffer:set_stale(true) end
      return res
    end
    doc:undo()
    doc.raw_remove = nil
    T.eq(doc.undo_stack.idx, undo_idx, "undo entries kept")
    T.eq(doc.redo_stack.idx, redo_idx, "no redo entries")
    -- (a stale buffer reads as placeholders)
    doc.remote.stale = false
    if doc.buffer.set_stale then doc.buffer:set_stale(false) end
    T.eq(doc:get_text(101, 1, 101, 13), "xxxxabcxxxxx", "first insert kept")
    T.eq(doc:get_text(300, 1, 300, 13), "xxxxdefxxxxx", "second insert restored")
    doc:undo()
    T.eq(doc.lines[101], l101)
    T.eq(doc.lines[300], l300)
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: a failed reload keeps the document and its remote state", function()
    local h = T.connect()
    local docs = require "plugins.thither.docs"
    local ctx = work_copy()
    local doc = open(ctx)
    ready(doc, 1)
    doc:insert(1, 1, "kept\n")
    local r = doc.remote
    T.sh_ok("mv " .. ctx.posix .. " " .. ctx.posix .. ".away")
    h.cache:clear()
    T.ok(not pcall(doc.reload, doc), "reload of a missing file fails")
    T.eq(doc.remote, r, "remote state kept")
    T.ok(doc.buffer:is_remote())
    T.eq(doc.lines[1], "kept\n")
    T.sh_ok("mv " .. ctx.posix .. ".away " .. ctx.posix)
    -- a remote buffer without its state is never saved as a small file
    docs.release(doc)
    T.fails(function() doc:save() end, "lost its server state")
    T.eq(T.sh_ok("head -c 9 " .. ctx.posix), "SENTINEL-")
  end)

  T.test("large: replace-all and line scanners are disabled, other features guarded", function()
    local h = T.connect()
    local ctx = work_copy()
    local doc = open(ctx)
    local res = doc:replace(function(s) return s:upper(), 1 end)
    T.eq(next(res), nil)
    T.ok(not doc:is_dirty())
    local tw = require "plugins.trimwhitespace"
    tw.trim(doc)
    T.ok(not doc:is_dirty())
    require("plugins.thither.docs").release(doc)
  end)

  T.test("large: the pump survives a dropped connection and resumes after reconnect", function()
    local h = T.connect()
    local ctx = work_copy(true)
    local doc = open(ctx)
    ready(doc, 1)
    local conn = h.conn
    -- drop the transport while a chunk is wanted
    T.eq(doc.lines[6000000], PH)
    conn.proc:kill()
    T.wait_for(function() return conn.state ~= "ready" end, 10, "disconnect noticed")
    T.sleep(0.3)
    T.eq(doc.lines[6000000], PH, "still a placeholder while disconnected")
    -- automatic reconnect (delays are tiny in the tests)
    T.wait_for(function() return conn.state == "ready" end, 30, "auto reconnect")
    T.wait_for(function() return doc.lines[6000000] ~= PH end, 30, "chunk after reconnect")
    T.ok(not doc.remote.stale)
    -- the file changes while we are away: revalidation marks it stale
    conn.proc:kill()
    T.wait_for(function() return conn.state ~= "ready" end, 10, "second disconnect")
    T.sh_ok("sleep 0.05; printf 'y' >> " .. ctx.posix)
    T.wait_for(function() return conn.state == "ready" end, 30, "second reconnect")
    T.wait_for(function() return doc.remote.stale end, 15, "stale after reconnect")
    require("plugins.thither.docs").release(doc)
  end)
end
