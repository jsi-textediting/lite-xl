-- Transport, handshake, ssh command lines.
return function(T)
  T.test("ssh: command lines for ssh / plink / wsl / local transports", function()
    local ssh = require "plugins.thither.ssh"
    local config = require "core.config"
    local rc = config.plugins.thither
    local saved = { rc.ssh_command, rc.identity, rc.port, rc.user }

    rc.ssh_command = { "plink", "-ssh", "-batch", "-T" }
    rc.identity, rc.port, rc.user = "C:\\keys\\k.ppk", 2222, nil
    local argv = ssh.build("me@box", "me@box")
    T.eq(table.concat(argv, " "), "plink -ssh -batch -T -i C:\\keys\\k.ppk -P 2222 me@box thither-server --stdio")

    -- a PuTTY saved session name works the same way
    rc.identity, rc.port = nil, nil
    argv = ssh.build("my session", "my-session")
    T.eq(argv[#argv - 1], "my session")

    rc.ssh_command = { "ssh", "-T", "-o", "BatchMode=yes" }
    rc.port, rc.user = 22, "bob"
    argv = ssh.build("box", "box")
    T.eq(table.concat(argv, " "), "ssh -T -o BatchMode=yes -p 22 bob@box thither-server --stdio")

    -- a server path with spaces is quoted for the remote shell
    rc.hosts = rc.hosts or {}
    rc.hosts.q = { server_path = "/opt/my dir/thither-server", server_args = { "--root", "/data x" } }
    argv = ssh.build("q", "q")
    T.eq(argv[#argv], "'/opt/my dir/thither-server' --stdio --root '/data x'")
    T.fails(function() ssh.build("-oProxyCommand=evil", "x") end, "invalid host")

    argv = ssh.build("wsl:Ubuntu", "wsl-Ubuntu")
    T.eq(table.concat(argv, " "), "wsl.exe -d Ubuntu -e thither-server --stdio")
    argv = ssh.build("local:", "local")
    T.eq(argv[1], "thither-server")

    rc.ssh_command, rc.identity, rc.port, rc.user = saved[1], saved[2], saved[3], saved[4]
    rc.hosts.q = nil
    T.configure_remote()
  end)

  T.test("connect: transport handshake and server info", function()
    local t0 = system.get_time()
    local h = T.connect()
    local conn = h.conn
    T.eq(conn.state, "ready")
    T.eq(conn.hello.proto_version, 1)
    T.ok(conn.caps.large_file and conn.caps.watch and conn.caps.exec)
    T.ok(conn.hello.home:find("^/"))
    io.stdout:write(string.format("      connect took %.0f ms (server %s)\n", (system.get_time() - t0) * 1000,
      conn.hello.server_version))
    local pong = conn:call("ping", { data = "x" })
    T.eq(pong, "x")
  end)

  T.test("connect: blocking call inside a core thread yield-polls", function()
    local h = T.connect()
    local v = T.in_thread(function()
      return h.conn:call("ping", { data = 42 })
    end)
    T.eq(v, 42)
  end)

  T.test("connect: missing server gives a clear failure", function()
    local vfs = require "plugins.thither.vfs"
    local config = require "core.config"
    config.plugins.thither.hosts.nosrv = { server_path = "/nonexistent/thither-server" }
    -- wsl.exe runs but the server does not exist: the transport exits
    local spec = T.spec
    local Conn = require "plugins.thither.client"
    local c = Conn.new(spec, "nosrv")
    local ok = c:start()
    T.ok(ok)
    local ready, why = c:wait_ready(20)
    T.ok(not ready, "must not become ready")
    T.ok(c.state == "failed" or c.state == "closed", "state " .. c.state)
    T.ok(tostring(why):find("did not start") or tostring(why):find("exit"), tostring(why))
    Conn.all.nosrv = nil
  end)

  T.test("real editor: thither commands registered by the plugin, status item after connect", function()
    if not T.real then io.stdout:write("      (skipped outside -Real mode: needs core.init)\n") return end
    local command = require "core.command"
    for _, name in ipairs { "thither:open-project", "thither:disconnect", "thither:reconnect" } do
      T.ok(command.map[name], name .. " is not registered")
    end
    T.eq(package.loaded["plugins.remote"], nil, "the old plugin must not be loaded")
    T.connect()
    T.wait_for(function() return T.core.status_view and T.core.status_view:get_item("thither:status") end, 10, "status item")
    local item = T.core.status_view:get_item("thither:status")
    local txt = {}
    for _, v in ipairs(item.get_item()) do if type(v) == "string" then txt[#txt + 1] = v end end
    io.stdout:write("      status item: " .. (table.concat(txt):gsub("%s+", " ")) .. "\n")
    T.ok(table.concat(txt):find("connected"), "status text")
  end)
end
