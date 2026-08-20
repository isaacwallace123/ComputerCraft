<#
.SYNOPSIS
  Show the proposed ICOS look in your terminal.

.DESCRIPTION
  Runs tools\preview.lua through the same Lua binary the spec suite uses - the one
  the language server ships - so this needs nothing installed that the repository
  did not already require.

  Paints example screens through src\ui\buffer.lua at a real 51x19 computer
  terminal, then writes the cell grid out as ANSI truecolour. It is the actual
  renderer and the actual sixteen palette slots, not a drawing - so what you see
  is what a computer would show.

  Also reports the greyscale separation of the semantic tokens, which is what a
  non-advanced terminal reduces the palette to. See docs\ui-design.md.

  Needs a terminal that understands ANSI truecolour: Windows Terminal, the VS
  Code terminal, and PowerShell 7 all do. The Windows 10+ console host does too.

.EXAMPLE
  .\tools\preview.ps1
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
  & $lua -E "tools/preview.lua"
}
else {
  & $lua "tools/preview.lua"
}
$code = $LASTEXITCODE
Pop-Location

exit $code
