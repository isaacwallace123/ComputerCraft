--- Fleet-wide atomic job assignment and shared-mine sector leasing.

local log = require("core.log")
local net = require("core.net")
local plan = require("mine.plan")
local registry = require("mine.registry")
local rosterStore = require("fleet.roster")

local coordinator = {}
local renewalCheckedAt = {}

local function availableMiners()
  local devices = rosterStore.load()
  local miners = {}
  for _, node in ipairs(rosterStore.sorted(devices)) do
    local snap = node.snap or {}
    if rosterStore.online(node) and snap.role == "miner" and snap.parked then
      miners[#miners + 1] = node
    end
  end
  return miners
end

--- Give every connected parked miner the same job and launch it.
---
--- `assign_job` is deliberately used instead of separate set/configure/deploy
--- messages. The miner applies the whole assignment while parked and only then
--- queues deployment, so it cannot start between those steps with stale settings.
function coordinator.assignParked(job, settings)
  local miners = availableMiners()
  if #miners == 0 then
    return false, "no connected parked miners are available"
  end

  local sent = 0
  for _, node in ipairs(miners) do
    if
      net.send(tonumber(node.id), "command", {
        action = "assign_job",
        job = job,
        settings = settings,
      })
    then
      sent = sent + 1
    end
  end

  if sent == 0 then
    return false, "assignments could not be sent - check the modem"
  end
  return true, ("queued %s on %d/%d parked miners"):format(job, sent, #miners)
end

function coordinator.quarry(settings)
  local miners = availableMiners()
  if #miners == 0 then
    return false, "no connected parked miners are available"
  end

  local cells = (math.abs(settings.x2 - settings.x1) + 1)
    * (math.abs(settings.z2 - settings.z1) + 1)
  while #miners > cells do
    table.remove(miners)
  end

  local sent = 0
  for index, node in ipairs(miners) do
    local assignment = {
      minX = math.min(settings.x1, settings.x2),
      maxX = math.max(settings.x1, settings.x2),
      minZ = math.min(settings.z1, settings.z2),
      maxZ = math.max(settings.z1, settings.z2),
      topY = settings.topY,
      bottomY = settings.bottomY,
      workerIndex = index,
      workerCount = #miners,
    }
    if
      net.send(tonumber(node.id), "command", {
        action = "assign_job",
        job = "quarry",
        settings = assignment,
      })
    then
      sent = sent + 1
    end
  end

  if sent == 0 then
    return false, "assignments could not be sent - check the modem"
  end
  return true, ("assigned %d/%d parked miners"):format(sent, #miners)
end

---------------------------------------------------------------------------
-- Shared mine
---------------------------------------------------------------------------

--- Answer a turtle's `mine` request.
---
--- Kept deliberately small and synchronous: a turtle waits about three seconds
--- for this before falling back to its cached plan, so there is nothing here
--- that can block. If the base is busy or missing, mining still happens - just
--- without the guarantee that two turtles are in different sectors.
function coordinator.mine(sender, body)
  if type(body) ~= "table" then
    return
  end

  local state = registry.load()

  if body.action == "claim" then
    if not state.plan.configured then
      net.send(sender, "mine_result", {
        ok = false,
        requestId = body.requestId,
        message = "no mine configured at base - run `mine here` on the console",
      })
      return
    end

    local index, work = registry.claim(state, sender, body.workKey, body.sector, body.frontier)
    if not index or type(work) ~= "table" then
      net.send(sender, "mine_result", { ok = false, requestId = body.requestId, message = work })
      log.warn("mine: no sector available for #" .. tostring(sender))
      return
    end

    registry.save(state)
    net.send(sender, "mine_result", {
      ok = true,
      requestId = body.requestId,
      plan = state.plan,
      sector = index,
      frontier = work.frontier or 0,
      -- What the fleet already knows about this sector's shaft head, so a
      -- replacement turtle does not re-survey ground somebody has surveyed.
      surface = registry.surfaceOf(state, index),
    })
    log.info(
      ("mine: sector %d leased to #%d (%s)"):format(index, sender, plan.describe(state.plan, index))
    )
  elseif body.action == "report" then
    local index = math.floor(tonumber(body.sector) or 0)
    if index < 1 then
      return
    end
    local recorded, reportError = registry.report(
      state,
      sender,
      index,
      body.workKey,
      body.frontier,
      body.blocks,
      body.exhausted
    )
    if not recorded then
      log.warn(("mine: report from #%d rejected - %s"):format(sender, tostring(reportError)))
      return
    end
    registry.save(state)
    if body.exhausted == true then
      log.info(("mine: sector %d worked out by #%d"):format(index, sender))
    end
  elseif body.action == "surface" then
    local index = math.floor(tonumber(body.sector) or 0)
    if index < 1 then
      return
    end
    local recorded, surfaceState = registry.surface(state, sender, index, body)
    if not recorded then
      log.warn(
        ("mine: surface report from #%d rejected - %s"):format(sender, tostring(surfaceState))
      )
      return
    end
    registry.save(state)
    if body.state == "open" then
      log.warn(("mine: sector %d shaft head is OPEN - %s"):format(index, tostring(body.reason)))
    elseif body.state == "blocked" then
      log.warn(("mine: sector %d head cannot be sealed - %s"):format(index, tostring(body.reason)))
    end
  elseif body.action == "release" then
    local index = math.floor(tonumber(body.sector) or 0)
    if index >= 1 then
      registry.release(state, sender, index)
      registry.save(state)
    end
  end
end

--- Keep a working turtle's lease alive from its normal status heartbeat.
function coordinator.renewMine(sender, snapshot)
  if not snapshot or snapshot.parked then
    return
  end
  local index = math.floor(tonumber(snapshot and snapshot.sector) or 0)
  local workKey = snapshot and snapshot.workKey
  if index < 1 or type(workKey) ~= "string" then
    return
  end
  local now = os.epoch("utc")
  if now - (renewalCheckedAt[sender] or 0) < 30000 then
    return
  end
  renewalCheckedAt[sender] = now
  local state = registry.load()
  if registry.renew(state, sender, index, workKey) then
    registry.save(state)
  end
end

--- Point the mine at a world position and hand out fresh sectors from there.
function coordinator.setMine(fields)
  local state = registry.load()
  local merged = {}
  for key, value in pairs(state.plan) do
    merged[key] = value
  end
  for key, value in pairs(fields or {}) do
    merged[key] = value
  end
  local hasCentre = fields and fields.centreX ~= nil and fields.centreZ ~= nil
  merged.configured = state.plan.configured or hasCentre

  local normalised = plan.normalise(merged)

  -- Anything that changes which ground a sector number refers to invalidates
  -- every recorded frontier. The keep-out radius counts: raising it shifts every
  -- sector outward in the spiral.
  local moved = normalised.centreX ~= state.plan.centreX
    or normalised.centreZ ~= state.plan.centreZ
    or normalised.cellSize ~= state.plan.cellSize
    or normalised.minRing ~= state.plan.minRing

  state.plan = normalised
  if moved then
    -- Sector N means a different patch of ground now, so every frontier and
    -- lease recorded against the old grid is meaningless. Keeping them would
    -- send turtles to tunnels that do not exist.
    state.sectors = {}
  end
  registry.save(state)
  return state.plan, moved
end

function coordinator.mineState()
  return registry.load()
end

return coordinator
