param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
  [string]$Version
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

$tauriPath = Join-Path $root 'src-tauri\tauri.conf.json'
$tauriText = Get-Content -Raw $tauriPath
$tauriText = [regex]::Replace(
  $tauriText,
  '(?m)^(\s*"version"\s*:\s*")[^"]+("\s*,?\s*)$',
  { param($match) $match.Groups[1].Value + $Version + $match.Groups[2].Value },
  1
)
Write-Utf8NoBom $tauriPath $tauriText

$cargoPath = Join-Path $root 'src-tauri\Cargo.toml'
$cargo = Get-Content -Raw $cargoPath
$cargo = [regex]::Replace($cargo, '(?ms)(^\[package\].*?^version\s*=\s*")[^"]+("\s*$)', "`${1}$Version`${2}", 1)
Write-Utf8NoBom $cargoPath $cargo

$baseVersion = $Version.Split('-')[0]
$cabalPath = Join-Path $root 'backend\monitor.cabal'
$cabal = Get-Content -Raw $cabalPath
$cabal = [regex]::Replace($cabal, '(?m)^version:\s*.*$', "version:            $baseVersion.0", 1)
Write-Utf8NoBom $cabalPath $cabal

Push-Location (Join-Path $root 'frontend')
try { & npm.cmd version $Version --no-git-tag-version --allow-same-version }
finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw 'npm version failed' }

& (Join-Path $root 'scripts\build.ps1') version
if ($LASTEXITCODE -ne 0) { throw 'Version verification failed' }
Write-Host "Version set to $Version" -ForegroundColor Green
