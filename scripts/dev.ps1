# ============================================================================
# Server Monitor 开发运行脚本
#
# 用法（在仓库根目录执行）：
#   pwsh scripts/dev.ps1            # 桌面窗口模式（cargo tauri dev）
#   pwsh scripts/dev.ps1 -Browser   # 纯浏览器模式（后端 + Vite，浏览器打开）
#   pwsh scripts/dev.ps1 -SkipBuild # 跳过 sidecar 编译（仅前端/壳改动时更快）
#   pwsh scripts/dev.ps1 -DryRun    # 只打印将要执行的模式与路径，不启动任何东西
#
# 兼容性：
#   支持 pwsh -File、& 调用、-Command 字符串、stdin 管道等执行方式；
#   定位不到项目根目录时会从当前目录向上搜索仓库特征。
#
# 安全约定：
#   * 本脚本只按 PID 清理“自己启动”的进程，绝不按进程名匹配/杀 node 等系统进程
#   * 全部为只读/启动操作，不改动任何服务器
# ============================================================================
param(
  [switch]$Browser,
  [switch]$SkipBuild,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 定位项目根目录（多级回退，兼容各种调用方式）
# ---------------------------------------------------------------------------
function Find-ProjectRoot {
  param([string]$ScriptDir)

  # 1) 标准执行（-File / .\ 调用）：$PSScriptRoot 或 MyCommand.Path
  if ($ScriptDir) {
    return Split-Path $ScriptDir -Parent
  }
  if ($MyInvocation.MyCommand.Path) {
    return Split-Path $MyInvocation.MyCommand.Path -Parent
  }
  # 2) 从当前目录向上搜索仓库特征（scripts\dev.ps1 与 backend\config.json 同时存在）
  $dir = Get-Location
  while ($dir) {
    $candidate = $dir.Path
    $hasScript = Test-Path (Join-Path $candidate 'scripts\dev.ps1')
    $hasBackend = Test-Path (Join-Path $candidate 'backend\config.json')
    if ($hasScript -and $hasBackend) {
      return $candidate
    }
    $parent = Split-Path $candidate -Parent
    if ($parent -eq $candidate) { break }
    $dir = Get-Item $parent
  }
  throw '无法定位项目根目录：请在 server-monitor 仓库目录内运行，例如 pwsh -File scripts\dev.ps1'
}

$root       = Find-ProjectRoot -ScriptDir $PSScriptRoot
$backend    = Join-Path $root 'backend'
$frontend   = Join-Path $root 'frontend'
$srcTauri   = Join-Path $root 'src-tauri'
$buildScript = Join-Path $root 'scripts\build-backend.ps1'

# 本脚本启动的后端进程 PID（退出时按 PID 精确清理）
$backendPid = $null

function Stop-Spawned {
  if ($backendPid -and (Get-Process -Id $backendPid -ErrorAction SilentlyContinue)) {
    Stop-Process -Id $backendPid -Force -ErrorAction SilentlyContinue
  }
}

function Assert-Config {
  if (-not (Test-Path (Join-Path $backend 'config.json'))) {
    throw "缺少配置文件：$backend\config.json（请参考 README 创建）"
  }
}

function Get-BackendExe {
  Push-Location $backend
  try {
    $exe = & cabal list-bin exe:monitor-backend
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
      throw '找不到编译后的后端 exe，请先运行 cabal build exe:monitor-backend'
    }
    return $exe.Trim()
  } finally {
    Pop-Location
  }
}

function Start-BrowserMode {
  Assert-Config
  $beExe = Get-BackendExe
  $token = 'dev-' + [guid]::NewGuid().ToString('N').Substring(0, 16)
  $log   = Join-Path $env:TEMP 'monitor-backend-dev.log'
  Remove-Item $log, ($log + '.err') -Force -ErrorAction SilentlyContinue

  Write-Host '[*] 启动 Haskell 后端 ...'
  $p = Start-Process -FilePath $beExe -ArgumentList @('--config', 'config.json', '--token', $token) -WorkingDirectory $backend -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') -PassThru
  $backendPid = $p.Id

  # 等待 READY <port> <token>
  $ready = $false
  for ($i = 0; $i -lt 60; $i++) {
    if ($p.HasExited) {
      $err = Get-Content ($log + '.err') -Raw -ErrorAction SilentlyContinue
      throw "后端启动失败（退出码 $($p.ExitCode)）：$err"
    }
    Start-Sleep -Milliseconds 500
    if (Test-Path $log) {
      $line = Get-Content $log -Raw -ErrorAction SilentlyContinue
      if ($line -match 'READY\s+(\d+)\s+(\S+)') {
        $env:VITE_BACKEND_PORT  = $Matches[1]
        $env:VITE_BACKEND_TOKEN = $Matches[2]
        $ready = $true
        break
      }
    }
  }
  if (-not $ready) {
    throw '后端 30 秒内未就绪（未读到 READY 行），请查看日志：' + $log
  }
  Write-Host "[*] 后端就绪: http://127.0.0.1:$env:VITE_BACKEND_PORT"

  Push-Location $frontend
  try {
    Write-Host '[*] 启动 Vite dev server，浏览器访问 http://localhost:5173'
    Start-Process 'http://localhost:5173'
    & npm.cmd run dev
  } finally {
    Pop-Location
  }
}

function Start-DesktopMode {
  Assert-Config
  if (-not $SkipBuild) {
    Write-Host '[*] 编译并暂存 Haskell sidecar ...'
    Push-Location $backend
    try { & cabal build exe:monitor-backend } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'cabal build 失败' }
    & $buildScript
    if ($LASTEXITCODE -ne 0) { throw 'sidecar 暂存失败' }
  }
  Push-Location $srcTauri
  try {
    Write-Host '[*] cargo tauri dev（Ctrl+C 退出，会自行清理 vite 与 sidecar）'
    & npx.cmd tauri dev
  } finally {
    Pop-Location
  }
}

try {
  if ($DryRun) {
    $mode = if ($Browser) { 'browser' } else { 'desktop' }
    Write-Host "[DRY RUN] mode=$mode root=$root"
    Write-Host "[DRY RUN] backend=$backend"
    Write-Host "[DRY RUN] frontend=$frontend"
    Write-Host "[DRY RUN] skipBuild=$SkipBuild"
    exit 0
  }
  if ($Browser) { Start-BrowserMode } else { Start-DesktopMode }
} finally {
  Stop-Spawned
}
