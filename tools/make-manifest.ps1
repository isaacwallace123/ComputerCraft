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

# Everything `update.lua` needs in order to run at all.
#
# `bootstrap.lua` installs this set and nothing else, then hands over. It used to
# carry a hand-written list - `core/config.lua`, `core/ui.lua`, `core/sound.lua`
# - and the D039 restructure deleted all three. Nothing failed here, nothing
# failed in a check, and nothing failed on any machine that already had ICOS:
# the only thing that broke was installing onto a *fresh* computer, which is the
# one path nobody exercises until they need it on a server.
#
# So it is computed rather than remembered. Walk the requires out of `update.lua`
# transitively; whatever comes back is what bootstrap fetches, and it cannot go
# stale because it is derived from the same tree it describes.
function Get-Closure([string]$entry) {
  $seen = [System.Collections.Generic.HashSet[string]]::new()
  $queue = [System.Collections.Generic.Queue[string]]::new()
  $queue.Enqueue($entry)

  while ($queue.Count -gt 0) {
    $relative = $queue.Dequeue()
    if (-not $seen.Add($relative)) { continue }

    $path = Join-Path $src $relative
    if (-not (Test-Path $path)) {
      throw "$entry needs $relative, which does not exist"
    }
    foreach ($match in [regex]::Matches((Get-Content $path -Raw), 'require\("([\w\.]+)"\)')) {
      $queue.Enqueue($match.Groups[1].Value.Replace(".", "/") + ".lua")
    }
  }

  return @($seen | Sort-Object)
}

$bootstrap = Get-Closure "update.lua"

# What each kind of machine actually needs.
#
# A CC computer gets 1,000,000 bytes and the whole tree is about 554 KB of that.
# Most of it is code a given machine will never run: a client has no mine, no
# sector leases and no turtle jobs; a turtle has no console and no disk manager.
# Shipping it anyway is half the disk spent on files that exist to be skipped.
#
# So `update.lua` downloads the closure for its own role and deletes the rest.
# The four lists overlap heavily - the UI framework, the ports, the adapters -
# and that is fine: they are lists of what to fetch, not an attempt at modules.
#
# ## Three requires are dynamic, and all three are enumerable
#
# `require` with a literal is followed by the walk. Three places call it with a
# variable instead, and each reads from a table that names every possibility:
# `boot.ROOTS` (one composition root per role), `apps/registry.lua` (the apps)
# and `domain/turtle/jobs.lua` (the jobs). Those are seeded explicitly below,
# which is why this can be exact rather than "everything, to be safe".
function Get-Seeds([string]$role) {
  # Every machine runs the same three programs, whatever it is.
  $seeds = @("startup.lua", "icos.lua", "update.lua")

  # `boot.ROOTS` maps a role onto one composition root, by name.
  $seeds += "os/$role/main.lua"

  # The apps this role can show, from the registry that decides.
  $registry = Get-Content (Join-Path $src "apps/registry.lua") -Raw
  foreach ($match in [regex]::Matches($registry,
      '(?s)module\s*=\s*"([\w\.]+)",\s*roles\s*=\s*\{([^}]*)\}')) {
    $module = $match.Groups[1].Value
    $roles = [regex]::Matches($match.Groups[2].Value, '"(\w+)"') | ForEach-Object { $_.Groups[1].Value }
    if ($roles -contains $role) {
      $seeds += $module.Replace(".", "/") + ".lua"
    }
  }

  # A turtle picks its job at runtime from a catalogue of module names, so every
  # one of them has to be on the disk before it is asked for.
  if ($role -eq "turtle") {
    $jobs = Get-Content (Join-Path $src "domain/turtle/jobs.lua") -Raw
    foreach ($match in [regex]::Matches($jobs, 'module\s*=\s*"([\w\.]+)"')) {
      $seeds += $match.Groups[1].Value.Replace(".", "/") + ".lua"
    }
  }

  return $seeds
}

$roleFiles = [ordered]@{}
foreach ($role in @("server", "client", "turtle", "mobile")) {
  $closure = @()
  foreach ($seed in (Get-Seeds $role)) {
    $closure += Get-Closure $seed
  }
  $roleFiles[$role] = @($closure | Sort-Object -Unique)
}

$manifest = [ordered]@{
  generated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
  bootstrap = @($bootstrap)
  roles     = $roleFiles
  files     = @($files)
}

$out = Join-Path $src "manifest.json"
$json = $manifest | ConvertTo-Json -Depth 3

# NOT Set-Content -Encoding utf8: Windows PowerShell 5.1 writes a UTF-8 BOM,
# and a leading EF BB BF makes CC's textutils.unserialiseJSON reject the file.
# That fails as "manifest.json is malformed" on every machine, which looks like
# a bad push rather than an encoding problem.
[System.IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Wrote $out" -ForegroundColor Green
Write-Host ("  bootstrap: {0} files update.lua needs to run" -f $bootstrap.Count) -ForegroundColor Cyan
foreach ($role in $roleFiles.Keys) {
  Write-Host ("  {0,-7}   {1,3} of {2} files" -f $role, $roleFiles[$role].Count, $files.Count) -ForegroundColor Cyan
}
$files | ForEach-Object { "  $_" }
Write-Host ""
Write-Host "Now: git add -A; git commit -m 'update'; git push" -ForegroundColor Cyan
