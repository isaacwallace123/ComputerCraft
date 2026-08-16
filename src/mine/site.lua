--- Turtle-side view of the shared mine: which sector I hold, and where it is.
---
--- The base station is the authority on sector leases, but it is never a
--- dependency. A turtle that cannot reach base falls back to the plan it cached
--- last and a sector derived from its own computer ID, so a modem failure costs
--- coordination, not mining. That is the same rule the rest of the network code
--- follows: losing the base must never stop a turtle working or coming home.
---
--- Requests are broadcast rather than addressed, because the base is the only
--- thing that answers them and broadcasting means this module never has to know
--- or cache a base ID. Replies arrive on the shared receive loop in
--- `miner/network.lua`, which drops them in the mailbox below.

local config = require("core.config")
local log = require("core.log")
local net = require("core.net")
local plan = require("mine.plan")

local site = {}

site.PATH = ".site"

--- Long enough for a reply from a base that is awake, short enough that a turtle
--- whose base is gone does not stand at its chest waiting for one.
site.CLAIM_TIMEOUT = 3

local mailbox = nil

local function sameGrid(a, b)
  return a.centreX == b.centreX
    and a.centreZ == b.centreZ
    and a.cellSize == b.cellSize
    and a.minRing == b.minRing
end

--- Called by the receive loop when the base answers.
function site.deliver(body)
  mailbox = body
end

local function defaults()
  return {
    plan = plan.normalise({}),
    sector = 0,
    frontier = 0,
    workKey = nil,
    claimedAt = 0,
    fromBase = false,
    fallbackOffsets = {},
  }
end

function site.load()
  local state = config.load(site.PATH, defaults())
  state.plan = plan.normalise(state.plan)
  state.sector = math.max(0, math.floor(tonumber(state.sector) or 0))
  state.frontier = math.max(0, math.floor(tonumber(state.frontier) or 0))
  state.workKey = type(state.workKey) == "string" and state.workKey or nil
  state.fallbackOffsets = type(state.fallbackOffsets) == "table" and state.fallbackOffsets or {}
  return state
end

function site.save(state)
  config.save(site.PATH, state)
end

--- A sector to work when nobody is coordinating.
---
--- Spreading by computer ID is not as good as a lease - two turtles whose IDs are
--- congruent modulo the sector count would share ground - but it is stable across
--- reboots, needs no network, and never puts the whole fleet in sector 1.
function site.fallbackSector(state, workKey)
  local capacity = plan.capacity(state.plan)
  local offset = math.max(0, math.floor(tonumber(state.fallbackOffsets[workKey or ""] or 0)))
  if offset >= capacity then
    return nil
  end
  return ((os.getComputerID() - 1 + offset) % capacity) + 1
end

--- Ask the base for a sector, then wait briefly for the answer.
function site.claim(workKey, preferredSector, frontier)
  local state = site.load()
  workKey = tostring(workKey or "")
  preferredSector = math.floor(tonumber(preferredSector) or 0)
  frontier = math.max(0, math.floor(tonumber(frontier) or 0))
  local requestId = ("%d:%s:%s"):format(os.getComputerID(), tostring(os.epoch("utc")), workKey)

  mailbox = nil
  local asked = net.broadcast("mine", {
    action = "claim",
    requestId = requestId,
    workKey = workKey,
    sector = preferredSector > 0 and preferredSector or nil,
    frontier = frontier,
  })
  local claimError = nil

  if asked then
    local deadline = os.clock() + site.CLAIM_TIMEOUT
    while os.clock() < deadline do
      local reply = mailbox
      if reply then
        mailbox = nil
        -- A delayed response to an earlier claim must not assign this job the
        -- wrong sector. Ignore it and keep waiting for the matching response.
        if reply.requestId == requestId then
          if reply.ok == false then
            claimError = tostring(reply.message or "base refused a sector")
            log.warn("mine: " .. claimError)
            -- A reply is authoritative. Falling back after an explicit refusal
            -- could resurrect an old grid after the base moved, or reopen a
            -- worked-out sector after the configured capacity was exhausted.
            state.claimedAt = os.epoch("utc")
            state.fromBase = true
            site.save(state)
            return state, claimError
          else
            local receivedPlan = plan.normalise(reply.plan)
            if not sameGrid(state.plan, receivedPlan) then
              state.fallbackOffsets = {}
            end
            state.plan = receivedPlan
            state.sector = math.floor(tonumber(reply.sector) or 0)
            state.frontier = math.floor(tonumber(reply.frontier) or 0)
            state.workKey = workKey
            state.claimedAt = os.epoch("utc")
            state.fromBase = true
            site.save(state)
            return state
          end
        end
      end
      sleep(0.1)
    end
  end

  -- No base or no answer. Carry on with what we already know: an
  -- unfinished sector we are already standing in is worth far more than a new
  -- one, and re-picking would be exactly the behaviour this design removes.
  --
  -- With no cached plan there is nothing safe to fall back to. The default plan
  -- is centred on world 0,0, which is a real place and certainly not this base -
  -- so stay unassigned and let the caller refuse to deploy.
  if state.plan.configured then
    local preferred = plan.sector(state.plan, preferredSector)
    if preferred and frontier < preferred.trunkLength then
      state.sector = preferredSector
      state.frontier = frontier
    elseif state.workKey ~= workKey or state.sector < 1 then
      -- The preferred sector is already complete. Advance the stable offline
      -- cursor instead of repeatedly redeploying to its final trunk cell.
      state.sector = site.fallbackSector(state, workKey) or 0
      state.frontier = 0
    end
    state.workKey = workKey
  end
  state.claimedAt = os.epoch("utc")
  state.fromBase = false
  site.save(state)
  if not state.plan.configured then
    return state, claimError or "no mine plan received - start the configured fleet base"
  end
  if state.sector < 1 then
    return state, claimError or "offline mine capacity exhausted - reconnect the configured base"
  end
  return state, claimError
end

--- Tell the base how far the trunk has been worked. Fire and forget: the local
--- copy is saved either way, so progress survives with the modem unplugged.
function site.report(workKey, sector, frontier, blocks, exhausted)
  local state = site.load()
  sector = math.floor(tonumber(sector) or 0)
  workKey = tostring(workKey or "")
  frontier = math.max(0, math.floor(tonumber(frontier) or 0))

  if state.workKey == workKey and state.sector == sector then
    state.frontier = math.max(state.frontier, frontier)
    if exhausted then
      state.sector = 0
      state.frontier = 0
      state.fallbackOffsets[workKey] = math.max(
        0,
        math.floor(tonumber(state.fallbackOffsets[workKey] or 0))
      ) + 1
    end
  end
  site.save(state)

  if sector > 0 then
    net.broadcast("mine", {
      action = "report",
      workKey = workKey,
      sector = sector,
      frontier = frontier,
      blocks = math.floor(tonumber(blocks) or 0),
      exhausted = exhausted == true,
    })
  end
  return state
end

--- The sector geometry this turtle is currently working, or nil if unassigned.
--- An unconfigured plan counts as unassigned: its coordinates are placeholders.
function site.sector(state)
  if not state or (state.sector or 0) < 1 or not state.plan.configured then
    return nil
  end
  return plan.sector(state.plan, state.sector)
end

return site
