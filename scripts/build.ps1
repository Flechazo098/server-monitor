param(
  [ValidateSet('test', 'check', 'build', 'bundle', 'all', 'clean', 'contract', 'version')]
  [string]$Task = 'check',
  [switch]$Dependencies
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$backend = Join-Path $root 'backend'
$frontend = Join-Path $root 'frontend'
$tauri = Join-Path $root 'src-tauri'
$contractFile = Join-Path $frontend '.contract\haskell.json'
$tauriCli = Join-Path $frontend 'node_modules\.bin\tauri.cmd'
$localPrivateKey = Join-Path $root '.local-secrets\server-monitor.key'
$localPassword = Join-Path $root '.local-secrets\server-monitor.password'
$updaterPublicKey = Join-Path $tauri 'updater.pubkey'

function Invoke-Checked {
  param([string]$Name, [scriptblock]$Action)
  Write-Host "`n==> $Name" -ForegroundColor Cyan
  & $Action
  if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}

function Assert-Tool {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required tool is not available: $Name"
  }
}

function Get-Versions {
  $tauriConfig = Get-Content -Raw (Join-Path $tauri 'tauri.conf.json') | ConvertFrom-Json
  $frontendPackage = Get-Content -Raw (Join-Path $frontend 'package.json') | ConvertFrom-Json
  $cargoText = Get-Content -Raw (Join-Path $tauri 'Cargo.toml')
  $cabalText = Get-Content -Raw (Join-Path $backend 'monitor.cabal')
  $cargoMatch = [regex]::Match($cargoText, '(?ms)^\[package\].*?^version\s*=\s*"([^"]+)"')
  $cabalMatch = [regex]::Match($cabalText, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\.[0-9]+)?\s*$')
  if (-not $cargoMatch.Success -or -not $cabalMatch.Success) { throw 'Unable to read Cargo/Cabal version' }
  [ordered]@{
    tauri = [string]$tauriConfig.version
    cargo = $cargoMatch.Groups[1].Value
    frontend = [string]$frontendPackage.version
    haskell = $cabalMatch.Groups[1].Value
  }
}

function Assert-Version {
  $versions = Get-Versions
  $expected = $versions.tauri
  $baseVersion = $expected.Split('-')[0]
  $releaseMismatch = $versions.cargo -ne $expected -or $versions.frontend -ne $expected
  $haskellMismatch = $versions.haskell -ne $baseVersion
  if ($releaseMismatch -or $haskellMismatch) {
    $detail = ($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
    throw "Version mismatch: $detail"
  }
  $tauriConfig = Get-Content -Raw (Join-Path $tauri 'tauri.conf.json') | ConvertFrom-Json
  if (Test-Path -LiteralPath $updaterPublicKey) {
    $expectedPubkey = (Get-Content -Raw -LiteralPath $updaterPublicKey).Trim()
    $configuredPubkey = [string]$tauriConfig.plugins.updater.pubkey
    if ($configuredPubkey -ne $expectedPubkey) {
      throw 'Updater public key differs between tauri.conf.json and src-tauri/updater.pubkey'
    }
  }
  return $expected
}

function Assert-BuildTools {
  Assert-Tool cabal
  Assert-Tool cargo
  Assert-Tool npm.cmd
  Assert-Tool rustc
}

function Export-Contract {
  Invoke-Checked 'Build Haskell contract exporter' {
    Push-Location $backend
    try { & cabal build exe:monitor-contract } finally { Pop-Location }
  }
  Push-Location $backend
  try {
    $contractExe = (& cabal list-bin exe:monitor-contract | Where-Object { $_ -match '\.exe$' } | Select-Object -Last 1).Trim()
  } finally { Pop-Location }
  if (-not (Test-Path -LiteralPath $contractExe)) { throw 'monitor-contract executable was not produced' }
  New-Item -ItemType Directory -Force -Path (Split-Path $contractFile -Parent) | Out-Null
  Invoke-Checked 'Export Haskell JSON contract' { & $contractExe $contractFile }
}

function Stage-Backend {
  Invoke-Checked 'Build Haskell sidecar' {
    Push-Location $backend
    try { & cabal build exe:monitor-backend } finally { Pop-Location }
  }
  Push-Location $backend
  try {
    $backendExe = (& cabal list-bin exe:monitor-backend | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Unable to locate backend executable (exit code $LASTEXITCODE)" }
  } finally { Pop-Location }
  if (-not (Test-Path -LiteralPath $backendExe)) { throw "Backend executable does not exist: $backendExe" }

  $triple = (& rustc --print host-tuple).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $triple) { throw 'Unable to resolve the Rust host tuple' }
  $binDir = Join-Path $tauri 'binaries'
  $target = Join-Path $binDir "monitor-backend-$triple.exe"
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  Copy-Item -LiteralPath $backendExe -Destination $target -Force
  Write-Host "Staged sidecar: $target"
}

function Invoke-Tests {
  Assert-Version | Out-Null
  Export-Contract
  Invoke-Checked 'Haskell tests' { Push-Location $backend; try { & cabal test all --test-show-details=direct } finally { Pop-Location } }
  Invoke-Checked 'Frontend unit and contract tests' { Push-Location $frontend; try { & npm.cmd test } finally { Pop-Location } }
}

function Invoke-Checks {
  Assert-Version | Out-Null
  Export-Contract
  Invoke-Checked 'Haskell tests' { Push-Location $backend; try { & cabal test all --test-show-details=direct } finally { Pop-Location } }
  Invoke-Checked 'Haskell lint' { Push-Location $backend; try { & hlint src app test } finally { Pop-Location } }
  Invoke-Checked 'Frontend type and contract tests' { Push-Location $frontend; try { & npm.cmd test } finally { Pop-Location } }
  Invoke-Checked 'Frontend production build' { Push-Location $frontend; try { & npm.cmd run build } finally { Pop-Location } }
  Stage-Backend
  Invoke-Checked 'Rust format' { Push-Location $tauri; try { & cargo fmt --check } finally { Pop-Location } }
  Invoke-Checked 'Rust check' { Push-Location $tauri; try { & cargo check } finally { Pop-Location } }
}

function Invoke-Build {
  Assert-Version | Out-Null
  Export-Contract
  Stage-Backend
  Invoke-Checked 'Frontend production build' { Push-Location $frontend; try { & npm.cmd run build } finally { Pop-Location } }
  Invoke-Checked 'Tauri debug build' { Push-Location $tauri; try { & cargo build } finally { Pop-Location } }
}

function Invoke-Bundle {
  Assert-Version | Out-Null
  Export-Contract
  Stage-Backend
  if (-not (Test-Path -LiteralPath $tauriCli)) { throw 'Tauri CLI is missing; run npm ci in frontend' }
  $hasSigningKey = -not [string]::IsNullOrWhiteSpace($env:TAURI_SIGNING_PRIVATE_KEY)
  $hasSigningPassword = -not [string]::IsNullOrWhiteSpace($env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD)
  if (-not $hasSigningKey -and (Test-Path -LiteralPath $localPrivateKey)) {
    $env:TAURI_SIGNING_PRIVATE_KEY = Get-Content -Raw -LiteralPath $localPrivateKey
    $hasSigningKey = $true
  }
  if (-not $hasSigningPassword -and (Test-Path -LiteralPath $localPassword)) {
    $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = (Get-Content -Raw -LiteralPath $localPassword).TrimEnd("`r", "`n")
    $hasSigningPassword = $true
  }
  if ($hasSigningKey -xor $hasSigningPassword) {
    throw 'Updater signing key and password must either both be configured or both be absent'
  }

  $bundleLabel = 'Unsigned local Tauri NSIS bundle'
  $configOverride = $null
  if ($hasSigningKey) {
    if (-not (Test-Path -LiteralPath $updaterPublicKey)) { throw 'Updater public key is missing' }
    if (-not [string]::IsNullOrWhiteSpace($env:TAURI_CONFIG)) {
      $configOverride = $env:TAURI_CONFIG
    } else {
      $pubkey = (Get-Content -Raw -LiteralPath $updaterPublicKey).Trim()
      $configOverride = [ordered]@{
        bundle = @{ createUpdaterArtifacts = $true }
        plugins = @{ updater = @{
          pubkey = $pubkey
          endpoints = @('https://github.com/Flechazo098/server-monitor/releases/latest/download/latest.json')
          windows = @{ installMode = 'passive' }
        } }
      } | ConvertTo-Json -Compress -Depth 8
    }
    $bundleLabel = 'Signed Tauri NSIS bundle and updater artifact'
  } else {
    Write-Host 'No updater signing key configured; producing a local installer without updater artifacts.' -ForegroundColor Yellow
  }

  $configOverridePath = $null
  try {
    if ($configOverride) {
      $configOverridePath = Join-Path ([System.IO.Path]::GetTempPath()) "server-monitor-tauri-$PID-$([guid]::NewGuid().ToString('N')).json"
      [System.IO.File]::WriteAllText($configOverridePath, $configOverride, [System.Text.UTF8Encoding]::new($false))
    }
    Invoke-Checked $bundleLabel {
      Push-Location $tauri
      try {
        if ($configOverridePath) {
          & $tauriCli build --bundles nsis --config $configOverridePath
        } else {
          & $tauriCli build --bundles nsis
        }
      } finally { Pop-Location }
    }
  } finally {
    if ($configOverridePath -and (Test-Path -LiteralPath $configOverridePath)) {
      Remove-Item -LiteralPath $configOverridePath -Force
    }
  }
}

function Remove-ApprovedDirectory {
  param([string]$Path)
  $resolved = [System.IO.Path]::GetFullPath($Path)
  $allowed = @(
    [System.IO.Path]::GetFullPath((Join-Path $backend 'dist-newstyle')),
    [System.IO.Path]::GetFullPath((Join-Path $frontend 'dist')),
    [System.IO.Path]::GetFullPath((Join-Path $frontend '.contract')),
    [System.IO.Path]::GetFullPath((Join-Path $tauri 'target')),
    [System.IO.Path]::GetFullPath((Join-Path $frontend 'node_modules'))
  )
  if ($resolved -notin $allowed -or -not $resolved.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar)) {
    throw "Refusing to remove unapproved path: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) {
    Write-Host "Removing $resolved"
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}

function Invoke-Clean {
  Remove-ApprovedDirectory (Join-Path $backend 'dist-newstyle')
  Remove-ApprovedDirectory (Join-Path $frontend 'dist')
  Remove-ApprovedDirectory (Join-Path $frontend '.contract')
  Remove-ApprovedDirectory (Join-Path $tauri 'target')
  Get-ChildItem -LiteralPath (Join-Path $tauri 'binaries') -Filter 'monitor-backend-*.exe*' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force
  if ($Dependencies) { Remove-ApprovedDirectory (Join-Path $frontend 'node_modules') }
  Write-Host 'Clean complete.' -ForegroundColor Green
}

switch ($Task) {
  'test' { Assert-BuildTools; Invoke-Tests }
  'check' { Assert-BuildTools; Invoke-Checks }
  'build' { Assert-BuildTools; Invoke-Build }
  'bundle' { Assert-BuildTools; Invoke-Bundle }
  'all' { Assert-BuildTools; Invoke-Checks; Invoke-Bundle }
  'clean' { Invoke-Clean }
  'contract' { Assert-BuildTools; Export-Contract; Invoke-Checked 'Contract tests' { Push-Location $frontend; try { & npm.cmd run contract:test } finally { Pop-Location } } }
  'version' { Assert-Version | Out-Host }
}
