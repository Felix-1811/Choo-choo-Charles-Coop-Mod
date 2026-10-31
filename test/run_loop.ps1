# Run run_pair.ps1 N times and score each run from its logs.
# Pass = guest joined, guest got its pawn, guest moved >300 units on the host, no crash, saves untouched.
param([int]$Count = 10)
$runs = Join-Path (Split-Path -Parent $PSScriptRoot) "runs"
$summary = Join-Path $runs ("loop_" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")

function Pos($line, $name) {
  if ($line -match [regex]::Escape($name) + '\*?\((-?\d+) (-?\d+) (-?\d+)\)') { return @([int]$matches[1], [int]$matches[2]) }
}
$pass = 0
for ($i = 1; $i -le $Count; $i++) {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "run_pair.ps1") -TimeoutSec 420 2>&1 | Out-String
  $dir = ([regex]::Match($out, 'RUN DIR: (\S+)')).Groups[1].Value
  $g = Get-Content (Join-Path $dir "probe_guest.log") -ErrorAction SilentlyContinue
  $h = Get-Content (Join-Path $dir "probe_host.log") -ErrorAction SilentlyContinue
  $joined = [bool]($g | Select-String "JOINED host world")
  $pawn = [bool]($g | Select-String "has a pawn after the host")
  $crash = (Test-Path (Join-Path $dir "userdir-guest\Saved\Crashes")) -or (Test-Path (Join-Path $dir "userdir-host\Saved\Crashes"))
  $saves = $out -match "real save folder unchanged"
  $keyed = [bool](Get-Content (Join-Path $dir "procs.log") -ErrorAction SilentlyContinue | Select-String "held W")
  # guest character name on the host = the non-local one in host STATUS lines
  $moved = 0
  $hs = $h | Select-String "STATUS\[wait_guest\].*chars=2"
  if ($hs) {
    $first = $hs[0].Line; $last = $hs[-1].Line
    $gname = ([regex]::Matches($first, '(BP_NMCharacter_Player_C_\d+)\(') | Select-Object -First 1).Groups[1].Value
    $a = Pos $first $gname; $b = Pos $last $gname
    if ($a -and $b) { $moved = [int][Math]::Sqrt([Math]::Pow($b[0]-$a[0],2) + [Math]::Pow($b[1]-$a[1],2)) }
  }
  $ok = $joined -and $pawn -and (-not $crash) -and $saves -and $moved -gt 300
  if ($ok) { $pass++ }
  $line = "{0,2} {1} joined={2} pawn={3} keyed={4} moved_on_host={5} crash={6} saves_ok={7} -> {8}" -f $i, (Split-Path -Leaf $dir), $joined, $pawn, $keyed, $moved, $crash, $saves, ($(if ($ok) {"PASS"} else {"FAIL"}))
  Add-Content $summary $line; Write-Output $line
}
$tot = "TOTAL $pass/$Count passed"
Add-Content $summary $tot; Write-Output $tot
