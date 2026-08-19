--- Pull the latest code from GitHub onto this machine.
---
---   edit in VS Code  ->  git push  ->  run `update` in game
---
--- Runs in two passes. The first downloads anything whose content differs from
--- what is on disk. The second re-reads every file back OFF the disk and checks
--- its checksum against what was actually fetched - so "updated" means the
--- bytes are really there, not merely that a write call returned.

package.path = "/?.lua;/?/init.lua;" .. package.path

local console = require("os.kernel.console")
local config = require("adapters.cc.config")

local CONFIG_PATH = ".update"
local RESULT_PATH = ".update-result"
local rebootAfter = false
for _, argument in ipairs({ ... }) do
  if argument == "--reboot" then
    rebootAfter = true
  end
end

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
-- repository with Contents: Read-only and an expiry date.

-- Prompt on the first run only, keyed on the file existing rather than on the
-- fields being blank, so the baked-in defaults can still be overridden - and so
-- a private repo gets asked for its token.
local firstRun = not fs.exists(CONFIG_PATH)
local cfg = config.load(CONFIG_PATH, defaults)
config.save(RESULT_PATH, { ok = false, message = "update interrupted" })

if firstRun then
  term.clear()
  term.setCursorPos(1, 1)
  print("Update source - enter to accept each default.\n")

  local function ask(prompt, current)
    write(prompt .. " [" .. current .. "]: ")
    local answer = (read() or ""):gsub("^%s*(.-)%s*$", "%1")
    return answer ~= "" and answer or current
  end

  cfg.user = ask("GitHub username", cfg.user)
  cfg.repo = ask("Repository", cfg.repo)
  cfg.branch = ask("Branch", cfg.branch)
  write("Access token (blank if public): ")
  cfg.token = read("*") or ""

  config.save(CONFIG_PATH, cfg)
end

local private = cfg.token ~= ""

--- GitHub's API rejects requests without a User-Agent, and needs the token when
--- the repo is private. vnd.github.raw makes the contents endpoint return the
--- plain file rather than JSON with base64 content - CC has no base64 decoder.
local headers = { ["User-Agent"] = "icos-updater" }
if private then
  headers["Authorization"] = "Bearer " .. cfg.token
  headers["Accept"] = "application/vnd.github.raw"
end

local function get(url)
  local response, err, failed = http.get(url, headers)
  if not response then
    local code = failed and failed.getResponseCode()
    if code == 401 then
      err = "401 token rejected"
    elseif code == 404 then
      err = "404 not found"
    end
    return nil, err or "no response"
  end
  local body = response.readAll()
  response.close()
  return body
end

--- djb2, folded to 32 bits. Not cryptographic - it only has to catch a
--- truncated or partially written file, which it does.
local function checksum(text)
  local hash = 5381
  for i = 1, #text do
    hash = (hash * 33 + text:byte(i)) % 4294967296
  end
  return hash
end

--- Hand-rolled hex. string.format("%x") throws on a float in later Lua
--- versions, and CC's numbers are all floats.
local DIGITS = "0123456789abcdef"
local function hex(value)
  local out = ""
  for _ = 1, 8 do
    local nibble = value % 16
    out = DIGITS:sub(nibble + 1, nibble + 1) .. out
    value = math.floor(value / 16)
  end
  return out
end

--- Resolve the branch to the commit it points at.
---
--- raw.githubusercontent caches hard and CANNOT be busted: a ?t= query string
--- is ignored and so is Cache-Control: no-cache, both measured serving stale
--- files minutes after a push. A commit SHA in the path is immutable, so it is
--- never stale - and every push makes a new SHA, which is a new URL.
local function resolveRef()
  local body =
    get(("https://api.github.com/repos/%s/%s/branches/%s"):format(cfg.user, cfg.repo, cfg.branch))
  if not body then
    return nil
  end
  local data = textutils.unserialiseJSON((body:gsub("^\239\187\191", "")))
  if data and data.commit and type(data.commit.sha) == "string" then
    return data.commit.sha
  end
  return nil
end

local function urlFor(ref, name)
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
    return false
  end
  handle.write(body)
  handle.close()
  return true
end

-- ---------------------------------------------------------------- interface

local SPINNER = { "|", "/", "-", "\\" }
local recent = {}
local frame = 0

local function remember(name, note, color)
  recent[#recent + 1] = { name = name, note = note, color = color }
  while #recent > 5 do
    table.remove(recent, 1)
  end
end

--- The screen, built once.
---
--- `os/kernel/console.lua` rather than the component tree, because an updater
--- that could not draw its own failure would be the worst possible thing to be
--- unable to draw - it runs at the moment the files it is drawing with are
--- being replaced.
local screen = console.new(require("adapters.cc.screen").new(term))
local T = console.TOKENS

--- Repaint the whole screen. Cheap enough to call per file, and redrawing
--- everything avoids the stale-artifact bugs that partial updates invite - the
--- buffer turns a full repaint into one blit per row that actually differs, so
--- "redraw everything" costs what "redraw what changed" used to.
local function draw(stage, done, total, current)
  local _, height = screen:size()
  frame = frame + 1

  screen:clear()
  screen:header("ICOS update", stage)
  screen:line(3, cfg.user .. "/" .. cfg.repo, T.mutedFg)
  screen:bar(5, done, total)

  local spin = done < total and SPINNER[(frame % #SPINNER) + 1] .. " " or "  "
  screen:line(6, spin .. (current or ""), T.foreground)

  local row = 8
  for _, entry in ipairs(recent) do
    if row >= height then
      break
    end
    screen:line(row, entry.name, entry.color)
    screen:right(row, entry.note, entry.color)
    row = row + 1
  end

  screen:present()
end

local function fail(message, detail)
  config.save(RESULT_PATH, { ok = false, message = message, detail = detail })

  screen:clear()
  screen:header("ICOS update", "failed")
  screen:line(3, message, T.destructive)
  if detail then
    screen:line(5, detail, T.mutedFg)
  end
  screen:present()

  -- The cursor goes below whatever was drawn, so anything printed after this -
  -- a stack trace, a shell prompt - does not land on top of the reason.
  local _, height = screen:size()
  term.setCursorPos(1, height - 1)
end

-- ------------------------------------------------------------------ run it

draw("resolving", 0, 1, "finding latest commit")

local ref = resolveRef()
local pinned = ref ~= nil
if not pinned then
  ref = cfg.branch
end

draw("manifest", 0, 1, "fetching file list")

local manifestBody, manifestErr = get(urlFor(ref, "manifest.json"))
if not manifestBody then
  fail("Could not fetch manifest.json", tostring(manifestErr))
  return
end

-- Editors and PowerShell both like to add a BOM, and unserialiseJSON refuses
-- anything before the opening brace.
local manifest = textutils.unserialiseJSON((manifestBody:gsub("^\239\187\191", "")))
if not manifest or type(manifest.files) ~= "table" then
  fail("manifest.json is malformed", "re-run tools\\make-manifest.ps1 and push")
  return
end

local files = manifest.files
local total = #files
local expected = {}
local changed, unchanged, failed = 0, 0, 0
local bytes = 0

for index, name in ipairs(files) do
  draw("downloading", index - 1, total, name)

  local body, err = get(urlFor(ref, name))
  if not body then
    remember(name, tostring(err):sub(1, 12), T.destructive)
    failed = failed + 1
  else
    bytes = bytes + #body
    expected[name] = checksum(body)

    if body == readLocal(name) then
      unchanged = unchanged + 1
    elseif writeLocal(name, body) then
      remember(name, "updated", T.good)
      changed = changed + 1
    else
      remember(name, "UNWRITABLE", T.destructive)
      failed = failed + 1
    end
  end
end

-- Verification: read every file back off the disk and check it against what we
-- actually received. This is the difference between "the write call returned"
-- and "the bytes are on disk", and it is the only pass that can catch a
-- truncated file, a full disk, or a file that never got written at all.
local verified, broken = 0, {}
local fingerprint = 5381

for index, name in ipairs(files) do
  draw("verifying", index - 1, total, name)

  local onDisk = readLocal(name)
  if not onDisk then
    broken[#broken + 1] = name .. " missing"
  elseif not expected[name] then
    broken[#broken + 1] = name .. " not fetched"
  elseif checksum(onDisk) ~= expected[name] then
    broken[#broken + 1] = name .. " checksum"
  else
    verified = verified + 1
    -- Fold every verified file into one value, in manifest order. Two machines
    -- showing the same fingerprint are provably running identical code, which
    -- is the question you actually have when one turtle misbehaves.
    fingerprint = (fingerprint * 33 + expected[name]) % 4294967296
  end
end

-- ----------------------------------------------------------------- summary

local ok = failed == 0 and #broken == 0
local _, height = screen:size()
config.save(RESULT_PATH, {
  ok = ok,
  message = ok and "update verified" or "update verification failed",
  changed = changed,
  unchanged = unchanged,
  failed = failed,
  commit = ref,
})

screen:clear()
screen:header("ICOS update", ok and "verified" or "PROBLEMS")

screen:line(3, cfg.user .. "/" .. cfg.repo, T.mutedFg)
screen:line(4, "commit  " .. tostring(ref):sub(1, 7) .. (pinned and "" or " (branch)"), T.mutedFg)

screen:line(6, ("%-10s %d"):format("updated", changed), changed > 0 and T.good or T.mutedFg)
screen:line(7, ("%-10s %d"):format("unchanged", unchanged), T.mutedFg)
screen:line(8, ("%-10s %d"):format("failed", failed), failed > 0 and T.destructive or T.mutedFg)

screen:line(
  10,
  ("%-10s %d/%d files, %dkB"):format("verified", verified, total, math.floor(bytes / 1024)),
  ok and T.good or T.destructive
)
screen:line(11, ("%-10s %s"):format("fingerprint", hex(fingerprint)), T.accent)

local row = 13
for _, problem in ipairs(broken) do
  if row >= height - 1 then
    break
  end
  screen:line(row, problem, T.destructive)
  row = row + 1
end

-- The last line says what to do next rather than what happened, because what
-- happened is the six lines above it and somebody reading a summary is deciding
-- whether they still have to do something.
local footer
if ok and rebootAfter then
  footer = "Update verified - rebooting"
elseif ok and changed > 0 then
  footer = "Updated - reboot to run the new code"
elseif ok then
  footer = "Already up to date"
else
  footer = "Update incomplete - see above"
end

screen:line(height, footer, ok and T.mutedFg or T.warn)
screen:present()

-- A tone, because an automatic update runs unattended and the thing somebody
-- wants to know from across the room is whether it worked.
require("adapters.cc.sound").play(ok and "confirm" or "error")

-- Sound is optional: a machine with no speaker just updates quietly, and a
-- missing module must never be able to break updating itself.
pcall(function()
  require("adapters.cc.sound").play(ok and "ready" or "error")
end)

if ok and rebootAfter then
  sleep(1)
  os.reboot()
end

term.setCursorPos(1, height)
