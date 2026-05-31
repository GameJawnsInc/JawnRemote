# deploy-installer.ps1
#
# Uploads the JawnRemote PC-server installer to
# /var/www/jawnston/downloads/jawnremote/ so the landing page's
# "PC server for Windows" button has a file to serve.
#   URL: https://jawnston.com/downloads/jawnremote/JawnRemote-Server-Setup.exe
#
# Builds the installer first if it's missing (needs Inno Setup).
#
# Usage:
#   .\deploy-installer.ps1
#   .\deploy-installer.ps1 -SshHost mygame

param(
    [string]$SshHost = "mygame"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo      = Split-Path -Parent $scriptDir
$installer = Join-Path $repo "installer\Output\JawnRemote-Server-Setup.exe"
$iss       = Join-Path $repo "installer\JawnRemote.iss"
$iscc      = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

if (-not (Test-Path $installer)) {
    Write-Host "Installer missing - building with Inno Setup..." -ForegroundColor Yellow
    if (-not (Test-Path $iscc)) { Write-Host "Inno Setup not found at $iscc" -ForegroundColor Red; exit 1 }
    & $iscc $iss | Out-Null
    if (-not (Test-Path $installer)) { Write-Host "Build failed" -ForegroundColor Red; exit 1 }
}

$RemoteDir = "/var/www/jawnston/downloads/jawnremote"
$PublicUrl = "https://jawnston.com/downloads/jawnremote/JawnRemote-Server-Setup.exe"
$localSize = (Get-Item $installer).Length
$sizeMb    = [math]::Round($localSize / 1MB, 1)

# Resilient ssh/scp opts (residential-connection friendly).
$SshOpts = @("-o","ServerAliveInterval=15","-o","ServerAliveCountMax=8","-o","TCPKeepAlive=yes","-o","ConnectTimeout=30")

Write-Host ""
Write-Host "Deploying installer ($sizeMb MB)" -ForegroundColor Cyan
Write-Host "  from:  $installer"
Write-Host "  to:    $($SshHost):$RemoteDir"
Write-Host ""

$startTime = Get-Date

# --- [1/3] Ensure the remote folder exists ----------------------------
Write-Host "[1/3] Ensuring remote folder..." -ForegroundColor Yellow
ssh -n -o BatchMode=yes @SshOpts $SshHost "mkdir -p '$RemoteDir'"
if ($LASTEXITCODE -ne 0) { throw "mkdir failed (exit $LASTEXITCODE)" }

# --- [2/3] Upload with retries + size verification --------------------
Write-Host "[2/3] Uploading via scp..." -ForegroundColor Yellow
$ok = $false
foreach ($delay in 0, 5, 15) {
    if ($delay -gt 0) {
        Write-Host "   retry in ${delay}s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds $delay
    }
    scp -O @SshOpts $installer "${SshHost}:$RemoteDir/"
    if ($LASTEXITCODE -ne 0) { continue }
    $remoteSize = ssh -n -o BatchMode=yes @SshOpts $SshHost "stat -c '%s' '$RemoteDir/JawnRemote-Server-Setup.exe' 2>/dev/null"
    if ("$remoteSize".Trim() -eq "$localSize") { $ok = $true; break }
    Write-Host "   size mismatch (remote '$remoteSize' vs $localSize), retrying..." -ForegroundColor DarkYellow
}
if (-not $ok) { Write-Host "Upload failed after retries" -ForegroundColor Red; exit 1 }

# --- [3/3] Fix ownership ----------------------------------------------
Write-Host "[3/3] Fixing ownership via ssh..." -ForegroundColor Yellow
ssh -n -o BatchMode=yes @SshOpts $SshHost "chown -R caddy:caddy '$RemoteDir'"
if ($LASTEXITCODE -ne 0) { throw "chown failed (exit $LASTEXITCODE)" }

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
Write-Host ""
Write-Host "Deployed in ${elapsed}s" -ForegroundColor Green
Write-Host "Live at: $PublicUrl" -ForegroundColor Green
Write-Host ""

Set-Clipboard -Value $PublicUrl
Write-Host "Download URL copied to clipboard." -ForegroundColor DarkGray
