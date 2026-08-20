--- What an update deletes, and everything it must not.
---
--- This is the only module in the tree whose job is to remove files, so it is
--- the one where a spec is not optional. Every case below is a thing that would
--- be discovered by finding it gone.

local expect = require("support.expect")
local it = require("support.spec").it

local prune = require("lib.prune")

--- The shape of a current build, reduced to what the module reads.
local BUILD = {
  "startup.lua",
  "icos.lua",
  "update.lua",
  "os/kernel/boot.lua",
  "apps/fleet/app.lua",
  "ui/theme.lua",
}

it("the directories walked are this build's plus the ones ICOS retired", function()
  local roots = prune.roots(BUILD)

  local set = {}
  for _, name in ipairs(roots) do
    set[name] = true
  end

  expect.truthy(set.os, "a directory this build ships")
  expect.truthy(set.apps)
  expect.truthy(set.ui)

  -- The reason the retired list exists: `core/` is in no current manifest, so
  -- nothing derived from the build would ever look inside it - and it is 300 KB
  -- of ICOS 1 sitting on a 1 MB disk.
  expect.truthy(set.core, "and one it does not")
  expect.truthy(set.legacy)

  -- A root file is not a directory, and walking one would be an error.
  expect.falsy(set["startup.lua"], "root files are not roots")
end)

it("nothing outside those directories is ever a candidate", function()
  -- A program somebody wrote on the computer. `roots` is the whole safety
  -- boundary: if a name is not in it, the caller never walks it and this module
  -- never sees the files inside it.
  local set = {}
  for _, name in ipairs(prune.roots(BUILD)) do
    set[name] = true
  end
  expect.falsy(set.myprograms)
  expect.falsy(set.rom)
  expect.falsy(set.disk)
end)

it("a file this build ships is kept", function()
  local stale = prune.stale(BUILD, { "os/kernel/boot.lua", "ui/theme.lua" })
  expect.equal(#stale, 0)
end)

it("a file from a build that moved is deleted", function()
  -- The case this module exists for. Every one of these was a real path in a
  -- build that is on machines in the world right now.
  local stale = prune.stale(BUILD, {
    "core/ui.lua",
    "miner/runtime.lua",
    "legacy/net.lua",
    "apps/fleet.lua",
    "os/kernel/boot.lua",
  })

  expect.equal(#stale, 4)
  expect.equal(
    stale[1],
    "apps/fleet.lua",
    "including one whose replacement is a directory of the same name"
  )
  expect.equal(stale[4], "miner/runtime.lua")
end)

it("state is never deleted, at any depth", function()
  -- The rule is the dot. Deleting one of these would cost a turtle its position,
  -- a base its mine, or the fleet its roster - none of which anything in the
  -- world re-reports.
  local stale = prune.stale(BUILD, {
    ".node",
    ".location",
    ".mine",
    "os/.leftover",
    "core/.something",
  })
  expect.equal(#stale, 0)

  expect.truthy(prune.persisted(".log"))
  expect.truthy(prune.persisted("apps/.cache"), "a dot anywhere in the path")
  expect.falsy(prune.persisted("apps/fleet/app.lua"))
  expect.falsy(prune.persisted(nil), "and nothing that is not a path")
end)

it("an empty build list does not become permission to delete everything", function()
  -- A manifest that failed to parse, or a fetch that came back empty. The
  -- caller checks for that before getting here, and this is the second answer:
  -- with no build to compare against, everything on disk looks unwanted, so the
  -- guard has to be that nothing is a candidate unless a root said so.
  expect.equal(#prune.stale({}, {}), 0)
  expect.equal(#prune.stale(nil, nil), 0)
end)

it("the retired file list catches a launcher that was renamed", function()
  -- `icos2` became `icos`. Both on disk means two commands, and the one somebody
  -- types is the one they remember rather than the one that works.
  local set = {}
  for _, name in ipairs(prune.RETIRED_FILES) do
    set[name] = true
  end
  expect.truthy(set["icos2.lua"])
  expect.truthy(set["install.lua"], "ICOS 1's setup program")
end)
