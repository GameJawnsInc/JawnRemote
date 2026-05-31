# deploy-installer.ps1
#
# Uploads the JawnRemote PC-server installer to
# /var/www/jawnston/downloads/jawnremote/ so the landing page's
# "PC server for Windows" button has a file to serve.
#   URL: https://jawnston.com/downloads/jawnremote/JawnRemote-Server-Setup.exe
#
# Builds the installer first if it's missing (needs Inno Setup).
#
# RESUMABLE UPLOAD: the server resets long SSH transfers partway through, so a
# plain `scp` can fail over and over (scp can't resume - each retry restarts
# from zero). This script uses sftp `reput`, which continues from wherever the
# last attempt died, looping until the byte count matches, then verifies the
# whole file by SHA-256 before flipping ownership. (Same approach as
# deploy-app.ps1 - the installer is smaller but hits the same flaky link.)
#
# Usage:
#   .\deploy-installer.ps1
#   .\deploy-installer.ps1 -SshHost mygame

param(
    [string]$SshHost = "mygame"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo      = Split-Path -Parent $scriptDir
$installerWin = Join-Path $repo "installer\Output\JawnRemote-Server-Setup.exe"
$iss       = Join-Path $repo "installer\JawnRemote.iss"
$iscc      = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

if (-not (Test-Path $installerWin)) {
    Write-Host "Installer missing - building with Inno Setup..." -ForegroundColor Yellow
    if (-not (Test-Path $iscc)) { Write-Host "Inno Setup not found at $iscc" -ForegroundColor Red; exit 1 }
    & $iscc $iss | Out-Null
    if (-not (Test-Path $installerWin)) { Write-Host "Build failed" -ForegroundColor Red; exit 1 }
}

$RemoteDir  = "/var/www/jawnston/downloads/jawnremote"
$RemoteName = "JawnRemote-Server-Setup.exe"
$Remote     = "$RemoteDir/$RemoteName"
$PublicUrl  = "https://jawnston.com/downloads/jawnremote/$RemoteName"
$installer  = $installerWin -replace '\\','/'                 # sftp likes forward slashes
$local      = (Get-Item $installerWin).Length
$localHash  = (Get-FileHash $installerWin -Algorithm SHA256).Hash.ToLower()
$sizeMb     = [math]::Round($local / 1MB, 1)

$SshOpts = @("-o","BatchMode=yes","-o","ConnectTimeout=30",
             "-o","ServerAliveInterval=15","-o","ServerAliveCountMax=4")

Write-Host ""
Write-Host "Deploying installer ($sizeMb MB)" -ForegroundColor Cyan
Write-Host "  from:  $installerWin"
Write-Host "  to:    $($SshHost):$Remote"
Write-Host ""

# [1/4] Ensure the folder exists and clear any stale/partial file, so `reput`
# only ever resumes onto a prefix of THIS build.
Write-Host "[1/4] Preparing remote (mkdir + clear stale file)..." -ForegroundColor Yellow
ssh -n @SshOpts $SshHost "mkdir -p '$RemoteDir' && rm -f '$Remote'" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "remote prep failed (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }

# [2/4] Resumable upload - each pass adds whatever bytes it can before a reset.
Write-Host "[2/4] Resumable upload via sftp (survives connection resets)..." -ForegroundColor Yellow
$tmp = Join-Path $env:TEMP "jawn_sftp_installer.txt"
$ok = $false
for ($i = 1; $i -le 25; $i++) {
    $verb = if ($i -eq 1) { "put" } else { "reput" }
    [IO.File]::WriteAllText($tmp, "$verb `"$installer`" `"$Remote`"`n")   # UTF-8, no BOM, LF
    sftp @SshOpts -b $tmp $SshHost | Out-Null
    $rsizeRaw = "$(ssh -n @SshOpts $SshHost "stat -c %s '$Remote' 2>/dev/null")".Trim()
    $rsize = if ($rsizeRaw -match '^\d+$') { [int64]$rsizeRaw } else { 0 }
    $pct = if ($local -gt 0) { [math]::Round(100 * $rsize / $local) } else { 0 }
    Write-Host ("   attempt {0,2}: {1,3}%  ({2} / {3})" -f $i, $pct, $rsize, $local) -ForegroundColor DarkGray
    if ($rsize -eq $local) { $ok = $true; break }
}
Remove-Item $tmp -ErrorAction SilentlyContinue
if (-not $ok) { Write-Host "Upload did not complete after 25 attempts" -ForegroundColor Red; exit 1 }

# [3/4] Verify the bytes match before publishing.
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
