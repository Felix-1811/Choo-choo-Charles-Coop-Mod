# Two-instance test on one PC: host + guest over 127.0.0.1, on a COPY of the game only.
# Usage: powershell -File test\run_pair.ps1 -GameCopy "<copy of the game folder>" [-Test coop] [-Seed <save folder copy>]
un_pair.ps1 -GameCopy "<copy of the game folder>" [-Test coop] [-Seed <save folder copy>]
un_pair.ps1 -GameCopy "<copy of the game folder>" [-Test coop] [-Seed <save folder copy>]
#   -Test coop|play|train_drive|...  scripted scenario (see main.lua); -Real: normal play mode
#   -HostOnly: one instance; -Seed: copy these .sav files into each instance's own -userdir
param([int]$TimeoutSec = 600, [string]$Net = "ip", [switch]$HostOnly, [string]$Test = "", [string]$Seed = "", [switch]$Real,
      [string]$GameCopy = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "test-install\Choo-Choo Charles"))
$ErrorActionPreference = "Stop"
$root    = Split-Path -Parent $PSScriptRoot                     # repo root
$win64   = Join-Path $GameCopy "Obscure\Binaries\Win64"
$exe     = Join-Path $win64 "Obscure-Win64-Shipping.exe"
$run     = Join-Path $root ("runs\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$realSaved = Join-Path $env:LOCALAPPDATA "Obscure\Saved"
New-Item -ItemType Directory -Force $run | Out-Null

python -I (Join-Path $root "tools\check_lua.py") (Join-Path $root "mod")
if ($LASTEXITCODE -ne 0) { throw "Lua syntax check failed, not starting the game" }

# Deploy the mod (copy, so the source tree stays the master) and enable it.
$modDst = Join-Path $win64 "Mods\CharlesCoop"
Copy-Item -Recurse -Force (Join-Path $root "mod\CharlesCoop\*") (New-Item -ItemType Directory -Force $modDst)
$modsTxt = Join-Path $win64 "Mods\mods.txt"
$lines = Get-Content $modsTxt | Where-Object { $_ -notmatch "^\s*CharlesCoop\s*:" }
$lines = $lines -replace "^\s*CoopSDKDump\s*:\s*1", "CoopSDKDump : 0"
$i = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match "^\s*Keybinds\s*:" })
$lines = $lines[0..($i-1)] + "CharlesCoop : 1" + $lines[$i..($lines.Count-1)]
Set-Content -Encoding ascii $modsTxt $lines

# Fingerprint the real save folder so we can prove the run left it alone.
function Fingerprint($dir) { if (Test-Path $dir) { Get-ChildItem $dir -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object } }
$before = Fingerprint $realSaved

$procs = @()
function Start-Role($role, $x) {
  $env:COOP_ROLE = $role; if (-not $Real) { $env:COOP_SYNC_DIR = ($run -replace '\\','/') }; $env:COOP_NET = $Net; $env:COOP_TEST = $Test
  $ud = Join-Path $run "userdir-$role"
  New-Item -ItemType Directory -Force $ud | Out-Null
  # optional story progress: a copy of a save snapshot (never the real save folder)
  if ($Seed) { $sg = New-Item -ItemType Directory -Force (Join-Path $ud "Saved\SaveGames"); Copy-Item (Join-Path $Seed "*.sav") $sg }
  $a = @("-windowed", "-ResX=960", "-ResY=540", "-WinX=$x", "-WinY=40", "-nosplash", "-userdir=`"$ud`"")
  $p = Start-Process -FilePath $exe -ArgumentList $a -WorkingDirectory $win64 -PassThru
  Write-Host "started $role pid=$($p.Id)"
  return $p
}
if ($Real) { Remove-Item (Join-Path $win64 "Mods/CharlesCoop/probe_*.log") -ErrorAction SilentlyContinue }
$procs += Start-Role "host" 0
if (-not $HostOnly) { Start-Sleep -Seconds 5; $procs += Start-Role "guest" 970 }
Remove-Item Env:COOP_ROLE, Env:COOP_SYNC_DIR, Env:COOP_NET, Env:COOP_TEST -ErrorAction SilentlyContinue

$deadline = (Get-Date).AddSeconds($TimeoutSec)
# -Real: normal play mode (no hand-off files); runs for the whole timeout, logs in Mods\CharlesCoop
$modLogs = Join-Path $win64 "Mods\CharlesCoop"
$want = if ($HostOnly) { "host_done","host_failed" } else { "guest_done" }
# No desktop screenshots and no synthetic keys: someone may be using the PC while tests
# run. The game takes its own screenshots (HighResShot, scene only) and the in-game bot
# replaces the W key.
$tick = 0
while ((Get-Date) -lt $deadline) {
  $tick++
  if ($tick % 10 -eq 0) {
    $st = $procs | ForEach-Object { $_.Refresh(); "pid $($_.Id) responding=$($_.Responding) exited=$($_.HasExited)" }
    Add-Content (Join-Path $run "procs.log") ("{0:HH:mm:ss} {1}" -f (Get-Date), ($st -join "; "))
  }
  if ($want | Where-Object { Test-Path (Join-Path $run $_) }) { Start-Sleep -Seconds 8; break }
  if (-not ($procs | Where-Object { -not $_.HasExited })) { Write-Output "all game processes exited early"; break }
  Start-Sleep -Seconds 3
}
foreach ($p in $procs) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } else { Write-Output "pid $($p.Id) exit code $($p.ExitCode)" } }
Start-Sleep -Seconds 2

$after = Fingerprint $realSaved
$diff = Compare-Object @($before) @($after)
if ($diff) { Write-Output "WARNING: real save folder changed during the run:"; $diff | Format-Table -AutoSize | Out-String -Width 300 }
else { Write-Output "real save folder unchanged" }
Copy-Item (Join-Path $win64 "UE4SS.log") (Join-Path $run "UE4SS.log") -ErrorAction SilentlyContinue
Write-Output "RUN DIR: $run"
if ($Real) { Copy-Item (Join-Path $modLogs "probe_*.log") $run -ErrorAction SilentlyContinue }
Get-ChildItem $run -Filter "probe_*.log" | ForEach-Object { "===== $($_.Name)"; Get-Content $_.FullName }
