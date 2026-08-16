<#
.SYNOPSIS
  Removes a junction created by link-world.ps1, optionally leaving real files
  behind in its place.

.DESCRIPTION
  Do this before zipping or uploading a world - a junction is not portable and
  the receiving machine would just see an empty computer.

.EXAMPLE
  .\tools\unlink-world.ps1 -CopyBack
#>
[CmdletBinding()]
param(
  [string]$Instance = "C:\Users\isaac\curseforge\minecraft\Instances\Valhelsia 6",
  [string]$World = "New World",
  [int]$Id = 0,
  [switch]$CopyBack
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo "src"
$target = Join-Path $Instance "saves\$World\computercraft\computer\$Id"

$existing = Get-Item $target -ErrorAction SilentlyContinue
if (-not $existing) { Write-Host "Nothing at $target"; return }

if ($existing.LinkType -ne "Junction" -and $existing.LinkType -ne "SymbolicLink") {
  Write-Host "$target is a real folder, not a link. Leaving it alone." -ForegroundColor Yellow
  return
}

[System.IO.Directory]::Delete($existing.FullName, $false)
Write-Host "Link removed." -ForegroundColor Green

if ($CopyBack) {
  Copy-Item $source $target -Recurse
  Write-Host "Copied src\ into the world as real files." -ForegroundColor Green
}
