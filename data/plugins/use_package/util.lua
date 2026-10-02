local M = {}

-- Run a command to completion from inside a coroutine (core.add_thread).
-- Both pipes are drained while waiting so a chatty child can't block on a full
-- pipe. The child is killed after `timeout` seconds (default 300).
-- Returns (combined_output, returncode); returncode is -1 on spawn failure/timeout.
function M.exec(cmd, opts, timeout)
  local ok, proc = pcall(process.start, cmd, opts or {})
  if not ok or not proc then return tostring(ok and 'failed to start process' or proc), -1 end
  local deadline = system.get_time() + (timeout or 300)
  local out, err = {}, {}
  local function drain()
    local o, e = proc:read_stdout(), proc:read_stderr()
    if o and #o > 0 then out[#out + 1] = o end
    if e and #e > 0 then err[#err + 1] = e end
  end
  while proc:running() do
    drain()
    if system.get_time() > deadline then
      proc:kill()
      drain()
      return table.concat(out) .. table.concat(err) .. '\n[use-package] command timed out', -1
    end
    coroutine.yield(0.05)
  end
  drain()
  return table.concat(out) .. table.concat(err), proc:returncode()
end

-- Blocking variant for callers outside a coroutine. No shell is involved.
function M.execSync(cmd, timeout_ms)
  local ok, proc = pcall(process.start, cmd, {})
  if not ok or not proc then return false end
  local rc = proc:wait(timeout_ms or 10000)
  if rc == nil then proc:kill() return false end
  return rc == 0
end

-- Run a shell command string inside a working directory, cross-platform.
function M.runInDir(cmd, dir)
  local shell
  if PLATFORM == 'Windows' then
    shell = {'cmd', '/c', cmd}
  else
    shell = {'sh', '-c', cmd}
  end
  return M.exec(shell, {cwd = dir})
end

function M.gitCmd(args, dir)
  return M.exec({'git', '-C', dir, table.unpack(args)})
end

-- Current HEAD commit of a repo, or nil.
function M.gitHead(dir)
  local out, code = M.gitCmd({'rev-parse', 'HEAD'}, dir)
  if code ~= 0 then return nil end
  return (out:gsub('%s+', ''))
end

-- Plugin / addon names must be a single safe path component.
function M.validName(name)
  return type(name) == 'string' and name ~= '' and name ~= '.' and name ~= '..'
     and name:match('^[%w_.-]+$') ~= nil and not name:find('..', 1, true)
end

-- Relative path inside a repo (addon.path): no absolute paths, drive letters or "..".
function M.validRelPath(path)
  if type(path) ~= 'string' or path == '' then return false end
  if path:match('^[/\\]') or path:find(':', 1, true) then return false end
  for seg in path:gmatch('[^/\\]+') do
    if seg == '..' then return false end
  end
  return true
end

-- Destination under USERDIR/plugins or USERDIR/libraries for a validated name.
-- Returns dest, or nil + error.
function M.destPath(name, library)
  if not M.validName(name) then
    return nil, string.format('[use-package] invalid plugin name: %s', tostring(name))
  end
  return M.normPath(USERDIR .. (library and '/libraries/' or '/plugins/') .. name)
end

-- Only network git remotes are cloned (local paths never reach git clone).
function M.validCloneURL(url)
  if type(url) ~= 'string' or url:sub(1, 1) == '-' then return false end
  return url:match('^https://[^%s]+$') ~= nil
      or url:match('^ssh://[^%s]+$') ~= nil
      or url:match('^git@[%w_.-]+:[^%s]+$') ~= nil
end

function M.isURL(url)
  return url:match('^%w+://')
end

-- Returns "Author/RepoName" if url matches that pattern, else nil.
function M.slugify(url)
  return url:match('^[^/]+/[^/]+$')
end

-- Derive a short plugin name from a URL or slug.
-- Strips ".lxl" suffix and "lite-xl-" prefix.
function M.plugName(url)
  local name = string.lower(url:match('[^/]+$'))
  return name:gsub('%.lxl$', ''):gsub('^lite%-xl%-', '')
end

-- Normalize path separators to the OS separator and collapse duplicate separators.
-- On Windows: converts all '/' to '\', then collapses consecutive '\' into one
-- (UNC paths starting with '\\' are preserved).
function M.normPath(path)
  if PLATFORM == 'Windows' then
    path = path:gsub('/', '\\')
    if path:sub(1, 2) == '\\\\' then
      return '\\\\' .. path:sub(3):gsub('\\+', '\\')
    end
    return (path:gsub('\\+', '\\'))
  end
  return path
end

-- Create all missing directory segments in path, like mkdir -p.
function M.mkdirp(path)
  path = M.normPath(path)
  local sep = PATHSEP == '\\' and '\\' or '/'
  local parts = {}
  for seg in path:gmatch('[^' .. sep .. ']+') do
    parts[#parts + 1] = seg
  end
  local cur = path:sub(1, 1) == sep and sep or ''
  for _, seg in ipairs(parts) do
    cur = cur == '' and seg or (cur .. sep .. seg)
    if not system.get_file_info(cur) then
      system.mkdir(cur)
    end
  end
end

-- Works for both files and directories, and resolves junction points on Windows.
function M.fileExists(path)
  return system.get_file_info(M.normPath(path)) ~= nil
end

-- Binary-safe single-file copy.
local function copyFile(src, dest)
  local fi, err = io.open(src, 'rb')
  if not fi then return false, err end
  local fo, err2 = io.open(dest, 'wb')
  if not fo then fi:close(); return false, err2 end
  local CHUNK = 65536
  repeat
    local buf = fi:read(CHUNK)
    if buf then fo:write(buf) end
  until not buf
  fi:close(); fo:close()
  return true
end

-- Recursively copy a file or directory using only lite-xl built-ins.
-- No external processes; works on all platforms.
function M.copy(src, dest)
  local info = system.get_file_info(src)
  if not info then return false, 'source not found: ' .. src end
  if info.type == 'dir' then
    M.mkdirp(dest)
    for _, item in ipairs(system.list_dir(src) or {}) do
      local ok, err = M.copy(src .. PATHSEP .. item, dest .. PATHSEP .. item)
      if not ok then return false, err end
    end
    return true
  end
  local parent = dest:match('^(.*)[/\\][^/\\]+$')
  if parent then
    M.mkdirp(parent)
  end
  return copyFile(src, dest)
end

-- Recursively remove a file or directory, like rm -rf.
-- Safely handles symlinks without recursing into target directories.
function M.rmrf(path)
  path = M.normPath(path)
  -- Try removing as a regular file or symlink first without following the link.
  -- In POSIX, os.remove() unlinks files and symlinks (including symlinks pointing
  -- to directories) without touching the target directory contents.
  local ok, err = os.remove(path)
  if ok then return true end

  local info = system.get_file_info(path)
  if not info then
    -- Broken symlink or nonexistent path; attempt removal once more
    os.remove(path)
    return
  end

  -- If it's a symlink (or Windows junction point), NEVER recurse into the target!
  if info.symlink then
    if PLATFORM == 'Windows' then
      system.rmdir(path)
    else
      os.remove(path)
    end
    return
  end

  if info.type == 'dir' then
    for _, item in ipairs(system.list_dir(path) or {}) do
      M.rmrf(path .. PATHSEP .. item)
    end
    os.remove(path)
  end
end

-- True for paths the user intends as local filesystem references.
-- Handles Unix-style (~/, /, ./, ../) and Windows absolute paths (C:\, D:\).
function M.isLocalPath(path)
  local prefixes = { '~/', '/', '../', './' }
  for _, pref in ipairs(prefixes) do
    if path:find(pref, 1, true) == 1 then return true end
  end
  -- Windows: drive letter followed by backslash (C:\, D:\, etc.)
  if path:match('^%a:[/\\]') then return true end
  return false
end

function M.hexify(str)
  return (str:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

function M.dehexify(hex)
  return (hex:gsub('%x%x', function(d) return string.char(tonumber(d, 16)) end))
end

-- Extract the tag from a "url:tag" or "path:tag" string. Returns nil if no tag present.
-- Matches :tag at the end of the string, ensuring tag contains no slashes or colons.
function M.repoTag(repo)
  return repo:match(':([^/\\:]+)$')
end

-- Strip the ":tag" suffix from a "url:tag" or "path:tag" string, returning the URL or path.
-- For local paths, expands ~ to full home directory and normalizes path separators.
function M.repoURL(repo)
  local tag = M.repoTag(repo)
  local base = tag and repo:sub(1, #repo - #tag - 1) or repo
  if M.isLocalPath(base) then
    local ok, common = pcall(require, 'core.common')
    if ok and common and common.home_expand then
      base = common.home_expand(base)
    end
    base = M.normPath(base)
    if #base > 1 then
      base = base:gsub('[/\\]+$', '')
    end
    return base
  end
  return base
end

function M.repoDir(repo)
  return M.hexify(M.repoURL(repo))
end

function M.join(parts)
  local str = ''
  local sep_pat = string.format('%s$', '%' .. PATHSEP)
  for i, part in ipairs(parts) do
    local has_sep = part:match(sep_pat)
    str = str .. part .. (has_sep and '' or i == #parts and '' or PATHSEP)
  end
  return str:gsub(string.format('%s$', '%' .. PATHSEP), '')
end

-- Compares two semantic version strings (e.g. "0.2.1" vs "0.2.0").
-- Returns 1 if v1 > v2, -1 if v1 < v2, 0 if v1 == v2.
function M.compareVersions(v1, v2)
  if not v1 or not v2 then return 0 end
  local p1, p2 = {}, {}
  for num in tostring(v1):gmatch('%d+') do table.insert(p1, tonumber(num)) end
  for num in tostring(v2):gmatch('%d+') do table.insert(p2, tonumber(num)) end
  local len = math.max(#p1, #p2)
  for i = 1, len do
    local n1 = p1[i] or 0
    local n2 = p2[i] or 0
    if n1 > n2 then return 1 end
    if n1 < n2 then return -1 end
  end
  return 0
end

return M
