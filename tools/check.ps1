<#
.SYNOPSIS
  Static checks over the whole repo: type checking, linting, formatting.

.DESCRIPTION
  Run before pushing. Uses the binaries the VS Code extensions already ship, so
  there is nothing extra to install.

  - lua-language-server --check   type and nil-safety errors
  - selene                        lint against the CC: Tweaked standard library
  - stylua --check                formatting

  Anything not installed is skipped with a note rather than failing the run.

.EXAMPLE
  .\tools\check.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$searchRoots = @(
  # The extensions download their own binaries here. Checked first on purpose:
  # a rokit shim of the same name may sit on PATH, and it refuses to run unless
  # the tool is declared in a rokit.toml, which this project has no reason to have.
  "$env:APPDATA\Code\User\globalStorage",
  "$env:USERPROFILE\.vscode\extensions"
)
$failed = $false

function Find-Tool([string]$exeName) {
  foreach ($root in $searchRoots) {
    if (-not (Test-Path $root)) { continue }
    $found = Get-ChildItem $root -Filter $exeName -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($found) { return $found.FullName }
  }
  $onPath = Get-Command $exeName -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  return $null
}

# The layering rule from docs/icos-2.md section 3: `domain/` may not reference a
# CC global. `ports/` and `ui/` are held to the same standard - a port that
# reached for `term` would defeat the recording screen the whole renderer is
# tested through, and the point of writing the rule down is that something
# checks it. Nothing else can: the type checker is happy with a CC global and
# selene is happier still, because in every other folder they are correct.
#
# Comments are stripped first, since every one of these files talks about the
# APIs it is standing in for. A `--` inside a string literal would truncate that
# line early, which can only make the check more permissive - it is a guardrail
# against drift, not a proof.
#
# A name the file declares as a local is skipped, because in Lua a local shadows
# the global for the rest of the scope - `local host = {}` followed by `host.run`
# is not a reference to anything global. Without this the check reports a file
# for using its own variable, which is the kind of false positive that gets a
# check switched off rather than fixed.
Write-Host "== layering ==" -ForegroundColor Cyan
$pureRoots = @("domain", "ports", "ui", "lib")
$ccGlobals = @(
  "fs", "term", "turtle", "rednet", "gps", "peripheral", "colors", "colours",
  "keys", "textutils", "parallel", "settings", "window", "paintutils", "vector",
  "disk", "redstone", "commands", "multishell", "shell", "pocket", "http", "os"
)
# Known debt, with the reason recorded in the file's own header.
#
# **This list is empty, and keeping it empty is the point.** It held two files:
# `domain/mine/registry.lua`, moved into `domain/` without being de-globalised
# so the existing specs could prove the move changed nothing, and `lib/util.lua`,
# whose `since` defaulted its clock. Both are clean - the CC clock and the CC
# file now live in `legacy/mine/registry.lua` and at the one call site in
# `legacy/fleet/roster.lua`, which are ICOS 1 and are allowed to.
#
# Adding an entry here is declaring that a pure folder is not pure. Do it only
# with a header comment in the file saying what empties it again, and treat it
# as a debt with a due date rather than an exemption.
$layeringDebt = @{}

# `lib/` joined the pure roots when `core/` was dismantled. It holds the two
# files that were genuinely generic - `util` and `version` - and the point of
# checking it is to stop it becoming the next `core/`: a folder that starts as
# "shared helpers" and ends as thirteen of fourteen files touching CC globals.

$violations = @()
foreach ($root in $pureRoots) {
  $dir = Join-Path $repo "src\$root"
  if (-not (Test-Path $dir)) { continue }
  foreach ($file in Get-ChildItem $dir -Recurse -File -Filter *.lua) {
    $relative = $file.FullName.Substring((Join-Path $repo "src").Length + 1).Replace("\", "/")
    $allowed = $layeringDebt[$relative]
    $code = [System.IO.File]::ReadAllText($file.FullName)
    $code = [regex]::Replace($code, "--\[\[.*?\]\]", "", "Singleline")
    $code = [regex]::Replace($code, "--[^\r\n]*", "")
    # String literals go too, for the same reason comments do: their contents
    # are not references. `domain/turtle/jobs.lua` names the module each job
    # lives in - "os.turtle.jobs.mining.quarry" - and a check that reads that
    # as a use of the CC global `os` reports a file for saying where its own
    # code is. Like the comment stripping above, this can only make the check
    # more permissive; it is a guardrail against drift, not a proof.
    $code = [regex]::Replace($code, '"(?:[^"\\\r\n]|\\.)*"', "")
    $code = [regex]::Replace($code, "'(?:[^'\\\r\n]|\\.)*'", "")
    foreach ($name in $ccGlobals) {
      if ($allowed -contains $name) { continue }
      if ($code -match "(?m)^\s*local\s+$name\b") { continue }
      if ($code -match "(?<![\w.:])$name\s*[.\[]") {
        $violations += "  $relative references the CC global '$name'"
      }
    }
  }
}
if ($violations.Count -gt 0) {
  $violations | Sort-Object -Unique | ForEach-Object { Write-Host $_ -ForegroundColor Red }
  Write-Host "  take it through a port in src\ports instead" -ForegroundColor Yellow
  $failed = $true
}
else {
  Write-Host "  domain, ports and ui are free of CC globals"
}

Write-Host "== lua-language-server ==" -ForegroundColor Cyan
$luals = Find-Tool "lua-language-server.exe"
if ($luals) {
  $logs = "$env:TEMP\cc-check"
  # `--check_out_path` names the report explicitly. It used to be read out of
  # `--logpath`, where the language server does not put it - so every failure
  # printed "N problems found" and nothing else, which is the exact thing the
  # comment below says this branch exists to prevent. It cost somebody five
  # minutes before anybody noticed the report had never been found.
  $report = "$logs\check.json"
  if (Test-Path $report) { Remove-Item $report -Force }
  $out = & $luals --check $repo --checklevel=Warning --logpath=$logs --check_out_path=$report 2>&1
  $summary = $out | Select-Object -Last 1
  Write-Host "  $summary"
  if ($summary -notmatch "no problems found") {
    # Print the diagnostics, not just the count. The same reason the selene
    # branch below prints everything: "1 problems found" without a file and a
    # line is a check that tells you to go and find it yourself, and the report
    # is sitting in a file this script already knows the path of.
    if (Test-Path $report) {
      $json = Get-Content $report -Raw | ConvertFrom-Json
      foreach ($file in $json.PSObject.Properties) {
        $path = $file.Name -replace [regex]::Escape("file:///"), "" -replace "%3A", ":"
        foreach ($d in $file.Value) {
          $line = $d.range.start.line + 1
          Write-Host "  $path`:$line - $($d.message)" -ForegroundColor Yellow
        }
      }
    }
    $failed = $true
  }
}
else {
  Write-Host "  skipped (install the sumneko.lua extension)" -ForegroundColor DarkGray
}

Write-Host "== selene ==" -ForegroundColor Cyan
$selene = Find-Tool "selene.exe"
if ($selene) {
  Push-Location $repo
  $out = & $selene src 2>&1
  $code = $LASTEXITCODE
  Pop-Location
  if ($code -ne 0) {
    # Print everything - the trailing "Results" block alone hides which file
    # and line the warning is actually on.
    $out | ForEach-Object { "  $_" }
    $failed = $true
  }
  else {
    Write-Host "  clean"
  }
}
else {
  Write-Host "  skipped (open a .lua file once so the extension downloads it)" -ForegroundColor DarkGray
}

Write-Host "== stylua ==" -ForegroundColor Cyan
$stylua = Find-Tool "stylua.exe"
if ($stylua) {
  Push-Location $repo
  & $stylua --check src 2>&1 | ForEach-Object { "  $_" }
  $styluaFailed = $LASTEXITCODE -ne 0
  Pop-Location
  if ($styluaFailed) {
    Write-Host "  run: stylua src" -ForegroundColor Yellow
    $failed = $true
  }
  else {
    Write-Host "  formatting clean"
  }
}
else {
  Write-Host "  skipped (install the johnnymorganz.stylua extension)" -ForegroundColor DarkGray
}

# The handoff map, checked for the same reason the layering rule is: it was a
# claim nothing verified, and it had rotted to thirty-three broken rows out of
# forty. A wrong map is worse than no map - it sends a change into `src/os/`
# that needed to go into `src/legacy/`, which builds, passes, and does nothing.
& (Join-Path $PSScriptRoot "check-docs.ps1")
if ($LASTEXITCODE -ne 0) { $failed = $true }

Write-Host ""
if ($failed) {
  Write-Host "FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "All checks passed." -ForegroundColor Green
