--- What a machine should delete before installing a new build.
---
--- Pure: it is handed the new build's file list and what is on disk, and it
--- answers which paths should go. No filesystem, because deciding what to delete
--- and deleting it are different jobs and only one of them can be a spec.
---
--- ## Why an updater has to delete anything
---
--- `update.lua` used to write the new tree and never remove the old one. On a
--- machine with a 1,000,000 byte disk that is not untidiness, it is a failed
--- update: the D039 restructure moved almost every file, so a live ICOS 1
--- machine updating to a current build would hold `core/`, `fleet/`, `miner/`,
--- `mine/`, `jobs/` and `turtle/` **plus** the 550 KB it just downloaded. That
--- does not fit. The download fills the disk part-way through and leaves a
--- machine that boots into half a tree.
---
--- ## The safety boundary is a list of names, and it is closed
---
--- Only directories ICOS has shipped are ever considered. A program somebody
--- wrote on the computer is never at risk, and neither is anything beginning
--- with a dot - which is every file ICOS persists.
---
--- `RETIRED` names the directories no current build ships. It is closed rather
--- than maintained: the past does not gain new entries. Directories a *current*
--- build ships are derived from the file list itself, so a directory that is
--- added and later removed is handled without anybody coming back here.

local prune = {}

--- Top-level directories ICOS has shipped and no longer does.
---
--- Every one of these was real. `core/` was the shared library before D039
--- dismantled it; `fleet/`, `miner/`, `mine/`, `jobs/` and `turtle/` were ICOS
--- 1's tree; `legacy/` held ICOS 1 during the migration; `device/` and `shell/`
--- were intermediate homes that lasted a few commits each.
prune.RETIRED = {
  "core",
  "device",
  "fleet",
  "jobs",
  "legacy",
  "mine",
  "miner",
  "shell",
  "turtle",
}

--- Top-level directories a current build ships.
---
--- Derived from the file list wherever there is one - see `roots` - and named
--- here for the one caller that has no file list to derive from: `uninstall`,
--- which has to know what to remove without asking GitHub what a build looks
--- like. `tools/check.ps1` compares this against the manifest, so a new
--- top-level directory is a failed check rather than a directory uninstall
--- silently leaves behind.
prune.SHIPPED = {
  "adapters",
  "apps",
  "commands",
  "domain",
  "lib",
  "os",
  "ports",
  "ui",
}

--- Root files a current build ships.
---
--- `manifest.json` is not among them: `update.lua` fetches it and reads it
--- without ever writing it down, so there is nothing on disk to remove.
prune.SHIPPED_FILES = { "startup.lua", "icos.lua", "update.lua" }

--- Root files ICOS has shipped and no longer does.
---
--- `install.lua` was ICOS 1's setup program and `icos2.lua` was the launcher
--- before it was renamed to `icos`. A machine that keeps both has two ways to
--- start the wrong thing, and the one somebody types is the one they remember.
prune.RETIRED_FILES = { "install.lua", "icos2.lua", "boot.lua" }

--- Every top-level directory worth walking, given the build's file list.
---
--- The union of what this build ships and what ICOS has retired. Returned as a
--- sorted list rather than a set so a caller walks them in a fixed order and two
--- runs report the same thing.
function prune.roots(files)
  local roots = {}
  for _, name in ipairs(files or {}) do
    local top = name:match("^([^/]+)/")
    if top then
      roots[top] = true
    end
  end
  for _, name in ipairs(prune.RETIRED) do
    roots[name] = true
  end

  local out = {}
  for name in pairs(roots) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- Is this a path ICOS persists rather than ships?
---
--- The rule is the dot, at any depth. Every file ICOS writes at runtime is a
--- dotfile - `.node`, `.location`, `.nav`, `.mine`, `.log`, a job file - and
--- every file it ships is not, so "keep anything with a dot segment" needs no
--- list to maintain and cannot forget the state file somebody adds next month.
function prune.persisted(path)
  if type(path) ~= "string" then
    return false
  end
  if path:sub(1, 1) == "." then
    return true
  end
  return path:find("/%.") ~= nil
end

--- Everything ICOS owns, whether or not a build still ships it.
---
--- What `uninstall` walks. `roots` answers "where should I look for strays given
--- this build"; this answers "where has ICOS ever put anything", and the
--- difference is that one of them is being handed a build and the other is
--- taking one away.
function prune.owned()
  local out = {}
  for _, name in ipairs(prune.SHIPPED) do
    out[#out + 1] = name
  end
  for _, name in ipairs(prune.RETIRED) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- Every root file ICOS has ever shipped.
function prune.ownedFiles()
  local out = {}
  for _, name in ipairs(prune.SHIPPED_FILES) do
    out[#out + 1] = name
  end
  for _, name in ipairs(prune.RETIRED_FILES) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- Which of the paths on disk this build does not have.
---
--- `onDisk` is whatever the caller found by walking `roots`, plus any retired
--- root files that exist. Anything outside that was never a candidate, which is
--- what makes this safe to act on without a second opinion.
function prune.stale(files, onDisk)
  local wanted = {}
  for _, name in ipairs(files or {}) do
    wanted[name] = true
  end

  local out = {}
  for _, path in ipairs(onDisk or {}) do
    if not wanted[path] and not prune.persisted(path) then
      out[#out + 1] = path
    end
  end
  table.sort(out)
  return out
end

return prune
