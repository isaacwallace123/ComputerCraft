--- Shared miner state, job selection, telemetry, and local rendering.

local config = require("core.config")
local fuel = require("turtle.fuel")
local nav = require("turtle.nav")
local net = require("core.net")
local peers = require("turtle.peers")
local ui = require("core.ui")
local util = require("core.util")
local version = require("core.version")

local Context = {}
Context.__index = Context

local NODE_PATH = ".node"

local function chooseJob(jobs)
  local names, labels = {}, {}
  for name in pairs(jobs) do
    names[#names + 1] = name
  end
  table.sort(names)
  for index, name in ipairs(names) do
    labels[index] = jobs[name].label or name
  end
  local choice = ui.menu("Which job?", labels)
  return choice and names[choice] or names[1]
end

function Context.new(jobs)
  local self = setmetatable({}, Context)
  self.jobs = jobs
  self.node = config.load(NODE_PATH, {
    role = "miner",
    label = nil,
    job = nil,
    parked = false,
    parkKind = nil,
    parkReason = nil,
  })
  self.control = {
    recall = false,
    deploy = false,
    configure = false,
    changeJob = false,
    setJob = nil,
    settings = nil,
    update = nil,
  }
  self.status = { phase = "idle", detail = "" }
  self.baseId = nil
  self.worldPos = nil
  self.interactive = false

  if self.node.job == "expedition" then
    self.node.job = "rare"
    self:saveNode()
  end

  if not self.node.job or not jobs[self.node.job] then
    self.node.job = chooseJob(jobs)
    self:saveNode()
  end

  self.jobModule = jobs[self.node.job]
  self.job = self.jobModule.load()

  -- Upgrade the anonymous 95% park persisted by early ICOS builds.
  if
    self.node.parked
    and not self.node.parkKind
    and (self.jobModule.status(self.job).progress or 0) >= 0.95
    and not self.job.active
  then
    self.node.parkKind = "complete"
    self.node.parkReason = "job complete"
    self:saveNode()
  end

  return self
end

function Context:saveNode()
  config.save(NODE_PATH, self.node)
end

function Context:chooseJob()
  return chooseJob(self.jobs)
end

function Context:selectJob(name, requireExisting, allowUnlocated)
  local nextModule = self.jobs[name]
  if not nextModule then
    return false, "unknown job " .. tostring(name)
  end
  if requireExisting and not fs.exists(nextModule.PATH) then
    return false, "configure " .. name .. " locally once before remote use"
  end

  local nextJob = nextModule.load()
  if not fs.exists(nextModule.PATH) then
    if nextModule.usesSurfaceY then
      local here = nav.worldPosition()
      if not here and not allowUnlocated then
        return false, "set this turtle's position before selecting " .. name
      end
      if here then
        nextJob.surfaceY = here.y
      end
    end
    nextModule.save(nextJob)
  end

  self.node.job = name
  self.jobModule = nextModule
  self.job = nextJob
  self:saveNode()
  return true
end

function Context:snapshot()
  local x, y, z, facing = nav.position()
  local stats = nav.stats()
  local tank = fuel.level()
  local reserve = fuel.inventoryPotential()
  local available = fuel.available()
  local jobStatus = self.jobModule.status(self.job)
  local world = (nav.hasOrigin() and nav.worldPosition()) or self.worldPos
  self.worldPos = world
  local fuelRequired = self.jobModule.minimumFuel and self.jobModule.minimumFuel(self.job)
    or (self.jobModule.estimateFuel and self.jobModule.estimateFuel(self.job) or nil)
  local progress = jobStatus.progress

  if self.node.parked then
    if self.node.parkKind == "complete" then
      progress = 1
    elseif jobStatus.standing then
      -- A parked turtle is not part-way along a route, so a job whose progress
      -- tracks the route phase must report something else while it waits. Without
      -- this, every recalled turtle sits at the `home` phase's 95% for as long as
      -- it is parked - which reads as a turtle stuck on its way back, and is
      -- indistinguishable from one that genuinely is.
      progress = jobStatus.standing
    end
  end

  return {
    label = os.getComputerLabel() or ("turtle-" .. os.getComputerID()),
    version = version,
    role = "miner",
    job = self.jobModule.name,
    phase = self.status.phase,
    detail = self.status.detail,
    parked = self.node.parked,
    parkKind = self.node.parkKind,
    x = x,
    y = y,
    z = z,
    facing = facing,
    -- With a saved origin this is cheap dead reckoning and must be refreshed on
    -- every heartbeat. A 30-second-old position is actively harmful to peer
    -- avoidance because it makes a moving turtle look parked in an old block.
    world = world,
    -- math.huge does not survive rednet serialisation cleanly; -1 means off.
    fuel = available == math.huge and -1 or available,
    fuelTank = tank == math.huge and -1 or tank,
    fuelReserve = reserve,
    fuelFraction = fuel.fraction(),
    fuelRequired = fuelRequired,
    distanceHome = nav.distanceHome(),
    moves = stats.moves,
    digs = stats.digs,
    delivered = jobStatus.delivered,
    haul = jobStatus.haul,
    progress = progress,
    settings = jobStatus.settings,
    settingFields = self.jobModule.settingFields,
    startedAt = self.job.startedAt,
    -- Shared-mine telemetry. Optional on readers: a turtle running an older
    -- build, or a job with no concept of sectors, simply omits these.
    sector = jobStatus.sector,
    workKey = jobStatus.workKey,
    peers = peers.count(),
  }
end

function Context:draw()
  if self.interactive then
    return
  end
  local snap = self:snapshot()
  ui.clear()
  ui.header(snap.label, net.isOpen() and (self.baseId and "linked" or "no base") or "no modem")

  local width, height = ui.size()
  ui.text(2, 2, "ICOS v" .. snap.version, ui.theme.dim)
  ui.text(2, 3, ("%-9s %s"):format("job", snap.job), ui.theme.dim)
  ui.text(2, 4, ("%-9s %s"):format("phase", snap.phase), ui.theme.accent)
  ui.text(2, 5, ui.pad(util.fit(snap.detail, width - 3), width - 3), ui.theme.dim)
  ui.text(2, 7, ("%-9s %d, %d, %d"):format("at", snap.x, snap.y, snap.z))
  ui.text(2, 8, ("%-9s %d blocks"):format("home", snap.distanceHome))

  local fuelText = snap.fuel < 0 and "unlimited" or util.count(snap.fuel) .. " aboard"
  if self.node.parked and snap.fuelRequired and snap.fuel >= 0 then
    fuelText = fuelText .. " / " .. util.count(snap.fuelRequired)
  end
  ui.text(2, 9, ("%-9s %s"):format("fuel", fuelText))

  local barWidth = math.max(8, math.min(20, width - 13))
  local fuelGoal = self.node.parked and snap.fuelRequired or (snap.distanceHome + 64)
  local fuelTone = self.node.parked
      and fuelGoal
      and snap.fuel >= 0
      and snap.fuel < fuelGoal
      and ui.theme.bad
    or nil
  ui.bar(12, 10, barWidth, snap.fuel / math.max(1, fuelGoal or 1), fuelTone)
  ui.text(2, 11, ("%-9s %d%%"):format("progress", math.floor((snap.progress or 0) * 100)))
  ui.bar(12, 12, barWidth, snap.progress or 0, ui.theme.accent)

  if height >= 16 then
    ui.text(
      2,
      14,
      ("%-9s %s dug, %s delivered"):format(
        "totals",
        util.count(snap.digs),
        util.count(snap.delivered)
      )
    )
  end

  if self.node.parked then
    ui.footer("D start  C setup  J job  Q exit")
  else
    ui.footer("R recall  Q exit - auto mining")
  end
end

function Context:report(phase, detail)
  self.status.phase = phase
  self.status.detail = detail or ""
  self:draw()
end

function Context:reply(id, action, ok, message)
  if id then
    net.send(id, "command_result", {
      action = action,
      ok = ok,
      message = message,
      snapshot = self:snapshot(),
    })
  end
end

return Context
