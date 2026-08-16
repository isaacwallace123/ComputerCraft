<#
.SYNOPSIS
  Regenerates src\manifest.json - the list of files update.lua downloads.

.DESCRIPTION
  Run this after adding or deleting a .lua file in src\, then commit and push.
  If you forget, the new file simply will not appear on the in-game computer.

.EXAMPLE
  .\tools\make-manifest.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo "src"

$files = Get-ChildItem $src -Recurse -File -Filter *.lua |
  ForEach-Object { $_.FullName.Substring($src.Length + 1).Replace("\", "/") } |
  Sort-Object

$manifest = [ordered]@{
  generated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
  files     = @($files)
}

$out = Join-Path $src "manifest.json"
$manifest | ConvertTo-Json -Depth 3 | Set-Content $out -Encoding utf8

Write-Host "Wrote $out" -ForegroundColor Green
$files | ForEach-Object { "  $_" }
Write-Host ""
Write-Host "Now: git add -A; git commit -m 'update'; git push" -ForegroundColor Cyan
