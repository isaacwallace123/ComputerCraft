--- bootstrap.lua - one-shot installer for a brand new computer.
---
--- PUBLIC repo: run this on a fresh in-game computer.
---
---   wget run https://raw.githubusercontent.com/isaacwallace123/ComputerCraft/master/bootstrap.lua
---
--- PRIVATE repo: `wget` cannot send an Authorization header, so it can't fetch
--- this file from a private repo. Two ways round it:
---   1. Run tools\print-bootstrap.ps1 on your PC. It copies a single line to
---      your clipboard; paste it into the in-game `lua` prompt with Ctrl+V.
---   2. Put ONLY this file in a secret Gist and `wget run` that. It will prompt
---      for a token and pull everything else from the private repo.
---
--- Either way it grabs the handful of files update.lua needs to run - named in
--- the manifest's `bootstrap` list rather than here - and hands off to
--- update.lua, which pulls everything in src/manifest.json and removes anything
--- the build no longer has.

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

local function fetch(name)
  local response, err = http.get(urlFor(name), headers)
  if not response then
    printError("Failed to download " .. name .. ": " .. tostring(err))
    error("bootstrap aborted", 0)
  end
  local body = response.readAll()
  response.close()
  return body
end

--- Fetch one file and write it, comments and all.
---
--- Unstripped on purpose. `update.lua` runs immediately after this and rewrites
--- every one of these files with the comment lines blanked, so doing it here
--- would be the same work twice. Ten files of source is under 100 KB, which fits
--- on any computer that has room for the tree that follows.
local function grab(name)
  local body = fetch(name)
  local dir = fs.getDir(name)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local handle = fs.open(name, "w")
  if not handle then
    error("could not write " .. name, 0)
  end
  handle.write(body)
  handle.close()
  print("  got " .. name)
end

--- The minimum update.lua needs to run and draw itself, read from the manifest.
---
--- Named there rather than here, and that is the whole point of this block. It
--- used to be four literal calls - `core/config.lua`, `core/ui.lua`,
--- `core/sound.lua`, `update.lua` - and the restructure that dismantled `core/`
--- deleted three of them.
---
--- Nothing caught it. Every check passed, every machine that already had ICOS
--- kept updating fine, and the only broken path was installing onto a **fresh**
--- computer: three 404s and an aborted bootstrap. That is the one path nobody
--- exercises until they are standing in front of a new server.
---
--- `tools\make-manifest.ps1` walks `update.lua`'s requires transitively and
--- writes the answer as `bootstrap`, so this list is derived from the tree it
--- describes and cannot be left behind by a move.
print("\nBootstrapping from " .. user .. "/" .. repo)

local manifest = textutils.unserialiseJSON((fetch("manifest.json"):gsub("^\239\187\191", "")))
if type(manifest) ~= "table" or type(manifest.bootstrap) ~= "table" then
  error("manifest.json has no bootstrap list - re-run tools\\make-manifest.ps1 and push", 0)
end

for _, name in ipairs(manifest.bootstrap) do
  grab(name)
end

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
