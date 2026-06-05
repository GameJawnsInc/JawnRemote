# deploy-site.ps1
#
# Uploads the JawnRemote landing page to jawnston.com/jawnremote/.
# Mirrors browser_app/webpage/deploy-site.ps1 (the family convention).
#
# The page lives at /var/www/jawnston/jawnremote/index.html, served by Caddy's
# catch-all `handle { file_server }` rule — no Caddyfile change needed.
#   URL: https://jawnston.com/jawnremote/
#
# Usage:
#   .\deploy-site.ps1
#   .\deploy-site.ps1 -SshHost mygame   (override SSH host alias)

param(
    [string]$SshHost = "mygame"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$indexFile = Join-Path $scriptDir "index.html"

if (-not (Test-Path $indexFile)) {
    Write-Host "Missing $indexFile" -ForegroundColor Red
    exit 1
}

$RemoteDir  = "/var/www/jawnston/jawnremote"
$RemoteFile = "$RemoteDir/index.html"
$PublicUrl  = "https://jawnston.com/jawnremote/"

Write-Host ""
Write-Host "Deploying JawnRemote landing page" -ForegroundColor Cyan
Write-Host "  from:  $indexFile"
Write-Host "  to:    $($SshHost):$RemoteFile"
Write-Host ""

$startTime = Get-Date

# --- [1/3] Ensure the remote dir exists -------------------------------
Write-Host "[1/3] Ensuring $RemoteDir exists..." -ForegroundColor Yellow
ssh -n -o BatchMode=yes $SshHost "mkdir -p '$RemoteDir'"
if ($LASTEXITCODE -ne 0) { throw "mkdir failed (exit $LASTEXITCODE)" }

# --- [2/3] Upload index.html ------------------------------------------
# -O forces legacy SCP protocol (OpenSSH 9+ SFTP-over-scp is flaky on tiny files).
Write-Host "[2/3] Uploading index.html..." -ForegroundColor Yellow
scp -O $indexFile "${SshHost}:$RemoteFile"
if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }
# Privacy policy (required by Google Play; the app is ad-free).
$privacyFile = Join-Path $scriptDir "privacy.html"
if (Test-Path $privacyFile) {
    Write-Host "      uploading privacy.html..." -ForegroundColor Yellow
    scp -O $privacyFile "${SshHost}:$RemoteDir/privacy.html"
    if ($LASTEXITCODE -ne 0) { throw "scp privacy.html failed (exit $LASTEXITCODE)" }
}

# --- [2b/3] Upload og-image.png if present (optional share-preview banner) ---
# The OG <meta> tags point at jawnremote/og-image.png; the 1200x630 banner is
# optional. The chown -R on $RemoteDir below already covers it.
$ogImageFile = Join-Path $scriptDir "og-image.png"
if (Test-Path $ogImageFile) {
    Write-Host "      uploading og-image.png..." -ForegroundColor Yellow
    scp -O $ogImageFile "${SshHost}:$RemoteDir/og-image.png"
    if ($LASTEXITCODE -ne 0) { throw "scp og-image.png failed (exit $LASTEXITCODE)" }
}

# --- [2c/3] Upload favicons if present --------------------------------
foreach ($fav in @("favicon.ico", "favicon-16x16.png", "favicon-32x32.png", "apple-touch-icon.png", "demo_2x.gif")) {
    $favFile = Join-Path $scriptDir $fav
    if (Test-Path $favFile) {
        Write-Host "      uploading $fav..." -ForegroundColor Yellow
        scp -O $favFile "${SshHost}:$RemoteDir/$fav"
        if ($LASTEXITCODE -ne 0) { throw "scp $fav failed (exit $LASTEXITCODE)" }
    }
}

# --- [3/3] Fix ownership so Caddy can read it -------------------------
Write-Host "[3/3] Fixing ownership via ssh..." -ForegroundColor Yellow
ssh -n -o BatchMode=yes $SshHost "chown -R caddy:caddy '$RemoteDir'"
if ($LASTEXITCODE -ne 0) { throw "chown failed (exit $LASTEXITCODE)" }

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
Write-Host ""
Write-Host "Deployed in ${elapsed}s" -ForegroundColor Green
Write-Host "Live at: $PublicUrl" -ForegroundColor Green
Write-Host ""

Set-Clipboard -Value $PublicUrl
Write-Host "Page URL copied to clipboard." -ForegroundColor DarkGray
