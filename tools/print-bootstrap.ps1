<#
.SYNOPSIS
  Generates a single-line install command for a PRIVATE repo and copies it to
  your clipboard.

.DESCRIPTION
  `wget run` cannot send an Authorization header, so it cannot fetch anything
  from a private repo. This produces a one-liner you paste into the in-game
  `lua` prompt instead (CC: Tweaked supports Ctrl+V in the terminal).

  It downloads lib/config.lua and update.lua, writes .update with your details,
  then runs the updater to pull everything else.

  For a PUBLIC repo you do not need this - just use:
    wget run https://raw.githubusercontent.com/USER/REPO/main/bootstrap.lua

.EXAMPLE
  .\tools\print-bootstrap.ps1 -User me -Repo ComputerCraft -Token github_pat_xxx
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$User,
  [Parameter(Mandatory)][string]$Repo,
  [string]$Branch = "main",
  [string]$Path = "src",
  [Parameter(Mandatory)][string]$Token
)

$ErrorActionPreference = "Stop"

$lua = @'
local u,r,b,p,t="__USER__","__REPO__","__BRANCH__","__PATH__","__TOKEN__" local h={Authorization="Bearer "..t,Accept="application/vnd.github.raw",["User-Agent"]="cc"} local function g(n) local x,e=http.get(("https://api.github.com/repos/%s/%s/contents/%s/%s?ref=%s"):format(u,r,p,n,b),h) if not x then error(n..": "..tostring(e),0) end local d=fs.getDir(n) if d~="" and not fs.exists(d) then fs.makeDir(d) end local f=fs.open(n,"w") f.write(x.readAll()) f.close() x.close() print("got "..n) end g("adapters/cc/config.lua") g("legacy/shell/ui.lua") g("legacy/sound.lua") g("update.lua") local f=fs.open(".update","w") f.write(textutils.serialise({user=u,repo=r,branch=b,path=p,token=t})) f.close() if shell then shell.run("update.lua") else print("Now run: update") end
'@

$lua = $lua.Trim().
  Replace("__USER__", $User).
  Replace("__REPO__", $Repo).
  Replace("__BRANCH__", $Branch).
  Replace("__PATH__", $Path).
  Replace("__TOKEN__", $Token)

Set-Clipboard -Value $lua

Write-Host ""
Write-Host "Copied to clipboard ($($lua.Length) chars)." -ForegroundColor Green
Write-Host ""
Write-Host "In game:" -ForegroundColor Cyan
Write-Host "  1. Right-click the computer"
Write-Host "  2. Type:  lua"
Write-Host "  3. Press Ctrl+V, then Enter"
Write-Host "  4. Type:  exit     then reboot with Ctrl+R"
Write-Host ""
Write-Warning "This line contains your access token in plain text. Do not stream, screenshot, or paste it in chat."
