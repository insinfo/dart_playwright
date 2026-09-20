<#
.SYNOPSIS
  Runs `dart test` and removes the temporary files the run leaves behind.

.DESCRIPTION
  Every `dart test` invocation writes a `dart_test.kernel.<hash>` directory
  holding the compiled kernel for the package, plus `dart_test.vm.<hash>` for
  the VM service. They are never cleaned up. On a package the size of this one
  each is hundreds of megabytes, and a day of iterating fills the disk: this
  script exists because the system drive hit zero bytes free with more than
  20 GB of leftovers in TEMP.

  Browser automation adds its own: each launched Chromium, Firefox or WebKit
  gets a profile directory under TEMP, and a crashed or killed browser never
  removes it. Those are small individually and arrive by the hundred.

  The script runs the tests and then deletes entries that match a known
  leftover pattern AND have not been touched for -StaleMinutes. Anything the
  user put in TEMP is left alone, and so is anything a concurrent run is using:
  a live kernel directory is young, so age is what separates a leftover from
  work in progress.

  It deliberately does NOT delete "whatever appeared during this run". A run
  that finishes normally leaves nothing behind, so there is nothing to collect;
  what appears during a run may well belong to a *concurrent* run, and deleting
  it breaks that one with `Failed to load ... dart_test.kernel.<hash>`. That
  happened, which is why the rule is age and only age.

  It also reaps processes the tests left behind. That matters more than the
  disk: a stranded browser or viewer server holds its profile directory open --
  so the sweep below cannot remove it -- and sits on a port and a few hundred
  megabytes until the machine is rebooted. Three `playwright show-trace`
  servers once held ports 9299, 9301 and 61772 for over three hours.

  Processes are matched on their COMMAND LINE, never on their name. That is the
  lesson from the leak above: `show-trace` runs under `node.exe`, so a sweep
  looking for `dart`, `chrome` or `playwright_` walked past it. Matching on the
  name alone is also dangerous the other way round, since a bare `chrome.exe`
  is far more likely to be someone's browser than a test. Every pattern names
  this repository's path, a test profile under TEMP, or an npx invocation of
  upstream's viewer; and a deny list keeps the personal browser, other agents'
  runtimes and the user's MCP servers out of reach. `-NoReap` turns it off.

  The exit code is the test runner's, so this is a drop-in replacement for
  `dart test` in scripts and in CI.

.PARAMETER TestArgs
  Arguments forwarded to `dart test`. Defaults to none, i.e. the whole suite.

.PARAMETER StaleMinutes
  Only remove leftovers untouched for this many minutes. Default 30. A live
  run keeps writing to its own directories, so this is what keeps a concurrent
  run safe. Setting it to 0 disables cleaning entirely, processes included.

.PARAMETER NoReap
  Leave stranded processes alone and only clean directories.

.PARAMETER CleanOnly
  Clean and exit without running tests.

.EXAMPLE
  pwsh tool/test_clean.ps1
  pwsh tool/test_clean.ps1 -TestArgs '-j1','test/render'
  pwsh tool/test_clean.ps1 -CleanOnly
  pwsh tool/test_clean.ps1 -CleanOnly -StaleMinutes 5   # more aggressive
#>
[CmdletBinding()]
param(
  [string[]] $TestArgs = @(),
  [int] $StaleMinutes = 30,
  [switch] $CleanOnly,
  [switch] $NoReap
)

$ErrorActionPreference = 'Stop'

# Only these are ever deleted. Being conservative here is the whole point: a
# pattern that is too broad turns a disk-space script into a data-loss script.
$patterns = @(
  'dart_test.kernel.*',
  'dart_test.vm.*',
  'playwright_*',
  'playwright-*'
)

$temp = [System.IO.Path]::GetTempPath()
$repo = Split-Path -Parent $PSScriptRoot

# A leftover *process* is worse than a leftover directory: it holds the
# directory open so the cleanup below cannot remove it, and it keeps a port and
# a few hundred megabytes for as long as the machine is up. Three
# `playwright show-trace` servers once sat on ports 9299, 9301 and 61772 for
# over three hours this way.
#
# Matching is on the COMMAND LINE, never on the process name alone. That is the
# whole lesson of the show-trace leak: it runs under `node.exe`, so a sweep
# looking for `dart`, `chrome` or `playwright_` walked straight past it. And
# matching on name alone would be dangerous in the other direction -- a bare
# `chrome.exe` is far more likely to be somebody's browser than a test.
#
# Each pattern therefore has to name something no ordinary process would carry:
# this repository's path, a test profile under TEMP, or an npx invocation of
# upstream's viewer.
$processPatterns = @(
  # `dart test` and anything it spawned out of this checkout.
  [regex]::Escape($repo) + '.*(dart|test|show_trace|open_trace|open_report)',
  # Browser profiles this port mints, wherever TEMP happens to be.
  'playwright_\w+_profile-',
  'dart_test_[0-9a-f]{6,}',
  # Upstream's viewer, served by npx. Runs under node.exe -- the one that got
  # away last time.
  'playwright@[\d.]+ show-trace',
  'playwright-core[\\/].*show-trace'
)

# Never touched, whatever the patterns say. The personal browser, other
# agents' runtimes and the user's MCP servers are not ours to reap, and a
# cleanup script that kills someone's open tabs gets switched off forever.
$processNeverKill = @(
  'brave', 'msedge', 'msedgewebview2', 'Code', 'devenv', 'Antigravity',
  'OpenAI\\Codex', 'chrome-devtools-mcp', 'language_server'
)

function Get-StaleProcesses([int] $minutes) {
  $cutoff = (Get-Date).AddMinutes(-$minutes)
  $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
  $mine = foreach ($p in $all) {
    $cmd = $p.CommandLine
    if (-not $cmd) { continue }
    if ($p.ProcessId -eq $PID) { continue }
    $skip = $false
    foreach ($deny in $processNeverKill) { if ($cmd -match $deny) { $skip = $true; break } }
    if ($skip) { continue }
    $hit = $false
    foreach ($pat in $processPatterns) { if ($cmd -match $pat) { $hit = $true; break } }
    if (-not $hit) { continue }
    if ($p.CreationDate -and $p.CreationDate -ge $cutoff) { continue }
    $p
  }
  # Whole trees: a browser's renderers are children, and killing the parent
  # alone orphans them onto init.
  $targets = [System.Collections.Generic.HashSet[int]]::new()
  function Add-Tree([int] $processId, $all, $targets) {
    if (-not $targets.Add($processId)) { return }
    foreach ($c in ($all | Where-Object ParentProcessId -eq $processId)) {
      Add-Tree ([int]$c.ProcessId) $all $targets
    }
  }
  foreach ($p in $mine) { Add-Tree ([int]$p.ProcessId) $all $targets }
  return $targets
}

function Get-Leftovers {
  $found = @()
  foreach ($p in $patterns) {
    $found += Get-ChildItem -LiteralPath $temp -Filter $p -Force -ErrorAction SilentlyContinue
  }
  return $found
}

function Measure-SizeGB($items) {
  $bytes = 0
  foreach ($i in $items) {
    try {
      if ($i.PSIsContainer) {
        $bytes += (Get-ChildItem -LiteralPath $i.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Measure-Object -Property Length -Sum).Sum
      } else {
        $bytes += $i.Length
      }
    } catch { }
  }
  return [math]::Round(($bytes / 1GB), 2)
}

$exitCode = 0
if (-not $CleanOnly) {
  Write-Host "dart test $($TestArgs -join ' ')" -ForegroundColor Cyan
  & dart test @TestArgs
  $exitCode = $LASTEXITCODE
}

# `dart_test.kernel.<hash>` is content-addressed, so a run REUSES a directory
# created long ago and only reads from it: old creation time, old write time,
# and in use right now. Age cannot tell that apart. So while any `dart test` is
# running -- here or in another checkout -- nothing is removed at all. Deleting
# a live kernel directory breaks that run with
# `Failed to load ... dart_test.kernel.<hash>`, which is how this was found.
$live = @(Get-CimInstance Win32_Process -Filter "Name='dart.exe'" -ErrorAction SilentlyContinue |
          Where-Object { $_.CommandLine -match 'test' })
if ($live.Count -gt 0) {
  Write-Host "TEMP: $($live.Count) test run(s) still active, skipping cleanup." -ForegroundColor DarkYellow
  $StaleMinutes = 0
}

# Processes first: one of them is probably holding a directory the sweep below
# wants, and killing it is what lets that directory go.
if (-not $NoReap -and $StaleMinutes -gt 0) {
  $stale = Get-StaleProcesses $StaleMinutes
  if ($stale.Count -eq 0) {
    Write-Host "Processes: none left behind." -ForegroundColor DarkGray
  } else {
    # Children first, so a parent does not respawn one on the way down.
    foreach ($processId in ($stale | Sort-Object -Descending)) {
      try { Stop-Process -Id $processId -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Milliseconds 500
    $left = @($stale | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    $msg = "Processes: reaped $($stale.Count - $left.Count) of $($stale.Count) left behind"
    if ($left.Count -gt 0) { $msg += "; $($left.Count) would not die" }
    Write-Host $msg -ForegroundColor Green
  }
}

$toRemove = @()
if ($StaleMinutes -gt 0) {
  $cutoff = (Get-Date).AddMinutes(-$StaleMinutes)
  foreach ($i in (Get-Leftovers)) {
    # Both timestamps: a directory whose contents are still being written has a
    # recent LastWriteTime even when it was created long ago.
    $lastTouch = $i.LastWriteTime
    if ($i.CreationTime -gt $lastTouch) { $lastTouch = $i.CreationTime }
    if ($lastTouch -lt $cutoff) { $toRemove += $i }
  }
}

if ($toRemove.Count -eq 0) {
  Write-Host "TEMP: nothing to clean." -ForegroundColor DarkGray
} else {
  $sizeGB = Measure-SizeGB $toRemove
  $removed = 0
  foreach ($i in $toRemove) {
    try {
      Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction Stop
      $removed++
    } catch {
      # A directory a concurrent run still holds open stays. That is correct:
      # the next invocation will pick it up once it is released.
    }
  }
  $held = $toRemove.Count - $removed
  $msg = "TEMP: removed $removed of $($toRemove.Count) leftovers (~$sizeGB GB)"
  if ($held -gt 0) { $msg += "; $held still in use, left alone" }
  Write-Host $msg -ForegroundColor Green
}

$free = [math]::Round((Get-PSDrive ($temp.Substring(0,1))).Free / 1GB, 2)
Write-Host "Free on $($temp.Substring(0,2)) $free GB" -ForegroundColor DarkGray

exit $exitCode
