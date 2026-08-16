--- update.lua - pull the latest code from GitHub onto this computer.
---
--- This is the deploy step for server play, where you cannot reach the
--- computer's files from your PC. Workflow:
---
---   edit in VS Code  ->  git push  ->  run `update` in game
---
--- Requires the HTTP API, which CC: Tweaked enables by default. If your server
--- admin disabled it you will get "HTTP is disabled" and will need to ask them
--- to set http.enabled = true in computercraft-server.toml.

local config = require("lib.config")

local CONFIG_PATH = ".update"

local defaults = {
  user = "", -- your GitHub username
  repo = "", -- the repository name
  branch = "main",
  path = "src", -- folder inside the repo holding these programs
}

local cfg = config.load(CONFIG_PATH, defaults)

if cfg.user == "" or cfg.repo == "" then
  print("First run - where does your code live?\n")
  write("GitHub username: ")
  cfg.user = read()
  write("Repository name: ")
  cfg.repo = read()
  write("Branch [main]: ")
  local branch = read()
  if branch ~= "" then
    cfg.branch = branch
  end
  config.save(CONFIG_PATH, cfg)
  print("")
end

local base = ("https://raw.githubusercontent.com/%s/%s/%s/%s/"):format(
  cfg.user,
  cfg.repo,
  cfg.branch,
  cfg.path
)

--- Fetch a URL as a string. Returns nil plus a message on failure.
--- The timestamp defeats GitHub's CDN cache, which otherwise serves stale
--- files for a few minutes after you push.
local function fetch(name)
  local url = base .. name .. "?t=" .. tostring(os.epoch("utc"))
  local response, err = http.get(url)
  if not response then
    return nil, err or "no response"
  end
  local body = response.readAll()
  response.close()
  return body
end

--- Read a local file, or nil if it does not exist.
local function readLocal(path)
  if not fs.exists(path) then
    return nil
  end
  local handle = fs.open(path, "r")
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
  handle.write(body)
  handle.close()
end

print("Updating from " .. cfg.user .. "/" .. cfg.repo .. " (" .. cfg.branch .. ")")

local manifestBody, err = fetch("manifest.json")
if not manifestBody then
  printError("Could not fetch manifest.json: " .. tostring(err))
  printError("Check the username, repo, and branch in " .. CONFIG_PATH)
  return
end

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
  print("Reboot (or run `startup`) to use the new code.")
end
