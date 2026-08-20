<#
.SYNOPSIS
  Wires a LOCAL singleplayer world's computer at .\build\ so edits apply after
  one build command, with no push and no update step.

.DESCRIPTION
  This is for a throwaway test world on your own machine, not for the server -
  on a server the computer's files live on the host, so use the GitHub route
  (tools\make-manifest.ps1 + the in-game `update` program) instead.

  CC: Tweaked stores computer <id> at
    <instance>\saves\<world>\computercraft\computer\<id>\
  This replaces that folder with a directory junction pointing at .\build\.
  Save, run `tools\build.ps1`, reboot the computer in game - that is the loop.

  It used to point at `src\` directly, which was one command shorter and put a
  1.2 MB tree on a 1 MB disk. The machine drew perfectly and could not write a
  single file: its log stayed empty and its saved desktop arrangement vanished on
  every reboot, with nothing anywhere reporting an error. See `tools\build.ps1`.

  The junction survives a rebuild, because the build replaces the files inside
  the directory rather than the directory itself - and it leaves dotfiles alone,
  so the linked computer keeps its own `.node`, `.log` and position.

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
$source = Join-Path $repo "build"

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

# Built first, so linking a fresh clone does not produce a junction pointing at
# a directory that does not exist yet.
& (Join-Path $PSScriptRoot "build.ps1") | Out-Null

& cmd.exe /c mklink /J "`"$target`"" "`"$source`"" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "mklink failed with exit code $LASTEXITCODE" }

Write-Host ""
Write-Host "Linked computer $Id in '$World' -> build\" -ForegroundColor Green
Write-Host "  $target"
Write-Host ""
Write-Host "Place a computer in that world; the first one you place gets ID 0." -ForegroundColor Cyan
Write-Host "Re-run this after making a new world, or with -Id n for another computer."
Write-Host "After editing: .\tools\build.ps1, then reboot the computer in game." -ForegroundColor Cyan
