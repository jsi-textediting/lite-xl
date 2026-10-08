--- Options of the remote client: `config.plugins.remote.<name>`, optionally
--- overridden per host with `config.plugins.remote.hosts["<host label>"].<name>`.
local options = {}

local WIN = package.config:sub(1, 1) == "\\"

options.defaults = {
  -- argv prefix of the ssh client; the target and the remote command are appended
  ssh_command = WIN and { "plink", "-ssh", "-batch", "-T" }
                     or { "ssh", "-T", "-o", "ServerAliveInterval=15", "-o", "BatchMode=yes" },
  identity = nil,             -- private key (.ppk for plink, OpenSSH key otherwise)
  port = nil,                 -- ssh port
  user = nil,                 -- ssh user when the host spec has none
  server_path = "thither-server",
  server_args = {},           -- extra arguments for the server (e.g. { "--datadir", "/x" })
  wsl_command = "wsl.exe",    -- transport "wsl:" (testing without sshd)
  wsl_server_path = nil,      -- defaults to server_path
  hello_timeout = 30,         -- seconds to wait for the handshake
  request_timeout = 30,       -- default timeout of blocking calls
  ping_interval = 15,         -- heartbeat
  ping_timeout = 45,          -- no data for this long after a ping: connection is dead
  auto_reconnect = true,
  reconnect_delays = { 1, 2, 5, 10, 20 },
  chunk_size = 262144,        -- chunk size of remote large files
  cache_budget_mb = 256,      -- resident bytes per remote large file
  read_size = 1048576,        -- bytes per read request for small files
  stat_ttl = 60,              -- stat/readdir cache lifetime while a watch is active
  stat_ttl_nowatch = 2,       -- ... and without
  watch = true,
  recent_hosts = 12,
  rewrite_output = true,      -- map remote paths in exec output back to mount paths
  exec_window = 1048576,      -- unacknowledged exec output bytes in flight (0 = unlimited)
}

local function user_config()
  local ok, config = pcall(require, "core.config")
  if not ok then return {} end
  return config.plugins.remote
end

--- Returns option `name` for the host with label `label` (may be nil).
function options.get(name, label)
  local c = user_config()
  if label then
    local hosts = c.hosts
    local h = type(hosts) == "table" and hosts[label]
    if type(h) == "table" and h[name] ~= nil then return h[name] end
  end
  local v = c[name]
  if v ~= nil then return v end
  return options.defaults[name]
end

return options
