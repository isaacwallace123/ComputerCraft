--- What a turtle knows about itself, and what it tells the fleet.
---
--- The ICOS 2 replacement for `legacy/miner/context.lua`, and the last thing
--- standing between `os/turtle/engine.lua` and deleting `legacy/miner/`
--- entirely. `os/turtle/runner.lua` already replaced the loop; this replaces the
--- state the loop runs on.
---
--- ## Three jobs, and they were one object before
---
--- ICOS 1's context was the node record, the control flags, the job selector,
--- the snapshot builder, the status line *and* the screen. Everything on a
--- turtle held a reference to it, so nothing on a turtle could be tested.
---
--- Here the loop is `runner.lua`, the decisions are `domain/turtle/lifecycle.lua`
--- and `domain/turtle/jobs.lua`, and what is left is this: a record, a job, and
--- the function that turns both into a heartbeat.
---
--- ## The snapshot is a wire format
---
--- Every field below is read by something that is not on this turtle -
--- `legacy/fleet/roster.lua`, `domain/fleet/registry.lua`, the Devices page, the
--- ICOS 1 console. Renaming one is a protocol change, not a refactor, so the
--- shape is reproduced exactly rather than tidied. `role` still says `miner`
--- for the same reason: ICOS 1's roster keys off it, and during a rolling update
--- the base reading this may be an ICOS 1 base.
---
--- ## It draws nothing
---
--- `Context:draw` was the other half of the old file and it is not here. A
--- context that owned a screen is why `report` could not be called from a spec,
--- and drawing is the shell's job (`os/client/shell.lua`) on every other
--- machine in the fleet. The status is stored; something else decides whether
--- anybody can see it.

local fuel = require("os.turtle.device.fuel")
local jobs = require("domain.turtle.jobs")
local machine = require("adapters.cc.machine")
local nav = require("os.turtle.device.nav")
local peers = require("os.turtle.device.peers")
local version = require("lib.version")

local context = {}

--- The role this turtle reports.
---
--- `miner`, still, and deliberately. ICOS 1's roster and its Fleet page both key
--- off this string, and `os/kernel/roles.lua` maps it to `turtle` on the way in
--- (D036). Reporting `turtle` here would make an upgraded machine disappear from
--- an un-upgraded base's roster - the same failure `os/turtle/legacy.lua` exists
--- to prevent, arriving through a field instead of a protocol.
---
--- It changes when `legacy/` is deleted, and not before.
context.REPORTED_ROLE = "miner"

local Context = {}
Context.__index = Context

--- Build a turtle's context.
---
--- `node` and `flags` are shared by reference with `os/turtle/control.lua` and
--- `os/turtle/runner.lua`. A copy would mean a recall that set a flag nothing
--- was reading.
function context.new(options)
  options = options or {}

  local self = setmetatable({}, Context)
  self.node = options.node or {}
  self.flags = options.flags or {}
  self.status = { phase = "idle", detail = "" }
  self.worldPos = nil
  self.saveNode = options.saveNode or function() end

  local entry = options.entry or jobs.resolve(self.node.job)
  self.entry = entry
  self.module = options.module or require(entry.module)
  self.job = self.module.load()

  return self
end

--- Note what the turtle is doing, for the heartbeat and the screen.
---
--- Stored rather than drawn. Every job calls this on every cell, so a version
--- that painted would make the cost of reporting a function of how much screen
--- there is - and would make a job untestable without one.
function Context:report(phase, detail)
  self.status.phase = phase or self.status.phase
  self.status.detail = detail or ""
  return self.status
end

--- Switch to another job, saving the choice.
---
--- Through the catalogue, so a name that no longer exists becomes the default
--- rather than a crash at the moment somebody assigns it. Returns the entry so a
--- caller can report what it actually got, which is not always what it asked
--- for.
function Context:selectJob(name)
  local entry = jobs.resolve(name)
  self.entry = entry
  self.module = require(entry.module)
  self.job = self.module.load()
  self.node.job = entry.id
  self.saveNode(self.node)
  return entry
end

--- Everything the fleet is told about this turtle.
---
--- A wire format. See the header: renaming a field here is a protocol change.
function Context:snapshot()
  local x, y, z, facing = nav.position()
  local stats = nav.stats()
  local fuelState = fuel.snapshot()
  local status = self.module.status(self.job)

  local world = (nav.hasOrigin() and nav.worldPosition()) or self.worldPos
  self.worldPos = world

  local required = self.module.minimumFuel and self.module.minimumFuel(self.job)
    or (self.module.estimateFuel and self.module.estimateFuel(self.job) or nil)

  local progress = status.progress
  if self.node.parked then
    if self.node.parkKind == "complete" then
      progress = 1
    elseif status.standing then
      -- A parked turtle is not part-way along a route, so a job whose progress
      -- tracks the route phase has to report something else while it waits.
      -- Without this every recalled turtle sits at the home phase's 95% for as
      -- long as it is parked, which is indistinguishable from one that is
      -- genuinely stuck on its way back.
      progress = status.standing
    end
  end

  return {
    label = os.getComputerLabel() or ("turtle-" .. os.getComputerID()),
    version = version,
    role = context.REPORTED_ROLE,
    job = self.entry.id,
    phase = self.status.phase,
    detail = self.status.detail,
    parked = self.node.parked,
    parkKind = self.node.parkKind,
    x = x,
    y = y,
    z = z,
    facing = facing,
    -- Refreshed every heartbeat. A thirty-second-old position is actively
    -- harmful to peer avoidance, because it makes a moving turtle look parked
    -- in a block it has already left.
    world = world,
    -- `math.huge` does not survive rednet serialisation cleanly; -1 means an
    -- unlimited-fuel world.
    fuel = fuelState.available == math.huge and -1 or fuelState.available,
    fuelTank = fuelState.level == math.huge and -1 or fuelState.level,
    fuelReserve = fuelState.reserve,
    fuelFraction = fuelState.fraction,
    fuelRequired = required,
    distanceHome = nav.distanceHome(),
    moves = stats.moves,
    digs = stats.digs,
    delivered = status.delivered,
    haul = status.haul,
    progress = progress,
    settings = status.settings,
    settingFields = self.module.settingFields,
    startedAt = self.job.startedAt,
    -- Shared-mine telemetry, optional on readers: a job with no concept of
    -- sectors simply omits it.
    sector = status.sector,
    workKey = status.workKey,
    peers = peers.count(),
    -- A chunk loader is a peripheral, so unlike a pickaxe it can be observed
    -- rather than assumed. Reported so the base can offer this turtle the
    -- `general` job without anybody walking over to look.
    chunky = machine.capabilities().chunkLoaded,
    -- Every shared-mine job refuses to deploy without a known position, so a
    -- fleet-wide order silently skips a turtle that has never been given one.
    -- Reported so the base can name them rather than the operator opening each
    -- turtle in turn.
    located = nav.hasOrigin(),
  }
end

return context
