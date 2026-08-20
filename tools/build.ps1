<#
.SYNOPSIS
  Produce build\ - the tree a CC computer actually runs - from src\.

.DESCRIPTION
  A CC computer gets `computer_space_limit` bytes, which is 1,000,000 by
  default and is not something you can raise on somebody else's server. This
  tree is 1.2 MB, of which about half is comments.

  The comments are for the repository, not the device. So the build strips every
  comment-only line to an empty one - one byte instead of sixty - and the tree
  fits with room to spare.

  ## The line numbers are the reason it is blanked and not deleted

  `apps/job/app.lua:207` in an error message is the most useful thing this
  system has ever produced in a world, and it is only useful while it matches
  the file somebody opens here. A build that deleted comment lines would shift
  every line after them and quietly make every stack trace point at the wrong
  code.

  ## Why there is a build at all

  `link-world.ps1` used to junction a world's computer straight at `src\`. That
  is the fastest loop there is and it put a 1.2 MB tree on a 1 MB disk: the
  machine drew perfectly and could not write a single file, so its log was empty
  and its saved desktop arrangement vanished on every reboot. Nothing errored.

  Junctioning at the build instead costs one command between editing and
  rebooting, and the machine is then subject to exactly the limit a real server
  would apply.

  ## Dotfiles at the destination are never touched

  The rule is the dot. Every file ICOS persists is a dotfile - `.node`,
  `.location`, `.nav`, `.mine`, `.log`, a job file - and every file it ships is
  not. So "replace everything that is not a dotfile" needs no list to maintain
  and cannot forget the state file somebody adds next month. That matters here
  because a junctioned computer keeps its state *in the build directory*.

.EXAMPLE
  .\tools\build.ps1
  .\tools\build.ps1 -MeasureOnly
#>
[CmdletBinding()]
param(
  [string]$Out,
  # Report the size the build would be, and write nothing. What `check.ps1`
  # calls, so the size rule lives in one file rather than in two that can drift.
  [switch]$MeasureOnly,
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo "src"
if (-not $Out) { $Out = Join-Path $repo "build" }

if (-not (Test-Path $src)) { throw "No src at $src" }

# The default `computer_space_limit`. Hard-coded rather than read from a world,
# because the number that matters is the one on a server you do not administer.
$limit = 1000000

# One function, so the measurement and the write cannot disagree about what the
# build is. They did: the measurement joined with LF and the write used
# `WriteAllLines`, which is CRLF on Windows - so `check.ps1` was reporting a tree
# 34 KB smaller than the one that would land on the disk.
#
# LF is also the right answer on its own terms. A CC computer counts bytes, and
# a carriage return per line across 22,000 lines is 22 KB of nothing.
function Get-Stripped([string]$path) {
  $lines = [System.IO.File]::ReadAllLines($path)
  $out = foreach ($line in $lines) {
    if ($line.TrimStart().StartsWith("--")) { "" } else { $line }
  }
  return ($out -join "`n") + "`n"
}

if ($MeasureOnly) {
  $size = 0
  foreach ($file in Get-ChildItem $src -Recurse -File -Force |
      Where-Object { -not $_.Name.StartsWith(".") }) {
    if ($file.Extension -eq ".lua") {
      $size += [System.Text.Encoding]::UTF8.GetByteCount((Get-Stripped $file.FullName))
    }
    else {
      $size += $file.Length
    }
  }
  return [pscustomobject]@{ Size = $size; Limit = $limit; Fits = $size -le $limit }
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null

# Out with the old code, keeping every dotfile - see the header. A junctioned
# computer's `.node` and `.log` live here.
Get-ChildItem $Out -Force | Where-Object { -not $_.Name.StartsWith(".") } | ForEach-Object {
  Remove-Item $_.FullName -Recurse -Force
}

# In with the new. Dotfiles in `src\` are leftovers from when a computer was
# junctioned there directly; they are this developer machine's, never the
# target's, so they are not copied.
Get-ChildItem $src -Force | Where-Object { -not $_.Name.StartsWith(".") } | ForEach-Object {
  Copy-Item $_.FullName -Destination $Out -Recurse -Force
}

$stripped = 0
Get-ChildItem $Out -Recurse -File -Filter *.lua | ForEach-Object {
  [System.IO.File]::WriteAllText($_.FullName, (Get-Stripped $_.FullName), [System.Text.UTF8Encoding]::new($false))
  $stripped++
}

# Measured after the write, not from a cached FileInfo - which is what an
# earlier version did, and it reported "saving 0 KB" while having just halved
# the tree.
$size = (Get-ChildItem $Out -Recurse -File -Force |
    Where-Object { -not $_.Name.StartsWith(".") } |
    Measure-Object -Property Length -Sum).Sum

if (-not $Quiet) {
  $colour = if ($size -gt $limit) { "Red" } else { "Green" }
  Write-Host ("Built {0} files - {1} KB of {2} KB" -f
    $stripped, [math]::Round($size / 1024), [math]::Round($limit / 1024)) -ForegroundColor $colour
}

if ($size -gt $limit) {
  # A throw rather than a warning. Over the limit means every machine in the
  # fleet silently stops being able to write - which showed up once as a turtle
  # that could not save its own position, a failure that says nothing about the
  # real cause and points at the file it happened to be writing.
  throw ("build is {0} bytes, over the {1} byte computer_space_limit" -f $size, $limit)
}

return [pscustomobject]@{ Path = $Out; Size = $size; Limit = $limit; Files = $stripped }
