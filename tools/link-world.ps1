<#
.SYNOPSIS
  Wires a LOCAL singleplayer world's computer straight to .\src\ so edits apply
  instantly with no push and no update step.

.DESCRIPTION
  This is for a throwaway test world on your own machine, not for the server -
  on a server the computer's files live on the host, so use the GitHub route
  (tools\make-manifest.ps1 + the in-game `update` program) instead.

  CC: Tweaked stores computer <id> at
    <instance>\saves\<world>\computercraft\computer\<id>\
  This replaces that folder with a directory junction pointing at .\src\, so the
  files VS Code edits ARE the files the in-game computer runs. Save, then reboot
  the computer in game - that is the whole loop.

  Junctions do not require administrator rights.

.EXAMPLE
  .\tools\link-world.ps1 -List
  .\tools\link-world.ps1 -World "CC Testing" -Id 0
#>
[CmdletBinding()]
param(
  [string]$Instance = "C:\Users\isaac\curseforge\minecraft\Instances\Valhelsia 6",
  [string]$World = "New World",
  [int]$Id = 0,
  [switch]$List
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo "src"

if (-not (Test-Path $Instance)) { throw "Instance not found: $Instance" }
$savesDir = Join-Path $Instance "saves"

if ($List) {
  Write-Host "Worlds in $savesDir" -ForegroundColor Cyan
  Get-ChildItem -Directory $savesDir | Sort-Object LastWriteTime -Descending |
    ForEach-Object { "  {0,-40} {1}" -f $_.Name, $_.LastWriteTime }
  return
}

$worldDir = Join-Path $savesDir $World
if (-not (Test-Path $worldDir)) { throw "World not found: $worldDir  (try -List)" }

$computerDir = Join-Path $worldDir "computercraft\computer"
New-Item -ItemType Directory -Force -Path $computerDir | Out-Null
$target = Join-Path $computerDir $Id

$existing = Get-Item $target -ErrorAction SilentlyContinue
if ($existing) {
  if ($existing.LinkType -eq "Junction" -or $existing.LinkType -eq "SymbolicLink") {
    # Deleting a junction removes the link only; the target contents are untouched.
    [System.IO.Directory]::Delete($existing.FullName, $false)
    Write-Host "Replaced existing link." -ForegroundColor DarkGray
  }
  else {
    $backup = "$target.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    Move-Item $target $backup
    Write-Warning "Computer $Id had real files. Moved them to:`n  $backup"
  }
}

& cmd.exe /c mklink /J "`"$target`"" "`"$source`"" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "mklink failed with exit code $LASTEXITCODE" }

Write-Host ""
Write-Host "Linked computer $Id in '$World' -> src\" -ForegroundColor Green
Write-Host "  $target"
Write-Host ""
Write-Host "Place a computer in that world; the first one you place gets ID 0." -ForegroundColor Cyan
Write-Host "Re-run this after making a new world, or with -Id n for another computer."
