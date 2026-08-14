# Build the Haskell backend and stage it as a Tauri sidecar binary.
# Usage: pwsh scripts/build-backend.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$backend = Join-Path $root 'backend'
$binDir = Join-Path $root 'src-tauri\binaries'

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

Push-Location $backend
try {
    cabal build exe:monitor-backend
    $exe = cabal list-bin exe:monitor-backend
} finally {
    Pop-Location
}

$triple = & rustc --print host-tuple
$target = Join-Path $binDir "monitor-backend-$triple.exe"
Copy-Item $exe $target -Force
Write-Host "Staged sidecar: $target"
