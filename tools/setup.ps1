<#
.SYNOPSIS
  One-time setup after cloning this repo on a new machine.

.DESCRIPTION
  Downloads the CC: Tweaked type definitions that give VS Code autocomplete and
  type checking. They live in types\ and are gitignored, so every fresh clone
  needs this once.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $repo "types\cc-tweaked"

if (Test-Path $dest) {
  Write-Host "Updating type definitions..." -ForegroundColor Cyan
  git -C $dest pull --ff-only
}
else {
  Write-Host "Cloning type definitions..." -ForegroundColor Cyan
  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  git clone --depth 1 https://github.com/nvim-computercraft/lua-ls-cc-tweaked.git $dest
}

Write-Host ""
Write-Host "Done. Install the 'Lua' extension by sumneko if you have not:" -ForegroundColor Green
Write-Host "  code --install-extension sumneko.lua"
