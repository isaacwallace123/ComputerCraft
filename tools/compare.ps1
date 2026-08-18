<#
.SYNOPSIS
  Compare the ICOS renderer against Basalt 2 on one workload.

.DESCRIPTION
  Runs tools\compare.lua through the same Lua binary the spec suite uses - the one
  the language server ships - so this needs nothing installed that the repository
  did not already require.

  Runs one identical dashboard workload through two renderer designs and counts
  the terminal calls each produces: the cell diff in src\ui\buffer.lua, and a
  faithful reimplementation of the dirty-rectangle algorithm in Basalt 2's
  src/render.lua.

  The comparison is narrow on purpose - it is the renderers only, not the
  frameworks. See the header of tools\compare.lua for what that does and does
  not establish. The measured numbers live in docs\ui-framework.md section 12.

.EXAMPLE
  .\tools\compare.ps1
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
  & $lua -E "tools/compare.lua"
}
else {
  & $lua "tools/compare.lua"
}
$code = $LASTEXITCODE
Pop-Location

exit $code
