--- Pull the latest code from GitHub onto this machine.
---
--- This is the deploy step for server play, where you cannot reach a computer's
--- files from your PC:
---
---   edit in VS Code  ->  git push  ->  run `update` in game
---
--- Requires the HTTP API, which CC: Tweaked enables by default.

package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("core.config")

local CONFIG_PATH = ".update"

local defaults = {
  user = "isaacwallace123",
  repo = "ComputerCraft",
  branch = "master", -- this repo's default branch is master, not main
  path = "src", -- folder in the repo holding these programs
  token = "", -- only for a PRIVATE repo; see the warning below
}

-- SECURITY: the token is stored here in plain text. Anyone who can reach this
-- computer in game, plus the server admin, plus anyone with the world files,
-- can read it. Use a fine-grained personal access token scoped to this ONE
-- repository with Contents: Read-only and an expiry date. Never a classic
-- token, never one you use anywhere else.

-- Prompt on the first run only. Keyed on the file existing rather than on the
-- fields being blank, so the baked-in defaults above can still be confirmed or
-- overridden - and so a private repo gets asked for its token.
local firstRun = not fs.exists(CONFIG_PATH)
local cfg = config.load(CONFIG_PATH, defaults)

if firstRun then
  print("First run - press enter to accept each default.\n")
  write("GitHub username [" .. cfg.user .. "]: ")
  cfg.user = (read() or ""):gsub("^%s*(.-)%s*$", "%1")
  if cfg.user == "" then
    cfg.user = defaults.user
  end

  write("Repository [" .. cfg.repo .. "]: ")
  cfg.repo = (read() or ""):gsub("^%s*(.-)%s*$", "%1")
  if cfg.repo == "" then
    cfg.repo = defaults.repo
  end

  write("Branch [" .. cfg.branch .. "]: ")
  local branch = (read() or ""):gsub("^%s*(.-)%s*$", "%1")
  if branch ~= "" then
    cfg.branch = branch
  end

  write("Access token (blank if the repo is public): ")
  cfg.token = read("*") or ""

  config.save(CONFIG_PATH, cfg)
  print("")
end

local private = cfg.token ~= ""

--- GitHub's API rejects requests without a User-Agent, and needs the token when
--- the repo is private. vnd.github.raw makes the contents endpoint return the
--- plain file rather than JSON with base64 content - CC has no base64 decoder,
--- so that matters.
local headers = { ["User-Agent"] = "cc-tweaked-updater" }
if private then
  headers["Authorization"] = "Bearer " .. cfg.token
  headers["Accept"] = "application/vnd.github.raw"
end

local function get(url)
  local response, err, failed = http.get(url, headers)
  if not response then
    local code = failed and failed.getResponseCode()
    if code == 401 then
      err = "401 - token rejected (expired, or wrong permissions)"
    elseif code == 404 then
      err = "404 - not found (check repo/branch/path, or token lacks access)"
    end
    return nil, err or "no response"
  end
  local body = response.readAll()
  response.close()
  return body
end

--- Resolve the branch to the commit it currently points at.
---
--- This exists because raw.githubusercontent caches hard and CANNOT be busted:
--- a ?t= query string is ignored, and so is Cache-Control: no-cache. Both were
--- measured serving a stale file minutes after a push. A commit SHA in the path
--- is immutable, so it is never stale and never cached wrongly - and a new push
--- produces a new SHA, which is a new URL. One extra API call per update buys
--- correctness that no cache-busting trick can.
local function resolveRef()
  local url = ("https://api.github.com/repos/%s/%s/branches/%s"):format(
    cfg.user,
    cfg.repo,
    cfg.branch
  )
  local body = get(url)
  if not body then
    return nil
  end
  local data = textutils.unserialiseJSON((body:gsub("^\239\187\191", "")))
  if data and data.commit and type(data.commit.sha) == "string" then
    return data.commit.sha
  end
  return nil
end

print("Updating from " .. cfg.user .. "/" .. cfg.repo .. " (" .. cfg.branch .. ")")

local ref = resolveRef()
if not ref then
  print("Could not resolve " .. cfg.branch .. "; falling back to the branch name.")
  print("Files may be a few minutes out of date.")
  ref = cfg.branch
end

local function urlFor(name)
  if private then
    return ("https://api.github.com/repos/%s/%s/contents/%s/%s?ref=%s"):format(
      cfg.user,
      cfg.repo,
      cfg.path,
      name,
      ref
    )
  end
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s/%s"):format(
    cfg.user,
    cfg.repo,
    ref,
    cfg.path,
    name
  )
end

local function fetch(name)
  return get(urlFor(name))
end

local function readLocal(path)
  local handle = fs.exists(path) and fs.open(path, "r")
  if not handle then
    return nil
  end
  local body = handle.readAll()
  handle.close()
  return body
end

local function writeLocal(path, body)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local handle = fs.open(path, "w")
  if not handle then
    error("could not write " .. path, 0)
  end
  handle.write(body)
  handle.close()
end

print("At commit " .. tostring(ref):sub(1, 7))

local manifestBody, err = fetch("manifest.json")
if not manifestBody then
  printError("Could not fetch manifest.json: " .. tostring(err))
  printError("Check the username, repo, and branch in " .. CONFIG_PATH)
  return
end

-- Strip a UTF-8 byte order mark. Editors and PowerShell both like to add one,
-- and unserialiseJSON refuses anything before the opening brace.
manifestBody = manifestBody:gsub("^\239\187\191", "")

local manifest = textutils.unserialiseJSON(manifestBody)
if not manifest or type(manifest.files) ~= "table" then
  printError("manifest.json is malformed. Re-run tools\\make-manifest.ps1 and push.")
  return
end

local changed, unchanged, failed = 0, 0, 0

for _, name in ipairs(manifest.files) do
  local body, fetchErr = fetch(name)
  if not body then
    printError("  fail  " .. name .. " (" .. tostring(fetchErr) .. ")")
    failed = failed + 1
  elseif body == readLocal(name) then
    unchanged = unchanged + 1
  else
    writeLocal(name, body)
    print("  ok    " .. name)
    changed = changed + 1
  end
end

print("")
print(("%d updated, %d unchanged, %d failed"):format(changed, unchanged, failed))

if changed > 0 then
  print("Reboot (Ctrl+R) to run the new code.")
end
