<#
.SYNOPSIS
  Measure what a rendered frame costs.

.DESCRIPTION
  Runs tools\bench.lua through the same Lua binary the spec suite uses - the one
  the language server ships - so this needs nothing installed that the repository
  did not already require.

  Reports blit calls and milliseconds per frame for an idle screen, a typical
  dashboard update, and a full repaint, on both a computer terminal and the
  largest monitor a person can build. The measured numbers live in
  docs\ui-framework.md section 12.

.EXAMPLE
  .\tools\bench.ps1
#>
[CmdletBinding()]
param()

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
  & $lua -E "tools/bench.lua"
}
else {
  & $lua "tools/bench.lua"
}
$code = $LASTEXITCODE
Pop-Location

exit $code
