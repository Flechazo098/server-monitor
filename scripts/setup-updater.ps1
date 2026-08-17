param(
  [string]$Password = $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$secretDir = Join-Path $root '.local-secrets'
$privateKey = Join-Path $secretDir 'server-monitor.key'
$passwordFile = Join-Path $secretDir 'server-monitor.password'
$publicKey = Join-Path $root 'src-tauri\updater.pubkey'
$tauriCli = Join-Path $root 'frontend\node_modules\.bin\tauri.cmd'

if (-not (Test-Path -LiteralPath $tauriCli)) { throw 'Tauri CLI missing; run npm ci in frontend first' }
if ((Test-Path -LiteralPath $privateKey) -and -not $Force) {
  throw "Signing key already exists: $privateKey (use -Force only when intentionally rotating it)"
}

if (-not $Password) {
  $secure = Read-Host 'Updater signing-key password' -AsSecureString
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
if (-not $Password) { throw 'Signing-key password cannot be empty' }

New-Item -ItemType Directory -Force -Path $secretDir | Out-Null
$args = @('signer', 'generate', '--ci', '--password', $Password, '--write-keys', $privateKey)
if ($Force) { $args += '--force' }
& $tauriCli @args
if ($LASTEXITCODE -ne 0) { throw "Tauri signer failed with exit code $LASTEXITCODE" }

$generatedPublic = $privateKey + '.pub'
if (-not (Test-Path -LiteralPath $generatedPublic)) { throw 'Tauri signer did not produce a public key' }
Copy-Item -LiteralPath $generatedPublic -Destination $publicKey -Force
[System.IO.File]::WriteAllText($passwordFile, $Password, [System.Text.UTF8Encoding]::new($false))

Write-Host "Public key committed at: $publicKey" -ForegroundColor Green
Write-Host "Private key (gitignored): $privateKey"
Write-Host "Password (gitignored): $passwordFile"
Write-Host 'Configure GitHub secrets TAURI_SIGNING_PRIVATE_KEY and TAURI_SIGNING_PRIVATE_KEY_PASSWORD from those two files.'
