<#
.SYNOPSIS
  Copy src\ into one world computer, keeping that machine's own state.

.DESCRIPTION
  `link-world.ps1` junctions a computer straight at `src\`, which is the fastest
  loop there is - but only one machine can have it. Two computers pointed at one
  directory share `.node`, so they boot the same role; they share `.location`, so
  they claim the same coordinates; and they share `.nav` and `.log`. That is not
  a slower test, it is a broken one.

  So the second machine gets a copy. This overwrites the code and leaves the
  state alone.

  The rule is the dot. Every file ICOS persists is a dotfile - `.node`,
  `.location`, `.nav`, `.mine`, `.log`, a job file - and every file it ships is
  not. So "replace everything that is not a dotfile" needs no list to maintain
  and cannot forget the state file somebody adds next month.

.EXAMPLE
  .\tools\copy-world.ps1 -World "ComputerCraft" -Id 5
  .\tools\copy-world.ps1 -World "ComputerCraft" -Id 5 -Role server -Label base
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$World,
  [Parameter(Mandatory)][int]$Id,
  [string]$Role,
  [string]$Label,
  [string]$Branch,
  [string]$Instance = "C:\Users\isaac\curseforge\minecraft\Instances\Valhelsia 6"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo "src"

$root = Join-Path $Instance "saves\$World\computercraft\computer\$Id"

if (-not (Test-Path $src)) { throw "No src at $src" }

if (-not (Test-Path $root)) {
  # A computer that has never been powered on has no directory. Making it is
  # safe and saves a round trip into the game to place-and-boot before copying.
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  Write-Host "Created $root (place computer $Id in the world if you have not)" -ForegroundColor Yellow
}

$link = Get-Item $root -Force
if ($link.LinkType) {
  throw "Computer $Id is a $($link.LinkType) to $($link.Target). Unlink it first, or copy to a different id - a junctioned machine already has the code."
}

# Out with the code, keeping every dotfile.
Get-ChildItem $root -Force | Where-Object { -not $_.Name.StartsWith(".") } | ForEach-Object {
  Remove-Item $_.FullName -Recurse -Force
}

# In with the new. Dotfiles in src\ are this developer machine's own leftovers
# from a junction - never the target's - so they are not copied.
Get-ChildItem $src -Force | Where-Object { -not $_.Name.StartsWith(".") } | ForEach-Object {
  Copy-Item $_.FullName -Destination $root -Recurse -Force
}

# Strip comment-only lines, keeping the line count.
#
# A CC computer gets 1,000,000 bytes and this tree is 1,096,626 of which 55% is
# comments. The first machine to find that out was a turtle that could not write
# its own `.location` because the disk was full - a failure that says nothing
# about the real cause and points at the file it happened to be writing.
#
# The comments are for the repository, not the device. But the **line numbers**
# are for the device: `apps/job/app.lua:207` in an error message is the single
# most useful thing this system has produced in a world, and it is only useful
# while it matches the file somebody opens here. So each comment line becomes an
# empty line rather than disappearing - one byte instead of sixty, and line 207
# is still line 207.
$stripped = 0
Get-ChildItem $root -Recurse -File -Filter *.lua | ForEach-Object {
  $lines = [System.IO.File]::ReadAllLines($_.FullName)
  $out = foreach ($line in $lines) {
    if ($line.TrimStart().StartsWith("--")) { "" } else { $line }
  }
  [System.IO.File]::WriteAllLines($_.FullName, $out)
  $stripped++
}

# Measured after the write, not from the cached FileInfo - which is what the
# first version did, and it reported "saving 0 KB" while having just halved the
# tree.
$size = (Get-ChildItem $root -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
$limit = 1000000
$colour = if ($size -gt $limit) { "Red" } else { "Green" }
Write-Host ("Stripped comments from {0} files - {1} KB of {2} KB used" -f
  $stripped, [math]::Round($size / 1024), [math]::Round($limit / 1024)) -ForegroundColor $colour
if ($size -gt $limit) {
  Write-Host "  OVER the computer_space_limit - writes on this machine will fail" -ForegroundColor Red
}

$files = (Get-ChildItem $root -Recurse -File -Force | Where-Object { -not $_.Name.StartsWith(".") }).Count
Write-Host "Copied $files files to computer $Id" -ForegroundColor Green

if ($Role) {
  # Written here rather than left to setup, because the point of a second
  # machine is usually to be a specific thing, and walking into the game to
  # answer three questions is the slow half of the loop.
  $node = Join-Path $root ".node"
  $existing = if (Test-Path $node) { Get-Content $node -Raw } else { "" }

  $lines = @("{")
  $lines += "  role = `"$Role`","
  if ($Label) { $lines += "  label = `"$Label`"," }
  # Anything already there that is not role or label survives - a job, a parked
  # flag, an autoUpdate preference somebody set on purpose.
  foreach ($line in ($existing -split "`r?`n")) {
    $t = $line.Trim()
    if ($t -and $t -ne "{" -and $t -ne "}" -and $t -notmatch '^\s*(role|label)\s*=') {
      $lines += "  $t"
    }
  }
  $lines += "}"
  Set-Content -Path $node -Value ($lines -join "`n") -Encoding utf8 -NoNewline

  Write-Host "Set role=$Role$(if ($Label) { ", label=$Label" })" -ForegroundColor Green
}

if ($Branch) {
  # Which branch this machine pulls from when somebody runs `update`.
  #
  # Worth setting explicitly, because getting it wrong is silent and total: a
  # machine pointed at a branch that does not have the code you are testing
  # downloads sixty files, reports success, and reboots into something else
  # entirely. That is not a hypothetical - it happened to this world's server,
  # which was pointed at master and pulled ICOS 1 over a working ICOS 2 copy.
  $update = Join-Path $root ".update"
  $existing = if (Test-Path $update) { Get-Content $update -Raw } else { "" }

  $lines = @("{")
  $lines += "  branch = `"$Branch`","
  foreach ($line in ($existing -split "`r?`n")) {
    $t = $line.Trim()
    if ($t -and $t -ne "{" -and $t -ne "}" -and $t -notmatch '^\s*branch\s*=') {
      $lines += "  $t"
    }
  }
  $lines += "}"
  Set-Content -Path $update -Value ($lines -join "`n") -Encoding utf8 -NoNewline

  Write-Host "Set branch=$Branch" -ForegroundColor Green
}

Write-Host ""
Write-Host "Reboot computer $Id in game to run it." -ForegroundColor Cyan
