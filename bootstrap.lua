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

local USER = "" -- fill in and commit if you like; never commit a token
local REPO = ""
local BRANCH = "main"
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

local headers = private
    and {
      ["Authorization"] = "Bearer " .. token,
      ["Accept"] = "application/vnd.github.raw",
      ["User-Agent"] = "cc-tweaked-updater",
    }
  or nil

local function urlFor(name)
  if private then
    return ("https://api.github.com/repos/%s/%s/contents/%s/%s?ref=%s"):format(
      user,
      repo,
      PATH,
      name,
      branch
    )
  end
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s/%s"):format(user, repo, branch, PATH, name)
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
grab("lib/config.lua")
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
