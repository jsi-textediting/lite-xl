--- Mount-root path forms for remote files (see docs/remote-protocol.md, "Path forms").
---
---   POSIX client:   /.lxl-remote/<host>/<abs path>
---   Windows client: \\lxl-remote\<host>\<abs path with \>
---
--- This module is tiny and has no dependencies on the editor, so it can be
--- loaded at startup and used on hot paths (`is_remote` is the only thing the
--- shimmed system/io/os functions call for a local path).
local paths = {}

local byte, sub, lower, gsub, find = string.byte, string.sub, string.lower, string.gsub, string.find

local WIN = package.config:sub(1, 1) == "\\"
local SEP = WIN and "\\" or "/"

paths.WINDOWS = WIN
paths.SEP = SEP
paths.PREFIX = WIN and "\\\\lxl-remote\\" or "/.lxl-remote/"
local PREFIX = paths.PREFIX
local PLEN = #PREFIX
local PLOWER = lower(PREFIX)
local B1 = byte(PREFIX, 1)

--- Fast test: is `p` below the remote mount root (or the mount root itself
--- without trailing separator)? Costs one byte compare for ordinary paths.
function paths.is_remote(p)
  if type(p) ~= "string" then return false end
  local b = byte(p, 1)
  if b ~= B1 and not (WIN and b == 47) then return false end
  local s = sub(p, 1, PLEN)
  if WIN then s = lower((gsub(s, "/", "\\"))) end
  return s == (WIN and PLOWER or PREFIX)
end

--- Makes a host name safe for use as a path component and for display.
--- "wsl:" -> "wsl", "wsl:Ubuntu" -> "wsl-Ubuntu", "me@box" stays.
function paths.sanitize_host(spec)
  local s = tostring(spec or "")
  s = gsub(s, "^(%w+):$", "%1")
  s = gsub(s, "[:/\\%s]+", "-")
  s = gsub(s, "^%-+", ""):gsub("%-+$", "")
  return s
end

--- Lexically resolves `.`, `..` and empty components of an absolute POSIX path.
local function clean_posix(p)
  local parts = {}
  for part in string.gmatch(p, "[^/]+") do
    if part == ".." then parts[#parts] = nil
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  return "/" .. table.concat(parts, "/")
end
paths.clean_posix = clean_posix

--- Splits a mount-root path into host and absolute POSIX path on the server.
--- Returns nil for paths that are not remote. `..` is resolved lexically
--- (never above the host root).
function paths.parse(p)
  if type(p) ~= "string" or not paths.is_remote(p) then return nil end
  local rest = sub(p, PLEN + 1)
  if WIN then rest = gsub(rest, "\\", "/") end
  local host, tail = rest:match("^([^/]+)(.*)$")
  if not host then return nil end
  return host, clean_posix(tail ~= "" and tail or "/")
end

--- Builds the mount-root path of `rpath` (absolute POSIX path) on `host`.
function paths.make(host, rpath)
  rpath = clean_posix(rpath or "/")
  if WIN then
    if rpath == "/" then return PREFIX .. host .. "\\" end
    return PREFIX .. host .. gsub(rpath, "/", "\\")
  end
  if rpath == "/" then return PREFIX .. host end
  return PREFIX .. host .. rpath
end

--- The remote root `/` of a host as a mount path (what a project at "/" uses).
function paths.host_root(host)
  return paths.make(host, "/")
end

--- Normalizes the textual form of a remote path (slashes, `.`/`..`) without
--- touching the network. Non remote paths are returned unchanged.
function paths.normalize(p)
  local host, rpath = paths.parse(p)
  if not host then return p end
  return paths.make(host, rpath)
end

--- Parent directory of a mount-root path; nil above the host root.
function paths.dirname(p)
  local host, rpath = paths.parse(p)
  if not host or rpath == "/" then return nil end
  return paths.make(host, (rpath:match("^(.*)/[^/]+$") or ""))
end

--- Last component of the remote path (the host name for the host root).
function paths.basename(p)
  local host, rpath = paths.parse(p)
  if not host then return nil end
  if rpath == "/" then return host end
  return rpath:match("([^/]+)$")
end

--- Joins a mount-root directory and a child name.
function paths.join(dir, name)
  local host, rpath = paths.parse(dir)
  if not host then return dir .. SEP .. name end
  return paths.make(host, (rpath == "/" and "" or rpath) .. "/" .. name)
end

--- Splits "host:/path" (or "wsl:/path", "wsl:Ubuntu:/path", "user@h:/p") into
--- host spec and POSIX path. A bare host spec gives path nil.
function paths.split_location(s)
  s = tostring(s or ""):match("^%s*(.-)%s*$")
  local host, rpath = s:match("^(.-):(/.*)$")
  if host and host ~= "" then return host, rpath end
  host, rpath = s:match("^(.-):~(/.*)$")  -- "host:~/dir" (not expanded here)
  if host then return host, "~" .. rpath end
  if s ~= "" and not s:find("/", 1, true) then return s, nil end
  return nil
end

return paths
