# Runs the remote client tests with the real Windows editor binary against the
# real thither-server inside WSL (transport "wsl:", no sshd needed).
#
#   powershell -File tests\remote_client\run.ps1                 # headless, all tests
#   powershell -File tests\remote_client\run.ps1 -Filter large   # name filter
#   powershell -File tests\remote_client\run.ps1 -Real           # inside the real editor window
#
# Requirements: the editor built (cmake --build build --config Release), WSL with
# the server built (see docs/protocol.md in the thither repo, "Running and building"),
# the thither repo checked out next to this one (or $env:THITHER_REPO), `rg`, `cp`, `cmp`, `python3` and ~3 GB free in /tmp inside WSL for the large file tests.
param(
  [string]$Filter = "",
  [switch]$Real,
  [string]$Exe = "",
  [string]$Server = "",          # server executable as seen from the server side
  [Alias("Host")][string]$SshHost = "",   # real host (PuTTY session / user@host); empty = WSL
  [string]$ServerData = "",      # optional server --datadir on that host (with -Host); the binary embeds its Lua
  [switch]$NoRg,                 # the host has no rg: skip tests that need it
  [int]$BigMB = 1024,            # size of the large file test
  [int]$Timeout = 900
)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
# the server lives in its own repository, by default a sibling of this one
$thither = if ($env:THITHER_REPO) { $env:THITHER_REPO } else { Join-Path $repo "..\thither" }
if (-not $Exe) { $Exe = Join-Path $repo "build\src\Release\lite-xl.exe" }
if (-not (Test-Path $Exe)) { throw "editor binary not found: $Exe (build it first)" }

# The editor looks for data/ next to the binary or in <prefix>/share/lite-xl:
# a junction to the repository's data directory serves as the prefix.
$stage = Join-Path $env:TEMP "lxc-stage"
$share = Join-Path $stage "share"
New-Item -ItemType Directory -Force $share | Out-Null
$link = Join-Path $share "lite-xl"
if (-not (Test-Path $link)) {
  New-Item -ItemType Junction -Path $link -Target (Join-Path $repo "data") | Out-Null
}

if ($SshHost) {
  if (-not $Server) { throw "-Host needs -Server (path of thither-server on the host)" }
  if (-not (Get-Command plink -ErrorAction SilentlyContinue)) { throw "plink not on PATH" }
} elseif (-not $Server) {
  $wslhome = (wsl.exe -e sh -c 'echo $HOME').Trim()
  $Server = "$wslhome/thither-build/thither-server"
}
# WSL runs use the thither working tree's Lua modules; a real host uses the embedded ones
$datadir = if ($SshHost) { $ServerData } else {
  $lua = Join-Path $thither "lua"
  if (-not (Test-Path $lua)) { throw "thither repo not found: $thither (set THITHER_REPO)" }
  (wsl.exe -e wslpath -a (Resolve-Path $lua).Path).Trim()
}

$tests = $PSScriptRoot
$userdir = $tests
if ($Real) {
  # the real editor writes into its user directory: use a scratch copy
  $userdir = Join-Path $env:TEMP "lxc-user"
  if (Test-Path $userdir) { Remove-Item -Recurse -Force $userdir }
  New-Item -ItemType Directory -Force $userdir | Out-Null
  Copy-Item (Join-Path $tests "*.lua") $userdir
}

$env:LITE_PREFIX = $stage
$env:LITE_USERDIR = $userdir
$env:LITE_XL_RUNTIME = "lxc_runtime"
$env:LXC_TESTS = $tests
$env:LXC_SERVER = $Server
$env:LXC_DATADIR = $datadir
$env:LXC_FILTER = $Filter
$env:LXC_HOST = $SshHost
$env:LXC_NO_RG = $(if ($NoRg) { "1" } else { "0" })
$env:LXC_BIG_MB = "$BigMB"
$env:LXC_REAL = $(if ($Real) { "1" } else { "0" })

$p = Start-Process -FilePath $Exe -NoNewWindow -PassThru -Wait:$false
$null = $p.Handle     # keep the handle: ExitCode is empty otherwise
if (-not $p.WaitForExit($Timeout * 1000)) {
  $p.Kill()
  throw "tests timed out after $Timeout s"
}
exit $p.ExitCode
