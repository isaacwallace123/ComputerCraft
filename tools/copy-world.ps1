<#
.SYNOPSIS
  Copy the build into one world computer, keeping that machine's own state.

.DESCRIPTION
  `link-world.ps1` junctions a computer at `build\`, which is the fastest loop
  there is - but only one machine can have it. Two computers pointed at one
  directory share `.node`, so they boot the same role; they share `.location`, so
  they claim the same coordinates; and they share `.nav` and `.log`. That is not
  a slower test, it is a broken one.

  So every other machine gets a copy. This runs `build.ps1`, overwrites the code
  from it, and leaves the state alone.

  Building rather than stripping in place: the size rule and the comment
  stripping belong in one file, because "does this fit on a CC computer" is a
  question about the tree and not about which machine happens to be receiving it.

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

# The tree a computer runs, not the tree the repository holds. `build.ps1` owns
# the comment stripping and the size rule; this script owns getting one machine's
# files replaced without touching its state. Two jobs, one each, and the size
# limit is checked in the one place that can enforce it.
$built = & (Join-Path $PSScriptRoot "build.ps1") -Quiet
$src = $built.Path

$root = Join-Path $Instance "saves\$World\computercraft\computer\$Id"

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
#
# The rule is the dot. Every file ICOS persists is a dotfile - `.node`,
# `.location`, `.nav`, `.mine`, `.log`, a job file - and every file it ships is
# not. So "replace everything that is not a dotfile" needs no list to maintain
# and cannot forget the state file somebody adds next month.
Get-ChildItem $root -Force | Where-Object { -not $_.Name.StartsWith(".") } | ForEach-Object {
  Remove-Item $_.FullName -Recurse -Force
}

# In with the new, and only the part this machine's role needs.
#
# A real machine downloads its role's closure and nothing else - see the `roles`
# block in `tools/make-manifest.ps1`. Copying the whole build here would make
# every in-world test run against a machine holding files production does not
# have, which is the kind of difference that is only discovered by the fleet.
#
# The role comes from `-Role` when given, and from the target's own `.node` when
# not, so re-copying a machine that is already set up keeps it honest without
# anybody restating what it is.
$manifest = Get-Content (Join-Path $src "manifest.json") -Raw | ConvertFrom-Json
$targetRole = $Role
if (-not $targetRole) {
  $nodePath = Join-Path $root ".node"
  if (Test-Path $nodePath) {
    $nodeText = Get-Content $nodePath -Raw
    if ($nodeText -match 'role\s*=\s*"(\w+)"') { $targetRole = $matches[1] }
  }
}

# ICOS 1 role names still exist on live machines. One mapping, matching
# `os/kernel/roles.lua`, so a `miner` gets the turtle's files.
$asRole = @{
  fleet = "server"; gps = "server"; miner = "turtle"; controller = "mobile"
  utility = "client"; server = "server"; client = "client"; turtle = "turtle"; mobile = "mobile"
}
$wanted = $null
if ($targetRole -and $asRole.ContainsKey($targetRole)) {
  $wanted = @($manifest.roles.($asRole[$targetRole]))
}

if ($wanted) {
  foreach ($name in $wanted) {
    $from = Join-Path $src $name
    if (-not (Test-Path $from)) { throw "the build has no $name" }
    $to = Join-Path $root $name
    $dir = Split-Path -Parent $to
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item $from -Destination $to -Force
  }
  Write-Host ("Role $targetRole -> $($asRole[$targetRole]): {0} of {1} files" -f
    $wanted.Count, $manifest.files.Count) -ForegroundColor Cyan
}
else {
  # No role to filter by, so the machine gets everything - exactly what a fresh
  # computer downloads before `setup` has told it what it is.
  Get-ChildItem $src -Force | Where-Object { -not $_.Name.StartsWith(".") } | ForEach-Object {
    Copy-Item $_.FullName -Destination $root -Recurse -Force
  }
}

$size = (Get-ChildItem $root -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
$colour = if ($size -gt $built.Limit) { "Red" } else { "Green" }
Write-Host ("{0} KB of {1} KB used, including this machine's own state" -f
  [math]::Round($size / 1024), [math]::Round($built.Limit / 1024)) -ForegroundColor $colour
if ($size -gt $built.Limit) {
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
