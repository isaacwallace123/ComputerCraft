--- bootstrap.lua - one-shot installer for a brand new computer.
---
--- On a fresh in-game computer, run this single line (substitute your details):
---
---   wget run https://raw.githubusercontent.com/USER/REPO/main/bootstrap.lua
---
--- It grabs the two files needed to self-update, then hands off to update.lua
--- which pulls everything else listed in src/manifest.json.

local USER = "" -- <- fill these in and commit, or you will be prompted
local REPO = ""
local BRANCH = "main"
local PATH = "src"

local user, repo, branch = USER, REPO, BRANCH

if user == "" or repo == "" then
  write("GitHub username: ")
  user = read()
  write("Repository name: ")
  repo = read()
end

local base = ("https://raw.githubusercontent.com/%s/%s/%s/%s/"):format(user, repo, branch, PATH)

local function grab(name)
  local response, err = http.get(base .. name .. "?t=" .. tostring(os.epoch("utc")))
  if not response then
    printError("Failed to download " .. name .. ": " .. tostring(err))
    error("bootstrap aborted", 0)
  end
  local dir = fs.getDir(name)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local handle = fs.open(name, "w")
  handle.write(response.readAll())
  handle.close()
  response.close()
  print("  got " .. name)
end

print("Bootstrapping from " .. user .. "/" .. repo)
grab("lib/config.lua")
grab("update.lua")

-- Seed update.lua's config so it does not ask again.
local handle = fs.open(".update", "w")
handle.write(textutils.serialise({ user = user, repo = repo, branch = branch, path = PATH }))
handle.close()

print("\nRunning update...\n")
shell.run("update.lua")
