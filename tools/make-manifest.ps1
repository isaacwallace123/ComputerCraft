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

$manifest = [ordered]@{
  generated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
  bootstrap = @($bootstrap)
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
$files | ForEach-Object { "  $_" }
Write-Host ""
Write-Host "Now: git add -A; git commit -m 'update'; git push" -ForegroundColor Cyan
