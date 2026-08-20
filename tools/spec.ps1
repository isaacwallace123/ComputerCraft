<#
.SYNOPSIS
  Run the ICOS specs.

.DESCRIPTION
  There is no Lua interpreter installed on the development machine, but the Lua
  language server binary that tools\check.ps1 already locates is one. This runs
  the suite through it, so the tests need nothing new installed.

  Spec files live in `tests\`, mirroring `src\`, and are discovered rather than
  listed - a new one runs the moment it exists. They are deliberately outside
  `src\` because the updater deploys everything in `src\manifest.json` to every
  machine in the fleet, and a turtle has no use for a spec.

  Pass a substring to run only matching cases.

.EXAMPLE
  .\tools\spec.ps1
  .\tools\spec.ps1 chunk
#>
[CmdletBinding()]
param([string]$Filter)

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$searchRoots = @(
  "$env:APPDATA\Code\User\globalStorage",
  "$env:USERPROFILE\.vscode\extensions"
)

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

$lua = Find-Tool "lua.exe"
if (-not $lua) { $lua = Find-Tool "lua-language-server.exe" }
if (-not $lua) {
  Write-Host "No Lua interpreter found (install the sumneko.lua extension)" -ForegroundColor Red
  exit 1
}

Push-Location $repo

# Discovered, not listed. A spec file that nobody remembered to register is a
# spec file that reports green by never running, which is the one failure a test
# suite must not have.
$specs = Get-ChildItem "tests" -Recurse -File -Filter *_spec.lua |
  ForEach-Object { $_.FullName.Substring($repo.Length + 1).Replace("\", "/") } |
  Sort-Object

if ($specs.Count -eq 0) {
  Pop-Location
  Write-Host "No spec files found under tests\" -ForegroundColor Red
  exit 1
}

# `*` rather than an empty string for "no filter". PowerShell drops an empty
# argument when invoking a native executable, so the first spec path slid into
# the filter slot - the suite loaded one file fewer, matched no case names, and
# reported "0 passed" as a success.
$token = if ([string]::IsNullOrWhiteSpace($Filter)) { "*" } else { $Filter }
$arguments = @("tests/run.lua", $token) + $specs
if ($lua -match "lua-language-server") {
  $arguments = @("-E") + $arguments
}

& $lua @arguments
$code = $LASTEXITCODE
Pop-Location

if ($code -ne 0) {
  Write-Host "SPECS FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "Specs passed." -ForegroundColor Green
