--- bootstrap.lua - one-shot installer for a brand new computer.
---
--- PUBLIC repo: run this on a fresh in-game computer.
---
---   wget run https://raw.githubusercontent.com/USER/REPO/main/bootstrap.lua
---
--- PRIVATE repo: `wget` cannot send an Authorization header, so it can't fetch
--- this file from a private repo. Two ways round it:
---   1. Run tools\print-bootstrap.ps1 on your PC. It copies a single line to
---      your clipboard; paste it into the in-game `lua` prompt with Ctrl+V.
---   2. Put ONLY this file in a secret Gist and `wget run` that. It will prompt
---      for a token and pull everything else from the private repo.
---
--- Either way it grabs the two files needed to self-update, then hands off to
--- update.lua which pulls everything in src/manifest.json.

local USER = "isaacwallace123" -- safe to commit; never commit a token
local REPO = "ComputerCraft"
local BRANCH = "master"
local PATH = "src"

local user, repo, branch = USER, REPO, BRANCH

if user == "" or repo == "" then
  write("GitHub username: ")
  user = read() or ""
  write("Repository name: ")
  repo = read() or ""
end

write("Access token (blank if the repo is public): ")
local token = read("*") or ""
local private = token ~= ""

local headers = { ["User-Agent"] = "cc-tweaked-updater" }
if private then
  headers["Authorization"] = "Bearer " .. token
  headers["Accept"] = "application/vnd.github.raw"
end

--- Resolve the branch to a commit SHA. raw.githubusercontent caches hard and
--- cannot be busted - neither a ?t= query string nor Cache-Control: no-cache
--- works, both measured serving stale files minutes after a push. A SHA in the
--- path is immutable, so it is always exactly what was pushed.
local ref = branch
do
  local url = ("https://api.github.com/repos/%s/%s/branches/%s"):format(user, repo, branch)
  local response = http.get(url, headers)
  if response then
    local data = textutils.unserialiseJSON((response.readAll():gsub("^\239\187\191", "")))
    response.close()
    if data and data.commit and type(data.commit.sha) == "string" then
      ref = data.commit.sha
    end
  end
end

local function urlFor(name)
  if private then
    return ("https://api.github.com/repos/%s/%s/contents/%s/%s?ref=%s"):format(
      user,
      repo,
      PATH,
      name,
      ref
    )
  end
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s/%s"):format(user, repo, ref, PATH, name)
end

local function grab(name)
  local response, err = http.get(urlFor(name), headers)
  if not response then
    printError("Failed to download " .. name .. ": " .. tostring(err))
    error("bootstrap aborted", 0)
  end
  local dir = fs.getDir(name)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local handle = fs.open(name, "w")
  if not handle then
    error("could not write " .. name, 0)
  end
  handle.write(response.readAll())
  handle.close()
  response.close()
  print("  got " .. name)
end

print("\nBootstrapping from " .. user .. "/" .. repo)
grab("core/config.lua")
grab("update.lua")

-- Seed update.lua's config so it does not ask again.
local handle = fs.open(".update", "w")
if not handle then
  error("could not write .update", 0)
end
handle.write(
  textutils.serialise({ user = user, repo = repo, branch = branch, path = PATH, token = token })
)
handle.close()

print("\nRunning update...\n")
shell.run("update.lua")
