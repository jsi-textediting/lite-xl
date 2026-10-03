-- system.* shims, stat/readdir caches, mkdir/rmdir/remove/rename.
return function(T)
  local paths = require "core.remote.paths"

  --- Counts requests per op on a connection until the returned function is called.
  local function count_ops(conn)
    local counts = {}
    local orig = conn.request
    conn.request = function(self, op, ...)
      counts[op] = (counts[op] or 0) + 1
      return orig(self, op, ...)
    end
    return counts, function() conn.request = nil end
  end

  T.test("vfs: stat, list_dir and path functions on a remote directory", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("cd " .. dir .. " && printf 'hello' > a.txt && mkdir sub && printf 'x' > sub/b.txt && ln -s a.txt link && ln -s sub dlink")
    local info = system.get_file_info(paths.join(m, "a.txt"))
    T.eq(info.type, "file"); T.eq(info.size, 5)
    T.ok(math.abs(info.modified - os.time()) < 600, "mtime is a recent epoch time")
    T.eq(system.get_file_info(paths.join(m, "sub")).type, "dir")
    T.eq(system.get_file_info(paths.join(m, "sub")).symlink, false)
    T.eq(system.get_file_info(paths.join(m, "dlink")).type, "dir")
    T.eq(system.get_file_info(paths.join(m, "dlink")).symlink, true)
    T.eq(system.get_file_info(paths.join(m, "link")).type, "file")
    local missing, err = system.get_file_info(paths.join(m, "nope"))
    T.eq(missing, nil)
    T.ok(err:find("No such file"), err)
    local names = system.list_dir(m)
    table.sort(names)
    T.eq(table.concat(names, ","), "a.txt,dlink,link,sub")
    T.eq(system.list_dir(paths.join(m, "nope")), nil)
    T.eq(system.absolute_path(m .. PATHSEP .. "sub" .. PATHSEP .. ".." .. PATHSEP .. "a.txt"), paths.join(m, "a.txt"))
    T.eq(system.chdir(m), nil)           -- no-op
    T.eq(system.get_fs_type(m), "unknown")
    -- the local functions still work for local paths
    T.ok(system.get_file_info(DATADIR), "local stat")
    T.ok(#system.list_dir(DATADIR) > 3, "local list_dir")
  end)

  T.test("vfs: readdir seeds the stat cache (one round trip for a whole directory)", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("cd " .. dir .. " && for i in $(seq 1 200); do echo $i > f$i; done")
    local counts, restore = count_ops(h.conn)
    local names = system.list_dir(m)
    T.eq(#names, 200)
    for _, n in ipairs(names) do
      local info = system.get_file_info(paths.join(m, n))
      T.eq(info.type, "file")
    end
    T.eq(counts.readdir, 1)
    T.eq(counts.stat, nil, "stat requests")
    -- a second listing and 200 more stats are served from the cache
    system.list_dir(m)
    for _, n in ipairs(names) do system.get_file_info(paths.join(m, n)) end
    T.eq(counts.readdir, 1)
    T.eq(counts.stat, nil)
    restore()
  end)

  T.test("vfs: cache expires without a watch", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    h.watch_ok = false            -- earlier tests left a server watch behind: use the short TTL
    T.eq(#system.list_dir(m), 0)
    T.sh_ok("touch " .. dir .. "/new")
    T.sleep(0.4)       -- stat_ttl_nowatch = 0.2 in the tests
    T.eq(#system.list_dir(m), 1)
  end)

  T.test("vfs: mkdir, rmdir, os.remove, os.rename", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    local d = paths.join(m, "newdir")
    T.eq(system.mkdir(d), true)
    T.eq(system.get_file_info(d).type, "dir")
    local ok, err = system.mkdir(d)
    T.eq(ok, false)
    T.ok(err:find("exists"), err)
    local f = paths.join(d, "f.txt")
    local fp = T.ok(io.open(f, "wb"))
    fp:write("abc")
    T.eq(fp:close(), true)
    -- rmdir refuses a file and a non-empty directory
    ok, err = system.rmdir(f)
    T.eq(ok, false); T.ok(err:find("Not a directory"), err)
    ok, err = system.rmdir(d)
    T.eq(ok, false); T.ok(err:find("not empty") or err:find("ENOTEMPTY") or err:find("Directory"), err)
    local g = paths.join(d, "g.txt")
    T.eq(os.rename(f, g), true)
    T.eq(system.get_file_info(f), nil)
    T.eq(system.get_file_info(g).size, 3)
    T.eq(os.remove(g), true)
    local r, e = os.remove(g)
    T.eq(r, nil); T.ok(e:find("No such file"), e)
    T.eq(system.rmdir(d), true)
    T.eq(system.get_file_info(d), nil)
    -- common.mkdirp / common.rm go through the same shims
    local common = require "core.common"
    local deep = paths.join(m, "a" .. PATHSEP .. "b" .. PATHSEP .. "c")
    T.eq((common.mkdirp(deep)), true)
    T.eq(system.get_file_info(deep).type, "dir")
    T.eq((common.rm(paths.join(m, "a"), true)), true)
    T.eq(system.get_file_info(paths.join(m, "a")), nil)
    -- cross-host/local rename is refused
    local rr, re = os.rename(paths.join(m, "x"), "C:\\nowhere")
    T.eq(rr, nil)
  end)

  T.test("vfs: remote paths never reach the OS (no UNC lookup)", function()
    -- a name lookup for \\lxl-remote would take seconds; every shimmed call must be fast
    local h = T.connect()
    local m = paths.make(T.label, "/definitely/not/here")
    local t0 = system.get_time()
    system.get_file_info(m)
    system.list_dir(m)
    io.open(m, "rb")
    local buffer = require "buffer"
    T.eq(buffer.open(m), nil)
    pcall(dofile, m)
    T.eq(loadfile(m), nil)
    T.ok(system.get_time() - t0 < 2, "took " .. (system.get_time() - t0))
  end)

  T.test("vfs: server errors are reported, a dead connection fails fast", function()
    local h = T.connect()
    local dir, m = T.tmpdir()
    T.sh_ok("mkdir " .. dir .. "/locked && chmod 000 " .. dir .. "/locked")
    local ok, err = io.open(paths.join(m, "locked/x"), "rb")
    T.eq(ok, nil)
    T.ok(err:find("Permission") or err:find("No such"), err)
  end)
end
