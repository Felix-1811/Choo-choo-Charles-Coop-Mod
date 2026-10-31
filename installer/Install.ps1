# CharlesCoop installer: puts RE-UE4SS v3.0.1 and the CharlesCoop mod into Choo-Choo Charles.
# Usage: right-click Install.bat, or: powershell -ExecutionPolicy Bypass -File Install.ps1 [-GameDir "<game dir>"]
# Undo: Uninstall.bat. Nothing outside the game folder is changed.
param([string]$GameDir = "", [switch]$Uninstall)
$ErrorActionPreference = "Stop"
$UE4SS_URL = "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip"
$UE4SS_SHA = "4B47D4BCEDDD2F561A4E395BFA00924CCFC945AF576A2D0C613E6537846C57EC"
$here = $PSScriptRoot

function Find-Game {
  $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
  if (-not $steam) { return $null }
  $libs = @($steam)
  $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
  if (Test-Path $vdf) {
    foreach ($m in [regex]::Matches((Get-Content -Raw $vdf), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value -replace '\\\\', '\' }
  }
  foreach ($l in $libs) {
    $g = Join-Path $l "steamapps\common\Choo-Choo Charles"
    if (Test-Path (Join-Path $g "Obscure\Binaries\Win64\Obscure-Win64-Shipping.exe")) { return $g }
  }
  return $null
}

if (-not $GameDir) { $GameDir = Find-Game }
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir "Obscure\Binaries\Win64\Obscure-Win64-Shipping.exe"))) {
  $GameDir = Read-Host "Choo-Choo Charles folder not found. Paste the game folder (Steam: right-click the game > Manage > Browse local files)"
}
$win64 = Join-Path $GameDir "Obscure\Binaries\Win64"
if (-not (Test-Path (Join-Path $win64 "Obscure-Win64-Shipping.exe"))) { throw "Not a Choo-Choo Charles folder: $GameDir" }
Write-Host "Game folder: $GameDir"

if ($Uninstall) {
  foreach ($f in "dwmapi.dll", "UE4SS.dll") { Remove-Item (Join-Path $win64 $f) -ErrorAction SilentlyContinue }
  Remove-Item -Recurse (Join-Path $win64 "Mods\CharlesCoop") -ErrorAction SilentlyContinue
  Write-Host "Removed UE4SS and CharlesCoop. The game runs unmodded again."
  exit 0
}

if (Get-Process -Name "Obscure-Win64-Shipping" -ErrorAction SilentlyContinue) { throw "Close Choo-Choo Charles first." }

# 1. UE4SS (official release, checked by SHA-256)
if (-not (Test-Path (Join-Path $win64 "UE4SS.dll"))) {
  $tmp = Join-Path $env:TEMP ("charlescoop-" + [guid]::NewGuid())
  New-Item -ItemType Directory $tmp | Out-Null
  $zip = Join-Path $tmp "UE4SS_v3.0.1.zip"
  Write-Host "Downloading UE4SS v3.0.1 from GitHub..."
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing $UE4SS_URL -OutFile $zip
  $sha = (Get-FileHash -Algorithm SHA256 $zip).Hash
  if ($sha -ne $UE4SS_SHA) { throw "UE4SS download has the wrong SHA-256 ($sha). Not installing." }
  Expand-Archive $zip (Join-Path $tmp "x")
  foreach ($f in "dwmapi.dll", "UE4SS.dll", "UE4SS-settings.ini") { Copy-Item (Join-Path $tmp "x\$f") $win64 -Force }
  New-Item -ItemType Directory -Force (Join-Path $win64 "Mods") | Out-Null
  Copy-Item -Recurse -Force (Join-Path $tmp "x\Mods\*") (Join-Path $win64 "Mods")
  Remove-Item -Recurse -Force $tmp
  Write-Host "UE4SS installed."
} else { Write-Host "UE4SS already installed." }

# 2. UE4SS settings: the object-array cache crashed this game; no console windows
$ini = Join-Path $win64 "UE4SS-settings.ini"
$s = Get-Content $ini
$s = $s -replace '^\s*bUseUObjectArrayCache\s*=.*', 'bUseUObjectArrayCache = false'
$s = $s -replace '^\s*ConsoleEnabled\s*=.*', 'ConsoleEnabled = 0'
$s = $s -replace '^\s*GuiConsoleEnabled\s*=.*', 'GuiConsoleEnabled = 0'
$s = $s -replace '^\s*GuiConsoleVisible\s*=.*', 'GuiConsoleVisible = 0'
Set-Content -Encoding ascii $ini $s

# 3. The mod, and a mods.txt with only CharlesCoop on
$dst = Join-Path $win64 "Mods\CharlesCoop"
$keepIni = Join-Path $dst "coop.ini"
$oldIni = if (Test-Path $keepIni) { Get-Content $keepIni } else { $null }
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item -Recurse -Force (Join-Path $here "CharlesCoop\*") $dst
if ($oldIni) { Set-Content -Encoding ascii $keepIni $oldIni } else { Set-Content -Encoding ascii $keepIni "role = off" }
$mods = @("CheatManagerEnablerMod : 0", "ActorDumperMod : 0", "ConsoleCommandsMod : 0", "ConsoleEnablerMod : 0",
  "SplitScreenMod : 0", "LineTraceMod : 0", "BPModLoaderMod : 0", "BPML_GenericFunctions : 0", "jsbLuaProfilerMod : 0",
  "CharlesCoop : 1", "", "; Built-in keybinds, do not move up!", "Keybinds : 0")
Set-Content -Encoding ascii (Join-Path $win64 "Mods\mods.txt") $mods

Set-Content -Encoding ascii (Join-Path $here "gamedir.txt") $GameDir
Write-Host ""
Write-Host "Done. Use Host.bat (you host) or Join.bat (join a friend). Solo.bat plays normally."
