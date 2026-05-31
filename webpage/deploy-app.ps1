# deploy-app.ps1
#
# Builds the release-signed Android APK and uploads it to
# /var/www/jawnston/downloads/jawnremote/JawnRemote.apk so the landing page's
# "Download for Android" button has a file to serve.
#   URL: https://jawnston.com/downloads/jawnremote/JawnRemote.apk
#
# Note: this APK is signed with your UPLOAD key. Sideloaded installs and a later
# Play Store install have different signatures, so users can't update across the
# two — fine while you're distributing directly; revisit when you go live on Play.
#
# Usage:
#   .\deploy-app.ps1
#   .\deploy-app.ps1 -SshHost mygame

param(
    [string]$SshHost = "mygame"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo      = Split-Path -Parent $scriptDir
$flutter   = "C:\src\flutter\bin\flutter.bat"
$apk       = Join-Path $repo "app\build\app\outputs\flutter-apk\app-release.apk"

if (-not (Test-Path $apk)) {
    Write-Host "Release APK missing - building it..." -ForegroundColor Yellow
    Push-Location (Join-Path $repo "app")
    & $flutter build apk --release | Out-Null
    Pop-Location
    if (-not (Test-Path $apk)) { Write-Host "Build failed" -ForegroundColor Red; exit 1 }
}

$RemoteDir  = "/var/www/jawnston/downloads/jawnremote"
$RemoteName = "JawnRemote.apk"
$PublicUrl  = "https://jawnston.com/downloads/jawnremote/JawnRemote.apk"
$localSize  = (Get-Item $apk).Length
$sizeMb     = [math]::Round($localSize / 1MB, 1)

$SshOpts = @("-o","ServerAliveInterval=15","-o","ServerAliveCountMax=8","-o","TCPKeepAlive=yes","-o","ConnectTimeout=30")

Write-Host ""
Write-Host "Deploying Android app ($sizeMb MB)" -ForegroundColor Cyan
Write-Host "  from:  $apk"
Write-Host "  to:    $($SshHost):$RemoteDir/$RemoteName"
Write-Host ""

Write-Host "[1/3] Ensuring remote folder..." -ForegroundColor Yellow
ssh -n -o BatchMode=yes @SshOpts $SshHost "mkdir -p '$RemoteDir'"
if ($LASTEXITCODE -ne 0) { throw "mkdir failed (exit $LASTEXITCODE)" }

Write-Host "[2/3] Uploading via scp..." -ForegroundColor Yellow
$ok = $false
foreach ($delay in 0, 5, 15) {
    if ($delay -gt 0) {
        Write-Host "   retry in ${delay}s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds $delay
    }
    scp -O @SshOpts $apk "${SshHost}:$RemoteDir/$RemoteName"
    if ($LASTEXITCODE -ne 0) { continue }
    $remoteSize = ssh -n -o BatchMode=yes @SshOpts $SshHost "stat -c '%s' '$RemoteDir/$RemoteName' 2>/dev/null"
    if ("$remoteSize".Trim() -eq "$localSize") { $ok = $true; break }
    Write-Host "   size mismatch, retrying..." -ForegroundColor DarkYellow
}
if (-not $ok) { Write-Host "Upload failed after retries" -ForegroundColor Red; exit 1 }

Write-Host "[3/3] Fixing ownership via ssh..." -ForegroundColor Yellow
ssh -n -o BatchMode=yes @SshOpts $SshHost "chown -R caddy:caddy '$RemoteDir'"
if ($LASTEXITCODE -ne 0) { throw "chown failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "Live at: $PublicUrl" -ForegroundColor Green
Set-Clipboard -Value $PublicUrl
Write-Host "Download URL copied to clipboard." -ForegroundColor DarkGray
