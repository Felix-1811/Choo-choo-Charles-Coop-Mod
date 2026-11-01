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

$saved = if ($env:COOP_SAVED_ROOT) { $env:COOP_SAVED_ROOT } else { Join-Path $env:LOCALAPPDATA "Obscure\Saved" }
$saves = Join-Path $saved "SaveGames"
$marker = Join-Path $saved "coop-active.txt"
# Your own settings survive a join; everything else in the slot is story.
$settings = @("Brightness", "Camera Shake", "Controller Rumble", "Defaults Loaded", "Desktop X", "Desktop Y", "FOV", "FPS Limit", "InputMappings",
  "Invert X", "Invert Y", "Left Stick Sensitivity", "Map Height", "Mouse Sensitivity", "Right Stick Sensitivity", "Screen Resolution",
  "Shown Subtitles Tip", "Subtitles", "Text Size", "Upscaling Mode", "Upscaling Sharpness", "Upscaling", "VSync", "VersionNumber",
  "Volume_Master", "Volume_Music", "Volume_SFX", "Volume_Voices", "Window Mode")

switch ($Mode) {
  "host" {
    Set-Content -Encoding ascii $cfg "role = host"
    # Friends get the story from this list of save keys (Lua can't list a folder quietly).
    $names = @()
    if (Test-Path $saves) { $names = @(Get-ChildItem $saves -Filter "*.sav" | ForEach-Object { $_.BaseName }) }
    Set-Content -Encoding ascii (Join-Path (Split-Path $cfg) "savekeys.txt") $names
    # This save becomes the group's. Keep one copy per day, just in case.
    $hb = Join-Path $saved ("SaveGames-host-backup-" + (Get-Date -Format "yyyyMMdd"))
    if ((Test-Path $saves) -and -not (Test-Path $hb)) { Copy-Item -Recurse $saves $hb; Write-Host "Your save was backed up to $hb" }
    Write-Host "Hosting. The game opens your save by itself a few seconds after the main menu shows."
    Write-Host "Friends need your address and UDP port 7777:"
    Write-Host " - same network or a VPN like Tailscale / ZeroTier / Radmin VPN: give them that address"
    Write-Host " - over the internet: forward UDP 7777 on your router to this PC and give them your public IP"
    Write-Host "Allow the game through Windows Firewall if Windows asks."
  }
  "join" {
    if (-not $Address) { $Address = Read-Host "Host address (IP, optionally :port)" }
    if (-not $Address) { throw "No address given." }
    # Playing in a friend's world writes that world into YOUR save slot. So: keep your own save
    # safe once (not again on later sessions: by then the slot holds the friend's world), and
    # start from your settings only, so nothing of your own story mixes with the host's.
    if (-not (Test-Path $marker)) {
      if (Test-Path $saves) {
        $bk = Join-Path $saved ("SaveGames-before-coop-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        Copy-Item -Recurse $saves $bk
        $a = @(Get-ChildItem $saves -Recurse -File).Count; $b = @(Get-ChildItem $bk -Recurse -File).Count
        if ($a -ne $b) { throw "Backing up your save failed ($b of $a files), nothing was changed." }
        Set-Content -Encoding ascii $marker $bk
        Write-Host "Your own save is safe in $bk. Solo.bat puts it back."
      } else {
        Set-Content -Encoding ascii $marker ""
      }
    }
    if (Test-Path $saves) {
      Get-ChildItem $saves -Filter "*.sav" | Where-Object { $settings -notcontains $_.BaseName } | Remove-Item -Force
    }
    Set-Content -Encoding ascii $cfg @("role = guest", "host = $Address")
    Write-Host "Joining $Address. The game connects by itself a few seconds after the main menu shows."
    Write-Host "You get control of your character about a minute after loading in."
  }
  "solo" {
    Set-Content -Encoding ascii $cfg "role = off"
    # Back from co-op: your own save returns by itself; the co-op state is kept beside it.
    if (Test-Path $marker) {
      $bk = (Get-Content $marker -TotalCount 1)
      $cur = Join-Path $saved ("SaveGames-after-coop-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
      if (Test-Path $saves) { Rename-Item $saves (Split-Path -Leaf $cur) }
      if ($bk -and (Test-Path $bk)) {
        Copy-Item -Recurse $bk $saves
        Write-Host "Your own save is back. The co-op state was kept in $cur."
      } else {
        Write-Host "You had no save before co-op, so the game starts fresh. The co-op state was kept in $cur."
      }
      Remove-Item $marker
    }
  }
}
if (-not $NoLaunch) { Start-Process "steam://rungameid/1766740" }
