<#
.SYNOPSIS
  Run the ICOS turtle logic specs against a simulated world.

.DESCRIPTION
  There is no Lua interpreter installed on the development machine, but the Lua
  language server binary that tools\check.ps1 already locates is one. This runs
  the spec suite through it, so the tests need nothing new installed.

  Pass a substring to run only matching specs.

.EXAMPLE
  .\tools\spec.ps1
  .\tools\spec.ps1 cap
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
if ($lua -match "lua-language-server") {
  & $lua -E "tools/spec/runner.lua" $Filter
}
else {
  & $lua "tools/spec/runner.lua" $Filter
}
$code = $LASTEXITCODE
Pop-Location

if ($code -ne 0) {
  Write-Host "SPECS FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "Specs passed." -ForegroundColor Green
