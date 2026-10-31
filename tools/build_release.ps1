# Builds dist\CharlesCoop-<version>.zip: the installer files plus the mod's runtime scripts
# (test-only modules are left out). Usage: powershell -File tools\build_release.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root "mod\CharlesCoop\Scripts"
$ver = ([regex]::Match((Get-Content -Raw (Join-Path $src "main.lua")), 'local VERSION = "([^"]+)"')).Groups[1].Value
if (-not $ver) { throw "VERSION not found in main.lua" }
python -I (Join-Path $root "tools\check_lua.py") (Join-Path $root "mod")
if ($LASTEXITCODE -ne 0) { throw "Lua syntax check failed" }

$dist = Join-Path $root "dist"
$stage = Join-Path $dist "CharlesCoop-$ver"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force (Join-Path $stage "CharlesCoop\Scripts") | Out-Null
Copy-Item (Join-Path $root "installer\*") $stage
foreach ($m in "main", "avatar", "players", "sync", "train", "respawn", "progress", "enemies", "turret", "sched") {
  Copy-Item (Join-Path $src "$m.lua") (Join-Path $stage "CharlesCoop\Scripts")
}
$zip = Join-Path $dist "CharlesCoop-$ver.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip
Write-Output "$zip"
Write-Output ("SHA-256 " + (Get-FileHash $zip -Algorithm SHA256).Hash)
