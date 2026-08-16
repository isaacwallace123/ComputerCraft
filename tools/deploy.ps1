<#
.SYNOPSIS
  Regenerate the manifest, run checks, commit, and push.

.DESCRIPTION
  The whole PC-side deploy step in one command. After this, run `update` on any
  in-game machine to pull the new code.

.EXAMPLE
  .\tools\deploy.ps1 -Message "smarter fuel margin"
  .\tools\deploy.ps1 -Message "wip" -SkipChecks
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Message,
  [switch]$SkipChecks
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo

try {
  & "$PSScriptRoot\make-manifest.ps1" | Out-Null
  Write-Host "Manifest regenerated." -ForegroundColor Green

  if (-not $SkipChecks) {
    & "$PSScriptRoot\check.ps1"
    if ($LASTEXITCODE -ne 0) {
      throw "Checks failed. Fix them, or re-run with -SkipChecks."
    }
  }

  git add -A
  $staged = git diff --cached --name-only
  if (-not $staged) {
    Write-Host "Nothing to commit." -ForegroundColor Yellow
    return
  }

  git commit -q -m $Message
  Write-Host "Committed: $Message" -ForegroundColor Green

  $remote = git remote
  if (-not $remote) {
    Write-Host ""
    Write-Warning "No git remote set. Add one, then push:"
    Write-Host "  git remote add origin https://github.com/USER/REPO.git"
    Write-Host "  git push -u origin master"
    return
  }

  git push
  Write-Host ""
  Write-Host "Pushed. Now run `update` on any in-game machine." -ForegroundColor Cyan
}
finally {
  Pop-Location
}
