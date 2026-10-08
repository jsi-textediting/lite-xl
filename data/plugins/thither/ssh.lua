--- Builds the command line that starts `thither-server --stdio` for a host.
---
--- Transports (chosen by the host spec):
---   `wsl:` / `wsl:<distro>`  wsl.exe -e <server> --stdio   (testing without sshd)
---   `local:`                 <server> --stdio              (server on the same machine)
---   anything else            <ssh_command> [-i key] [-P/-p port] [user@]host "<server> --stdio"
---                            (plink saved session names and user@host both work)
local paths = require "plugins.thither.paths"
local options = require "plugins.thither.options"

local ssh = {}

local shell_quote
function shell_quote(s)
  -- a leading "~/" must stay unquoted so the remote shell expands it
  local home, rest = s:match("^(~/)(.*)$")
  if home then return home .. shell_quote(rest) end
  if s ~= "" and not s:find("[^%w_@%%+=:,./-]") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function copy(t)
  local r = {}
  for i, v in ipairs(t or {}) do r[i] = v end
  return r
end

--- Returns the transport kind of a host spec: "wsl", "local" or "ssh".
function ssh.transport(spec)
  if spec:match("^wsl:") or spec == "wsl" then return "wsl" end
  if spec:match("^local:") or spec == "local" then return "local" end
  return "ssh"
end

--- Returns argv (a table) and a short description for `spec`.
--- `label` selects per-host option overrides.
function ssh.build(spec, label)
  label = label or paths.sanitize_host(spec)
  local get = function(name) return options.get(name, label) end
  local kind = ssh.transport(spec)
  local server = get("server_path")
  local sargs = copy(get("server_args"))

  if kind == "wsl" then
    local argv = { get("wsl_command") }
    local distro = spec:match("^wsl:(.+)$")
    if distro then argv[#argv + 1] = "-d"; argv[#argv + 1] = distro end
    argv[#argv + 1] = "-e"
    argv[#argv + 1] = get("wsl_server_path") or server
    argv[#argv + 1] = "--stdio"
    for _, a in ipairs(sargs) do argv[#argv + 1] = a end
    return argv, "wsl" .. (distro and (" (" .. distro .. ")") or "")
  elseif kind == "local" then
    local argv = { server, "--stdio" }
    for _, a in ipairs(sargs) do argv[#argv + 1] = a end
    return argv, "local"
  end

  local argv = copy(get("ssh_command"))
  assert(#argv > 0, "config.plugins.thither.ssh_command is empty")
  local exe = argv[1]:lower():match("([^/\\]+)$") or ""
  local is_plink = exe:find("plink", 1, true) ~= nil or exe:find("putty", 1, true) ~= nil
  local identity, port, user = get("identity"), get("port"), get("user")
  if identity then argv[#argv + 1] = "-i"; argv[#argv + 1] = identity end
  if port then argv[#argv + 1] = (is_plink and "-P" or "-p"); argv[#argv + 1] = tostring(port) end
  -- A target starting with "-" would be taken for an option by ssh.
  assert(spec:sub(1, 1) ~= "-", "invalid host " .. spec)
  local target = spec
  if user and not spec:find("@", 1, true) then target = user .. "@" .. spec end
  argv[#argv + 1] = target
  local remote = { shell_quote(server), "--stdio" }
  for _, a in ipairs(sargs) do remote[#remote + 1] = shell_quote(a) end
  argv[#argv + 1] = table.concat(remote, " ")
  return argv, target
end

return ssh
