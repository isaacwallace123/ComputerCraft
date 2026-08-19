<#
.SYNOPSIS
  Verify that every path in the handoff map points at something that exists.

.DESCRIPTION
  `AGENTS.md` tells every new agent and maintainer to read `docs/ai-handoff.md`
  first, and the most useful thing in it is the "Where to make changes" table.
  That table had rotted to thirty-three broken rows out of forty - every one of
  them pointing at a file the D039 restructure moved - which made the first
  thing anybody reads the least reliable thing in the repository. A map that is
  confidently wrong is worse than no map: it sends a change into `src/os/` that
  needed to go into `src/legacy/`, which builds, passes, and does nothing.

  Deliberately scoped to that one table and to `AGENTS.md`, and not to the docs
  as a whole. The other documents are full of paths that are correctly historical
  - a decision record explaining why `core/` was dismantled has to be able to say
  `core/`, and a migration note has to name the file it migrated from. Checking
  those would produce failures that are not defects, and a check that cries wolf
  gets switched off rather than fixed.

.EXAMPLE
  .\tools\check-docs.ps1
#>
[CmdletBinding()]
param()

$repo = Split-Path -Parent $PSScriptRoot
$failed = $false

# A backticked token is a path worth checking when it contains a slash or ends
# in a known extension. Everything else in these tables is prose, a symbol
# (`Buffer:clip`), or a placeholder (`src/apps/<id>/view.lua`), and none of those
# name a file.
function Get-Paths([string]$text) {
  $found = @()
  foreach ($match in [regex]::Matches($text, '`([^`]+)`')) {
    $token = $match.Groups[1].Value.Trim()
    if ($token -match '[<>*]') { continue }          # placeholder
    if ($token -match '^[A-Za-z_]+:') { continue }   # Buffer:clip, Root:dispatch
    if ($token -notmatch '/' -and $token -notmatch '\.(lua|ps1|md|json|yml)$') { continue }
    # A trailing `.lua` on a require path (`domain.mine.plan`) is not a file path.
    if ($token -notmatch '/' -and $token -match '^\w+(\.\w+)+$') { continue }
    $found += $token
  }
  return $found
}

function Test-Paths([string]$label, [string]$text) {
  $broken = @()
  foreach ($path in (Get-Paths $text | Sort-Object -Unique)) {
    # Written from the repository root, with or without a leading `.\`.
    $clean = $path -replace '^\./', '' -replace '\\', '/'
    if (-not (Test-Path (Join-Path $repo $clean))) {
      $broken += $path
    }
  }
  if ($broken.Count -gt 0) {
    Write-Host "  $label" -ForegroundColor Red
    $broken | ForEach-Object { Write-Host "    $_ does not exist" -ForegroundColor Red }
    return $false
  }
  Write-Host "  $label is accurate"
  return $true
}

Write-Host "== handoff map ==" -ForegroundColor Cyan

$handoff = Get-Content (Join-Path $repo "docs\ai-handoff.md") -Raw
# Just the table: from the heading to the next one. Prose elsewhere in the
# document is allowed to name files that have since moved, because some of it is
# explaining that they moved.
$table = [regex]::Match($handoff, '(?s)## Where to make changes(.*?)\r?\n## ')
if (-not $table.Success) {
  Write-Host "  the 'Where to make changes' table is gone - if it was renamed, update this check" -ForegroundColor Red
  exit 1
}
if (-not (Test-Paths "docs/ai-handoff.md" $table.Groups[1].Value)) { $failed = $true }

$agents = Get-Content (Join-Path $repo "AGENTS.md") -Raw
if (-not (Test-Paths "AGENTS.md" $agents)) { $failed = $true }

# Every `require` in the tree, checked against the tree.
#
# `tools/bench.ps1`, `compare.ps1` and `preview.ps1` all required `ui.buffer`
# for the whole of D039 - the file had moved to `ui/render/buffer.lua` and
# nothing noticed, because a tool nobody runs is a tool nobody notices is
# broken. The handoff document tells maintainers to run the bench after every
# change to `src/ui/`, so the first person to follow that instruction would have
# hit a stack trace instead of a number.
#
# A `require` is a path claim exactly like a documentation link, and it rots the
# same way. This is the same check, pointed at code.
Write-Host "== requires ==" -ForegroundColor Cyan
$roots = @((Join-Path $repo "src"), (Join-Path $repo "tests"))
$brokenRequires = @()
$files = @()
foreach ($dir in @("src", "tools", "tests")) {
  $files += Get-ChildItem (Join-Path $repo $dir) -Recurse -File -Filter *.lua -ErrorAction SilentlyContinue
}

foreach ($file in $files) {
  $text = [System.IO.File]::ReadAllText($file.FullName)
  foreach ($match in [regex]::Matches($text, 'require\(\s*"([A-Za-z0-9_.]+)"')) {
    $module = $match.Groups[1].Value
    # A dotted module name is a path. Anything without a dot is a stdlib-ish
    # name or a local alias and is left alone.
    if ($module -notmatch '\.') { continue }
    $relative = ($module -replace '\.', '/') + ".lua"
    $found = $false
    foreach ($root in $roots) {
      if (Test-Path (Join-Path $root $relative)) { $found = $true }
      if (Test-Path (Join-Path $root (($module -replace '\.', '/') + "/init.lua"))) { $found = $true }
    }
    if (-not $found) {
      $name = $file.FullName.Substring($repo.Length + 1).Replace("\", "/")
      $brokenRequires += "    $name requires $module, which does not exist"
    }
  }
}

if ($brokenRequires.Count -gt 0) {
  Write-Host "  broken module paths" -ForegroundColor Red
  $brokenRequires | Sort-Object -Unique | ForEach-Object { Write-Host $_ -ForegroundColor Red }
  $failed = $true
}
else {
  Write-Host "  every require resolves"
}

Write-Host "== module calls ==" -ForegroundColor Cyan

# A require that resolves says the file exists. It says nothing about whether
# the function being called on it does - and `format.fit`, a call to a function
# that has never existed, shipped past every check here and was found by a
# turtle in a world refusing to draw. Python because the tooling already needs
# it and the parsing is a page of regex rather than a page of PowerShell.
$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }

if ($python) {
  Push-Location $repo
  & $python.Source "tools/check-exports.py"
  $callsOk = $LASTEXITCODE -eq 0
  Pop-Location
  if (-not $callsOk) { $failed = $true }
}
else {
  Write-Host "  skipped (no python on PATH)" -ForegroundColor DarkGray
}

Write-Host ""
if ($failed) {
  Write-Host "FAILED - fix the path, or the map is worse than no map" -ForegroundColor Red
  exit 1
}
Write-Host "Documentation paths resolve." -ForegroundColor Green
