# CharlesCoop launcher: sets the mod's role, then starts the game through Steam.
#   host : open your own saved game for friends (UDP port 7777)
#   join : join a friend's game by address; your own save is backed up first
#   solo : normal single player (the mod does nothing)
param([ValidateSet("host", "join", "solo")][string]$Mode = "solo", [string]$Address = "", [switch]$NoLaunch)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$gdFile = Join-Path $here "gamedir.txt"
if (-not (Test-Path $gdFile)) { throw "Run Install.bat first." }
$cfg = Join-Path (Get-Content $gdFile -TotalCount 1) "Obscure\Binaries\Win64\Mods\CharlesCoop\coop.ini"
if (-not (Test-Path (Split-Path $cfg))) { throw "CharlesCoop is not installed. Run Install.bat first." }
if (Get-Process -Name "Obscure-Win64-Shipping" -ErrorAction SilentlyContinue) { throw "The game is already running. Close it first." }

switch ($Mode) {
  "host" {
    Set-Content -Encoding ascii $cfg "role = host"
    Write-Host "Hosting. The game opens your save by itself a few seconds after the main menu shows."
    Write-Host "Friends need your address and UDP port 7777:"
    Write-Host " - same network or a VPN like Tailscale / ZeroTier / Radmin VPN: give them that address"
    Write-Host " - over the internet: forward UDP 7777 on your router to this PC and give them your public IP"
    Write-Host "Allow the game through Windows Firewall if Windows asks."
  }
  "join" {
    if (-not $Address) { $Address = Read-Host "Host address (IP, optionally :port)" }
    if (-not $Address) { throw "No address given." }
    # Playing in a friend's world makes the game autosave that world into YOUR save slot.
    $saves = Join-Path $env:LOCALAPPDATA "Obscure\Saved\SaveGames"
    if (Test-Path $saves) {
      $bk = Join-Path $env:LOCALAPPDATA ("Obscure\Saved\SaveGames-before-coop-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
      Copy-Item -Recurse $saves $bk
      Write-Host "Your own save was backed up to $bk (Solo.bat offers to restore it)."
    }
    Set-Content -Encoding ascii $cfg @("role = guest", "host = $Address")
    Write-Host "Joining $Address. The game connects by itself a few seconds after the main menu shows."
    Write-Host "You get control of your character about a minute after loading in."
  }
  "solo" {
    Set-Content -Encoding ascii $cfg "role = off"
    $saves = Join-Path $env:LOCALAPPDATA "Obscure\Saved\SaveGames"
    $bk = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Obscure\Saved") -Directory -Filter "SaveGames-before-coop-*" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($bk) {
      $a = Read-Host "Restore your own save from before the last co-op session ($($bk.Name))? [y/N]"
      if ($a -match '^[yY]') {
        $cur = Join-Path $env:LOCALAPPDATA ("Obscure\Saved\SaveGames-after-coop-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        if (Test-Path $saves) { Rename-Item $saves (Split-Path -Leaf $cur) }
        Copy-Item -Recurse $bk.FullName $saves
        Write-Host "Restored. The co-op state was kept in $cur."
      }
    }
  }
}
if (-not $NoLaunch) { Start-Process "steam://rungameid/1766740" }
