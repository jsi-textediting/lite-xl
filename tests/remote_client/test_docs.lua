-- Ordinary (small) remote documents: load through the shim, etag checked save,
-- conflicts, external changes.
return function(T)
  local paths = require "core.remote.paths"

  local function new_doc(m, name, new_file)
    local Doc = require "core.doc"
    local abs = paths.join(m, name)
    return Doc(name, abs, new_file), abs
  end

  T.test("doc: small remote file loads, edits and saves with etag check", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("printf 'alpha\\r\\nbeta\\r\\ngamma\\r\\n' > " .. dir .. "/crlf.txt && printf 'one\\ntwo\\n' > " .. dir .. "/lf.txt")
    local doc, abs = new_doc(m, "crlf.txt")
    T.eq(#doc.lines, 3)
    T.eq(doc.lines[2], "beta\n")
    T.eq(doc.crlf, true)
    T.ok(doc.remote and doc.remote.small and doc.remote.etag, "etag recorded")
    T.ok(not doc.large_file)
    doc:insert(2, 1, "NEW ")
    T.ok(doc:is_dirty())
    doc:save()
    T.ok(not doc:is_dirty())
    T.eq(T.sh_ok("cat " .. dir .. "/crlf.txt"), "alpha\r\nNEW beta\r\ngamma\r\n")
    -- the etag follows our own save: a second save needs no reload
    doc:insert(1, 1, "x")
    doc:save()
    T.eq(T.sh_ok("head -c 12 " .. dir .. "/crlf.txt"), "xalpha\r\nNEW ")
    local lf = new_doc(m, "lf.txt")
    T.eq(lf.crlf, nil)
    T.eq(lf.lines[1], "one\n")
  end)

  T.test("doc: new remote file is created, existing one is not silently replaced", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    local doc, abs = new_doc(m, "fresh.txt", true)
    doc.crlf = false
    doc:insert(1, 1, "hello")
    doc:save()
    T.eq(T.sh_ok("cat " .. dir .. "/fresh.txt"), "hello\n")
    -- somebody else creates the file first: "must not exist" turns into a conflict
    local doc2 = new_doc(m, "race.txt", true)
    doc2.crlf = false
    T.sh_ok("echo theirs > " .. dir .. "/race.txt")
    doc2:insert(1, 1, "mine")
    local ok, err = pcall(doc2.save, doc2)
    T.ok(not ok)
    T.ok(type(err) == "table" and err.remote_conflict, tostring(err))
    T.eq(T.sh_ok("cat " .. dir .. "/race.txt"), "theirs\n")
  end)

  T.test("doc: save conflict offers overwrite / reload", function()
    local h = T.connect()
    local docs = require "core.remote.docs"
    local dir, m = T.tmpdir()
    T.sh_ok("printf 'base\\n' > " .. dir .. "/c.txt")
    local doc = new_doc(m, "c.txt")
    doc:insert(1, 1, "mine ")
    T.sh_ok("sleep 0.05; printf 'theirs\\n' > " .. dir .. "/c.txt")
    local ok, err = pcall(doc.save, doc)
    T.ok(not ok and type(err) == "table" and err.remote_conflict, "conflict")
    T.eq(T.sh_ok("cat " .. dir .. "/c.txt"), "theirs\n")
    T.ok(doc:is_dirty(), "still dirty")
    -- overwrite
    local retried
    docs.conflict_nag(doc, err, function() retried = pcall(doc.save, doc) end)
    T.answer_nag("Save Conflict", "Overwrite")
    T.wait_for(function() return retried ~= nil end, 10, "retry after overwrite")
    T.ok(retried)
    T.eq(T.sh_ok("cat " .. dir .. "/c.txt"), "mine base\n")
    -- conflict again, this time reload
    T.sh_ok("sleep 0.05; printf 'v3\\n' > " .. dir .. "/c.txt")
    doc:insert(1, 1, "again ")
    ok, err = pcall(doc.save, doc)
    T.ok(not ok and err.remote_conflict)
    docs.conflict_nag(doc, err)
    T.answer_nag("Save Conflict", "Reload")
    T.wait_for(function() return doc.lines[1] == "v3\n" end, 10, "reload")
    T.ok(not doc:is_dirty())
  end)

  T.test("doc: external change reloads a clean doc and nags for a dirty one", function()
    local h = T.connect()
    local vfs = require "core.remote.vfs"
    local dir, m = T.tmpdir()
    T.sh_ok("printf 'v1\\n' > " .. dir .. "/w.txt && printf 'd1\\n' > " .. dir .. "/d.txt")
    local clean, dirty = new_doc(m, "w.txt"), new_doc(m, "d.txt")
    vfs.ensure_watch(h, dir)
    T.watch_ready(h)
    dirty:insert(1, 1, "local ")
    T.sh_ok("sleep 0.05; printf 'v2\\n' > " .. dir .. "/w.txt; printf 'd2\\n' > " .. dir .. "/d.txt")
    T.wait_for(function() return clean.lines[1] == "v2\n" end, 10, "auto reload")
    T.wait_for(function() return T.nag_count("File Changed") >= 1 end, 10, "nag for the dirty doc")
    T.ok(dirty.lines[1]:find("local d1"), "dirty doc keeps its text")
    T.answer_nag("File Changed", "Yes")
    T.wait_for(function() return dirty.lines[1] == "d2\n" end, 10, "reload after yes")
  end)

  T.test("doc: server errors on load surface as errors", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    local Doc = require "core.doc"
    T.fails(function() Doc("nope.txt", paths.join(m, "nope.txt")) end, "No such file")
  end)

  T.test("doc: remote large file cannot be saved to a local path", function()
    -- covered with the large file tests; here only the guard on small docs
    local h = T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("printf 'x\\n' > " .. dir .. "/s.txt")
    local doc = new_doc(m, "s.txt")
    local tmp = os.getenv("TEMP") .. PATHSEP .. "lxc-local-save.txt"
    doc:save("lxc-local-save.txt", tmp)     -- small docs can be saved locally (save-as)
    T.eq(io.open(tmp, "rb"):read("a"), "x\n")
    os.remove(tmp)
  end)

  T.test("doc: two saves running at once do not conflict with each other", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("printf 'one\\n' > " .. dir .. "/twice.txt")
    local doc = new_doc(m, "twice.txt")
    doc:insert(1, 1, "a")
    local r1, r2
    T.core.add_thread(function() r1 = table.pack(pcall(doc.save, doc)) end)
    T.core.add_thread(function() r2 = table.pack(pcall(doc.save, doc)) end)
    T.wait_for(function() return r1 and r2 end, 20, "both saves")
    T.ok(r1[1], tostring(r1[2]))
    T.ok(r2[1], tostring(r2[2]))
    T.eq(T.nag_count("Save Conflict"), 0)
    T.eq(T.sh_ok("cat " .. dir .. "/twice.txt"), "aone\n")
    T.ok(not doc:is_dirty())
  end)

  T.test("doc: a CRLF piece-tree document saved to a remote path keeps its line ends", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    local config = require "core.config"
    local Doc = require "core.doc"
    local tmp = os.getenv("TEMP") .. PATHSEP .. "lxc-crlf-piece.txt"
    local f = assert(io.open(tmp, "wb"))
    f:write("alpha\r\nbeta\r\n")
    f:close()
    local old = config.use_piece_tree
    config.use_piece_tree = true
    local ok, err = pcall(function()
      local doc = Doc("lxc-crlf-piece.txt", tmp)
      T.ok(doc.buffer and doc.crlf, "opened as a CRLF piece-tree buffer")
      doc:save("crlf.txt", paths.join(m, "crlf.txt"))
    end)
    config.use_piece_tree = old
    os.remove(tmp)
    if not ok then error(err, 0) end
    T.eq(T.sh_ok("cat " .. dir .. "/crlf.txt"), "alpha\r\nbeta\r\n")
  end)

  T.test("doc: a refused edit in the middle of an undo group rolls the group back", function()
    local Doc = require "core.doc"
    local doc = Doc()
    doc:insert(1, 1, "hello\n")
    doc:insert(2, 1, "world")          -- same undo group (within undo_merge_timeout)
    local undo_idx, redo_idx = doc.undo_stack.idx, doc.redo_stack.idx
    -- the second removal of the group is refused (like a remote large document can)
    local calls = 0
    doc.raw_remove = function(self, ...)
      calls = calls + 1
      if calls == 2 then return false end
      return Doc.raw_remove(self, ...)
    end
    doc:undo()
    T.eq(calls, 2)
    T.eq(doc:get_text(1, 1, math.huge, math.huge), "hello\nworld")
    T.eq(doc.undo_stack.idx, undo_idx, "undo stack kept")
    T.eq(doc.redo_stack.idx, redo_idx, "nothing to redo")
    doc.raw_remove = nil
    doc:undo()
    T.eq(doc:get_text(1, 1, math.huge, math.huge), "")
    doc:redo()
    T.eq(doc:get_text(1, 1, math.huge, math.huge), "hello\nworld")
  end)
end
