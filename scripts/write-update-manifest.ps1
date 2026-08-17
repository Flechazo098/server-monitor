param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$Repository,
  [string]$BundleDir = 'src-tauri\target\release\bundle\nsis',
  [string]$Output = 'release\latest.json'
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$bundlePath = [System.IO.Path]::GetFullPath((Join-Path $root $BundleDir))
$packages = @(Get-ChildItem -LiteralPath $bundlePath -Filter '*-setup.exe' -File)
if ($packages.Count -ne 1) {
  throw "Expected exactly one updater package in $bundlePath, found $($packages.Count)"
}
$package = $packages[0]
$signaturePath = $package.FullName + '.sig'
if (-not (Test-Path -LiteralPath $signaturePath)) { throw "Missing updater signature: $signaturePath" }
$signature = (Get-Content -Raw -LiteralPath $signaturePath).Trim()
$url = "https://github.com/$Repository/releases/download/v$Version/$($package.Name)"
$manifest = [ordered]@{
  version = $Version
  notes = "Server Monitor $Version"
  pub_date = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  platforms = [ordered]@{
    'windows-x86_64' = [ordered]@{ signature = $signature; url = $url }
  }
}
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $root $Output))
New-Item -ItemType Directory -Force -Path (Split-Path $outputPath -Parent) | Out-Null
[System.IO.File]::WriteAllText($outputPath, (($manifest | ConvertTo-Json -Depth 8) + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host $outputPath
