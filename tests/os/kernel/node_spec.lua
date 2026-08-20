--- Writing `.node`, which is the record every machine boots from.
---
--- `roles.roleOf` is deliberately forgiving on the way in: it maps every ICOS 1
--- name forward and falls back to `client` for anything it cannot place, because
--- a machine with an unreadable role should end up as the thing that holds no
--- authority. That is right for reading and dangerous for writing - it means
--- setup could store any string at all and the machine would still boot,
--- silently, as a client. Somebody who chose Server and got a client has no error
--- to read and no reason to look for one.
---
--- So these cases are mostly about refusals, and about what a second run of setup
--- is not allowed to destroy.

local expect = require("support.expect")
local it = require("support.spec").it
local node = require("os.kernel.node")
local roles = require("os.kernel.roles")

---------------------------------------------------------------------------
-- What may be written
---------------------------------------------------------------------------

it("the four operating systems may be written, and nothing else", function()
  for _, role in ipairs(node.writable()) do
    expect.truthy(node.valid(role), role .. " is bootable")
  end
  expect.equal(#node.writable(), 4, "four, matching boot.ROOTS")
end)

it("an ICOS 1 role still reads, but is not written any more", function()
  -- §13's migration keeps working: a machine set up before ICOS 2 boots
  -- correctly for as long as it is never set up again.
  expect.equal(roles.roleOf({ role = "miner" }), roles.TURTLE, "an old record still reads")

  -- But setup writes the new name, which is what lets `FROM_ROLE` shrink to
  -- migration entries instead of growing a second vocabulary.
  local record, why = node.apply({}, { role = "miner" })
  expect.falsy(record, "refused")
  expect.contains(why, "no operating system", "and says why")
end)

it("a role nothing can boot is refused at the moment it is chosen", function()
  local record, why = node.apply({}, { role = "sever" })
  expect.falsy(record, "refused")
  expect.contains(why, "sever", "naming what was asked for")

  -- The alternative is what makes this worth a check at all: `roles.roleOf`
  -- would have turned that typo into a client, and a base station that came up
  -- as a client is a fault with no error attached to it.
  expect.equal(roles.roleOf({ role = "sever" }), roles.CLIENT, "which is what reading does")
end)

it("a machine needs a name", function()
  local record, why = node.apply({}, { role = roles.SERVER, label = "   " })
  expect.falsy(record, "refused")
  expect.contains(why, "name", "and says so")
end)

it("a label is trimmed rather than stored with the spaces somebody typed", function()
  local record = node.apply({}, { role = roles.CLIENT, label = "  wall  " })
  expect.equal(assert(record, "accepted").label, "wall", "trimmed")
end)

---------------------------------------------------------------------------
-- What a second run must not destroy
---------------------------------------------------------------------------

it("re-running setup to change a label keeps the job and the preferences", function()
  local existing = { role = "turtle", label = "miner-3", job = "rare", autoUpdate = false }
  local record = assert(node.apply(existing, { label = "miner-three" }), "accepted")

  expect.equal(record.label, "miner-three", "the answer given")
  expect.equal(record.job, "rare", "the job it was running")
  expect.equal(record.autoUpdate, false, "and the preference somebody set")
  expect.equal(record.role, "turtle", "and its role")
end)

it("an unanswered field is left exactly as it was", function()
  local record = assert(node.apply({ job = "quarry" }, {}), "accepted")

  -- Every answer is optional, which is what makes one function serve both the
  -- first run and every run after it.
  expect.equal(record.job, "quarry", "untouched")
end)

it("being set up clears a park from whatever it was doing before", function()
  local existing = {
    role = "turtle",
    job = "rare",
    parked = true,
    parkKind = "error",
    parkReason = "depot full",
  }
  local record = assert(node.apply(existing, { job = "quarry" }), "accepted")

  -- A turtle that comes back up still parked for a reason that applied to a job
  -- it no longer has is a turtle somebody has to go and look at.
  expect.falsy(record.parked, "not parked")
  expect.falsy(record.parkKind, "and no stale kind")
  expect.falsy(record.parkReason, "and no stale reason")
end)

it("changing nothing but the label leaves a parked turtle parked", function()
  local existing = { role = "turtle", parked = true, parkKind = "fuel" }
  local record = assert(node.apply(existing, { label = "miner-4" }), "accepted")

  -- The clear is tied to a role or job change, not to running setup. A turtle
  -- parked for fuel is still parked for fuel after somebody renames it, and
  -- pretending otherwise would deploy it into the same wall.
  expect.truthy(record.parked, "still parked")
  expect.equal(record.parkKind, "fuel", "for the same reason")
end)

---------------------------------------------------------------------------
-- Jobs
---------------------------------------------------------------------------

it("a job that no longer exists becomes the default rather than a dead record", function()
  local record = assert(node.apply({}, { role = roles.TURTLE, job = "expedition" }), "accepted")

  -- `expedition` was renamed to `rare`, and `jobs.resolve` is the one place that
  -- knows. A turtle whose job cannot be resolved gets the default, because the
  -- alternative is a turtle that will not start - and one that will not start is
  -- one somebody has to walk to.
  expect.equal(record.job, "rare", "renamed forward")
end)

it("only a turtle is offered a job", function()
  local caps = { dig = true, place = true, fuel = true, modem = true, chunky = true }

  expect.truthy(#node.jobs(roles.TURTLE, caps) > 0, "a turtle has jobs")
  expect.equal(#node.jobs(roles.SERVER, caps), 0, "a server has services instead")
  expect.equal(#node.jobs(roles.CLIENT, caps), 0, "and a client has pages")
end)

it("the jobs offered are the ones this machine can actually run", function()
  local miner = { dig = true, place = true, fuel = true, modem = true }
  for _, entry in ipairs(node.jobs(roles.TURTLE, miner)) do
    -- No chunk loader, so no general. Somebody who cannot select a thing does
    -- not need to know it exists; a menu of five with three refusals reads as a
    -- broken turtle rather than as a turtle with no upgrade.
    expect.truthy(entry.id ~= "general", "nothing it cannot hold")
  end
end)

---------------------------------------------------------------------------
-- The menu
---------------------------------------------------------------------------

it("a turtle is offered every role it can actually be", function()
  local caps = { turtle = true, modem = true, wireless = true, located = true, chunkLoaded = false }
  local offered = node.choices(caps)

  local byKey = {}
  for _, entry in ipairs(offered) do
    byKey[entry.key] = entry
  end

  expect.truthy(byKey[roles.TURTLE], "it can be a turtle")
  expect.truthy(byKey[roles.SERVER], "and a chunk-loaded one can be a server (D022)")
  expect.contains(byKey[roles.SERVER].warn, "Chunky", "warned about the chunk it must keep loaded")

  -- And a client, which is what a GPS-only turtle is. A constellation needs
  -- four hosts; making somebody pick Server for each would put four fleet
  -- authorities in the world to get four beacons.
  expect.truthy(byKey[roles.CLIENT], "and a client, which is a turtle that only hosts GPS")
  expect.contains(byKey[roles.CLIENT].warn, "never moves", "and told what that means")
end)

it("a computer with no modem is offered the server role, and told what it needs", function()
  local caps = { modem = false }
  local byKey = {}
  for _, entry in ipairs(node.choices(caps)) do
    byKey[entry.key] = entry
  end

  -- Offered rather than hidden. Setup is where somebody is standing at the
  -- machine and can be told what to attach; hiding the role until they have
  -- would leave them with no way to discover it was what they wanted.
  expect.truthy(byKey[roles.SERVER], "still offered")
  expect.contains(byKey[roles.SERVER].warn, "modem", "with the thing to fix")
end)

it("a suggested name is one a fleet of ten can tell apart", function()
  expect.equal(node.suggestLabel(roles.SERVER, 3), "base", "there is only one base")
  expect.equal(node.suggestLabel(roles.MOBILE, 3), "handheld", "and one handheld")
  expect.equal(node.suggestLabel(roles.TURTLE, 7), "turtle-7", "but ten turtles need numbers")
end)
