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

Write-Host "== lua-language-server ==" -ForegroundColor Cyan
$luals = Find-Tool "lua-language-server.exe"
if ($luals) {
  $out = & $luals --check $repo --checklevel=Warning --logpath="$env:TEMP\cc-check" 2>&1
  $summary = $out | Select-Object -Last 1
  Write-Host "  $summary"
  if ($summary -notmatch "no problems found") { $failed = $true }
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

Write-Host ""
if ($failed) {
  Write-Host "FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "All checks passed." -ForegroundColor Green
