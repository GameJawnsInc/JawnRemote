# deploy-app.ps1
#
# Builds the release-signed Android APK and uploads it to
# /var/www/jawnston/downloads/jawnremote/JawnRemote.apk so the landing page's
# "Download for Android" button has a file to serve.
#   URL: https://jawnston.com/downloads/jawnremote/JawnRemote.apk
#
# RESUMABLE UPLOAD: the server resets long SSH transfers partway through, so a
# plain `scp` of the ~56 MB APK fails over and over (scp can't resume - every
# retry restarts from zero and dies again). This script uses sftp `reput`, which
# continues from wherever the last attempt died, looping until the byte count
# matches, then verifies the whole file by SHA-256 before flipping ownership.
#
# Note: this APK is signed with your UPLOAD key. Sideloaded installs and a later
# Play Store install have different signatures, so users can't update across the
# two - fine while you're distributing directly; revisit when you go live on Play.
#
# Usage:
#   .\deploy-app.ps1
#   .\deploy-app.ps1 -SshHost mygame

param(
    [string]$SshHost = "mygame"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo      = Split-Path -Parent $scriptDir
$flutter   = "C:\src\flutter\bin\flutter.bat"
$apkWin    = Join-Path $repo "app\build\app\outputs\flutter-apk\app-release.apk"

if (-not (Test-Path $apkWin)) {
    Write-Host "Release APK missing - building it..." -ForegroundColor Yellow
    Push-Location (Join-Path $repo "app")
    & $flutter build apk --release | Out-Null
    Pop-Location
    if (-not (Test-Path $apkWin)) { Write-Host "Build failed" -ForegroundColor Red; exit 1 }
}

$RemoteDir  = "/var/www/jawnston/downloads/jawnremote"
$RemoteName = "JawnRemote.apk"
$Remote     = "$RemoteDir/$RemoteName"
$PublicUrl  = "https://jawnston.com/downloads/jawnremote/$RemoteName"
$apk        = $apkWin -replace '\\','/'                       # sftp likes forward slashes
$local      = (Get-Item $apkWin).Length
$localHash  = (Get-FileHash $apkWin -Algorithm SHA256).Hash.ToLower()
$sizeMb     = [math]::Round($local / 1MB, 1)

$SshOpts = @("-o","BatchMode=yes","-o","ConnectTimeout=30",
             "-o","ServerAliveInterval=15","-o","ServerAliveCountMax=4")

Write-Host ""
Write-Host "Deploying Android app ($sizeMb MB)" -ForegroundColor Cyan
Write-Host "  from:  $apkWin"
Write-Host "  to:    $($SshHost):$Remote"
Write-Host ""

# [1/4] Ensure the folder exists and clear any stale/partial file. We must start
# from a clean slate so `reput` only ever resumes onto a prefix of THIS build
# (resuming onto an older file would silently corrupt the result).
Write-Host "[1/4] Preparing remote (mkdir + clear stale file)..." -ForegroundColor Yellow
ssh -n @SshOpts $SshHost "mkdir -p '$RemoteDir' && rm -f '$Remote'" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "remote prep failed (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }

# [2/4] Resumable upload. Each pass adds whatever bytes it can before the server
# resets the connection; the loop keeps going until the remote size matches.
Write-Host "[2/4] Resumable upload via sftp (survives connection resets)..." -ForegroundColor Yellow
$tmp = Join-Path $env:TEMP "jawn_sftp_app.txt"
$ok = $false
for ($i = 1; $i -le 25; $i++) {
    $verb = if ($i -eq 1) { "put" } else { "reput" }
    [IO.File]::WriteAllText($tmp, "$verb `"$apk`" `"$Remote`"`n")   # UTF-8, no BOM, LF
    sftp @SshOpts -b $tmp $SshHost | Out-Null
    $rsizeRaw = "$(ssh -n @SshOpts $SshHost "stat -c %s '$Remote' 2>/dev/null")".Trim()
    $rsize = if ($rsizeRaw -match '^\d+$') { [int64]$rsizeRaw } else { 0 }
    $pct = if ($local -gt 0) { [math]::Round(100 * $rsize / $local) } else { 0 }
    Write-Host ("   attempt {0,2}: {1,3}%  ({2} / {3})" -f $i, $pct, $rsize, $local) -ForegroundColor DarkGray
    if ($rsize -eq $local) { $ok = $true; break }
}
Remove-Item $tmp -ErrorAction SilentlyContinue
if (-not $ok) { Write-Host "Upload did not complete after 25 attempts" -ForegroundColor Red; exit 1 }

# [3/4] Verify the bytes actually match (resume + append is only safe if the
# final hash is identical to the local file).
Write-Host "[3/4] Verifying SHA-256..." -ForegroundColor Yellow
$rhash = "$(ssh -n @SshOpts $SshHost "sha256sum '$Remote' | cut -d' ' -f1")".Trim().ToLower()
if ($rhash -ne $localHash) {
    Write-Host "HASH MISMATCH - remote file is corrupt, not publishing" -ForegroundColor Red
    Write-Host "  local : $localHash"
    Write-Host "  remote: $rhash"
    exit 1
}

# [4/4] Hand the file to Caddy.
Write-Host "[4/4] Fixing ownership (caddy:caddy)..." -ForegroundColor Yellow
ssh -n @SshOpts $SshHost "chown caddy:caddy '$Remote'" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "chown failed (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "Live at: $PublicUrl" -ForegroundColor Green
Write-Host "SHA-256: $localHash" -ForegroundColor DarkGray
Set-Clipboard -Value $PublicUrl
Write-Host "Download URL copied to clipboard." -ForegroundColor DarkGray
