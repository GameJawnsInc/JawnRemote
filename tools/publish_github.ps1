# Publishes JawnRemote to GitHub:
#   - private repo "JawnRemote"           = full source (backup / version control)
#   - public  repo "jawnremote-downloads" = the installer download link (Releases)
#
# ONE-TIME first:   gh auth login        (choose GitHub.com -> HTTPS -> login with a browser)
# Then run from anywhere:
#   powershell -ExecutionPolicy Bypass -File tools\publish_github.ps1

$ErrorActionPreference = "Stop"
# We check native exit codes ourselves (see GHOk). Stop PowerShell 7.4+ from
# THROWING when a native command exits non-zero -- otherwise `gh repo view` on a
# repo that doesn't exist yet aborts the script instead of returning a code.
$PSNativeCommandUseErrorActionPreference = $false
Set-Location (Split-Path $PSScriptRoot -Parent)   # repo root

$Version       = "v1.0.0"
$SourceRepo    = "JawnRemote"
$DownloadsRepo = "jawnremote-downloads"
$InstallerRel  = "installer\Output\JawnRemote-Server-Setup.exe"

function Fail($m) { Write-Host $m -ForegroundColor Red; exit 1 }
function GHOk { return ($LASTEXITCODE -eq 0) }

# 0. auth + installer
gh auth status 1>$null 2>$null
if (-not (GHOk)) { Fail "Not logged in. Run:  gh auth login   then re-run this script." }
$User = (gh api user --jq .login).Trim()
Write-Host "GitHub user: $User`n"

if (-not (Test-Path $InstallerRel)) {
    Write-Host "Installer not found - building it with Inno Setup..."
    & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" "installer\JawnRemote.iss" | Out-Null
}
$Installer = (Resolve-Path $InstallerRel).Path

# 1. private SOURCE repo
gh repo view "$User/$SourceRepo" 1>$null 2>$null
if (GHOk) {
    Write-Host "Source repo exists; pushing latest commits..."
    if (-not ((git remote) -contains "origin")) {
        git remote add origin "https://github.com/$User/$SourceRepo.git"
    }
    git push -u origin main
} else {
    Write-Host "Creating PRIVATE source repo '$SourceRepo'..."
    gh repo create $SourceRepo --private --source . --remote origin --push
}

# 2. public DOWNLOADS repo (landing page + Releases)
gh repo view "$User/$DownloadsRepo" 1>$null 2>$null
if (-not (GHOk)) {
    Write-Host "Creating PUBLIC downloads repo '$DownloadsRepo'..."
    $dl = Join-Path $env:TEMP "jawnremote-downloads"
    if (Test-Path $dl) { Remove-Item $dl -Recurse -Force }
    New-Item -ItemType Directory $dl | Out-Null
    @"
# JawnRemote - downloads

Turn your phone into a wireless mouse & keyboard for your Windows PC.

**[Download the PC server for Windows](https://github.com/$User/$DownloadsRepo/releases/latest/download/JawnRemote-Server-Setup.exe)**

Install it (double-click, approve the one prompt), then get the JawnRemote app on
your phone and connect over Wi-Fi.
"@ | Set-Content (Join-Path $dl "README.md") -Encoding utf8
    Push-Location $dl
    git init -b main 1>$null
    git add -A
    git commit -m "Downloads landing page" 1>$null
    gh repo create $DownloadsRepo --public --source . --remote origin --push
    Pop-Location
}

# 3. publish the Release with the installer attached
gh release view $Version --repo "$User/$DownloadsRepo" 1>$null 2>$null
if (GHOk) {
    Write-Host "Release $Version exists; updating the installer asset..."
    gh release upload $Version "$Installer#JawnRemote-Server-Setup.exe" --repo "$User/$DownloadsRepo" --clobber
} else {
    Write-Host "Creating release $Version..."
    gh release create $Version "$Installer#JawnRemote-Server-Setup.exe" --repo "$User/$DownloadsRepo" `
        --title "JawnRemote $Version" `
        --notes "JawnRemote PC server installer. Double-click, approve the one UAC prompt, done - no Python needed."
}

Write-Host ""
Write-Host "DONE. Public download link (put this behind your website's Download button):" -ForegroundColor Green
Write-Host "  https://github.com/$User/$DownloadsRepo/releases/latest/download/JawnRemote-Server-Setup.exe"
