--- Base-side sector leases and mining frontiers.
---
--- This is the piece that stops two turtles from working the same ground and,
--- just as importantly, stops one turtle from forgetting where it got to. A
--- a sector's keyed frontier is how far one profile/depth tunnel has been mined, and
--- it survives every unload, reboot, and inventory-full abort - so a turtle that
--- had to walk away from a half-cleared vein comes back to the same tunnel
--- instead of rolling a new random bearing and abandoning it forever.
---
--- Leases are soft. A turtle that stops reporting simply loses its claim after
--- `LEASE_SECONDS` and the sector returns to the pool, because the alternative -
--- a sector locked out permanently by a turtle that fell in lava - is worse.
---
--- ## Not pure yet
---
--- This file lives under `domain/` and does not yet obey the rule domain/ is
--- for: it reads `os.epoch` and it persists through `core/config`. That is
--- deliberate and it is debt, not an exemption. Moving the file and changing how
--- it gets its clock and its storage are two different changes, and doing both
--- at once would mean the existing specs could no longer prove the move was
--- mechanical - which is the only evidence available that a live fleet's sector
--- bookkeeping came through it unaltered.
---
--- The fix is a `clock` and a `storage` port threaded in from the caller, which
--- is a change to `fleet/coordinator.lua` and `core/console.lua` as much as to
--- this file. It belongs to the phase that does the OS split, alongside the rest
--- of the composition roots.

local config = require("core.config")
local plan = require("domain.mine.plan")
local util = require("core.util")

local registry = {}

--- The clock, injectable, falling back to CC's.
---
--- D027 records that this file was moved into `domain/` without being
--- de-globalised, and that it is the single entry in the layering check's allow
--- list. This does not clear that - `os.epoch` is still named below - but it is
--- the half of the fix that can be made without touching live code.
---
--- Every function that stamps a time now takes an optional `now`. An ICOS 2
--- caller that has a clock port passes it; `fleet/coordinator.lua` and
--- `core/console.lua`, which are ICOS 1 and are being replaced, pass nothing and
--- behave exactly as before. The allow-list entry goes when those callers do.
---
--- The alternative was a required parameter, which would have changed three live
--- call sites and the unmodified spec suite in one go - a refactor of the sector
--- bookkeeping a running fleet depends on, in exchange for deleting one line
--- from a check. Wrong trade.
local function stamp(now)
  return now or os.epoch("utc")
end

--- Seconds since a stamp, measured against the same clock that wrote it.
---
--- `util.since` reads `os.epoch` directly, which means a caller holding a clock
--- port and this module were measuring against two different clocks - and the
--- leases service found it immediately: every lease it took looked fifteen
--- minutes stale the instant it was written, so two turtles were handed the same
--- shaft. A comparison is as much a use of the clock as a stamp is.
local function elapsed(at, now)
  if at == nil then
    return math.huge
  end
  if now == nil then
    return util.since(at)
  end
  return math.max(0, (now - at) / 1000)
end

registry.PATH = ".mine"

--- Long enough to cover ordinary connectivity gaps. Running turtles renew this
--- from status traffic; parked or lost turtles eventually give the sector back.
registry.LEASE_SECONDS = 900

--- A mine nobody has configured yet.
function registry.empty()
  return {
    plan = plan.normalise({}),
    sectors = {},
  }
end

--- Make a table read off disk safe to use.
---
--- Separated from `load` so a caller that reads through the storage port - which
--- is every ICOS 2 caller - gets the same guarantees as one that goes through
--- `core.config`. Without this an ICOS 2 server would hand `plan.capacity` a raw
--- decoded table and get arithmetic on nil the first time a turtle asked for a
--- sector.
function registry.normalise(state)
  if type(state) ~= "table" then
    return registry.empty()
  end
  state.plan = plan.normalise(state.plan)
  state.sectors = type(state.sectors) == "table" and state.sectors or {}
  return state
end

function registry.load()
  return registry.normalise(config.load(registry.PATH, registry.empty()))
end

function registry.save(state)
  config.save(registry.PATH, state)
end

local function entry(state, index)
  local key = tostring(index)
  state.sectors[key] = state.sectors[key]
    or {
      holder = nil,
      holderWorkKey = nil,
      leasedAt = nil,
      work = {},
    }
  state.sectors[key].work = type(state.sectors[key].work) == "table" and state.sectors[key].work
    or {}
  -- Absent on every record written before the base tracked physical state.
  -- `unknown` is the honest value: nobody has said either way.
  if type(state.sectors[key].surface) ~= "table" then
    state.sectors[key].surface = { state = "unknown" }
  end
  return state.sectors[key]
end

--- Is this sector's shaft head believed to be a hole in the ground right now?
local function exposed(record)
  return record.surface ~= nil and record.surface.state == "open"
end

local function workEntry(record, workKey)
  record.work[workKey] = record.work[workKey]
    or {
      frontier = 0,
      exhausted = false,
      blocks = 0,
      lastMined = nil,
    }
  local work = record.work[workKey]
  work.frontier = math.max(0, math.floor(tonumber(work.frontier) or 0))
  work.blocks = math.max(0, math.floor(tonumber(work.blocks) or 0))
  work.exhausted = work.exhausted == true
  return work
end

local function held(record, now)
  return record.holder ~= nil and elapsed(record.leasedAt, now) < registry.LEASE_SECONDS
end

--- Drop leases whose holder has gone quiet. Returns how many were released.
function registry.expire(state, now)
  local released = 0
  for _, record in pairs(state.sectors) do
    if record.holder ~= nil and not held(record, now) then
      record.holder = nil
      record.holderWorkKey = nil
      record.leasedAt = nil
      released = released + 1
    end
  end
  return released
end

--- Hand `turtleId` a sector to work.
---
--- Preference order matters for hole count: a turtle that already holds an
--- unfinished sector keeps it, so redeploying after an unload continues down the
--- same shaft rather than opening a new one. Only when a sector is genuinely
--- finished does the fleet pay for a fresh hole.
function registry.claim(state, turtleId, workKey, preferredIndex, localFrontier, now)
  registry.expire(state, now)

  local capacity = plan.capacity(state.plan)
  workKey = tostring(workKey or "")
  preferredIndex = math.floor(tonumber(preferredIndex) or 0)
  localFrontier = math.max(0, math.floor(tonumber(localFrontier) or 0))
  if workKey == "" then
    return nil, "claim has no work key"
  end

  local function take(index, record, work)
    -- One turtle can only occupy one shaft. Release any older lease it owned
    -- before recording the newly selected work.
    for otherIndex = 1, capacity do
      if otherIndex ~= index then
        local other = entry(state, otherIndex)
        if other.holder == turtleId then
          other.holder = nil
          other.holderWorkKey = nil
          other.leasedAt = nil
        end
      end
    end
    record.holder = turtleId
    record.holderWorkKey = workKey
    record.leasedAt = stamp(now)
    return index, work
  end

  -- Prefer the turtle's cached sector. This is what lets offline progress and a
  -- reboot resume the same ground once the base becomes reachable again.
  if preferredIndex >= 1 and preferredIndex <= capacity then
    local record = entry(state, preferredIndex)
    local work = workEntry(record, workKey)
    if (not held(record, now) or record.holder == turtleId) and not work.exhausted then
      local sector = plan.sector(state.plan, preferredIndex)
      local trunkLength = sector and sector.trunkLength or 0
      work.frontier = math.max(work.frontier or 0, math.min(localFrontier, trunkLength))
      return take(preferredIndex, record, work)
    end
  end

  for index = 1, capacity do
    local record = entry(state, index)
    local work = workEntry(record, workKey)
    if record.holder == turtleId and not work.exhausted then
      return take(index, record, work)
    end
  end

  -- A sector whose head is a known hole in the ground comes first, ahead of
  -- both partly worked and untouched ground, and even when its own tunnel is
  -- finished. This is the whole patrol mechanism: a turtle sent there caps the
  -- head on the way in as it would on any other trip, finds nothing left to
  -- mine, and comes home. No separate job, no separate route, and an exposed
  -- shaft is repaired by the next turtle that asks for work rather than by
  -- somebody noticing it.
  for index = 1, capacity do
    local record = entry(state, index)
    if not held(record, now) and exposed(record) then
      return take(index, record, workEntry(record, workKey))
    end
  end

  -- Partly worked sectors before untouched ones: finishing a tunnel the fleet
  -- already paid to reach is cheaper than opening another shaft.
  local best, bestRecord = nil, nil
  local bestWork = nil
  for index = 1, capacity do
    local record = entry(state, index)
    local work = workEntry(record, workKey)
    if not held(record, now) and not work.exhausted then
      if not bestWork or (work.frontier or 0) > (bestWork.frontier or 0) then
        best, bestRecord, bestWork = index, record, work
      end
    end
  end

  if not best then
    return nil, "every sector in the plan is exhausted - raise maxRing or move the mine"
  end

  return take(best, bestRecord, bestWork)
end

--- Record what a turtle observed about a sector's shaft head.
---
--- This is physical state, not lease state, and it is the piece that used to
--- live only inside one turtle's job file: lose the turtle and nobody knew there
--- was a hundred-block drop at those coordinates. Held at the base it survives a
--- turtle being replaced, lets a fresh one skip re-probing a head that has
--- already been found, and makes "which sectors are open right now" a question
--- with an answer.
function registry.surface(state, turtleId, index, report, now)
  if index < 1 or index > plan.capacity(state.plan) or type(report) ~= "table" then
    return false, "surface report is outside the mine plan"
  end

  local known = {
    unknown = true,
    sealed = true,
    open = true,
    blocked = true,
  }
  local reported = known[report.state] and report.state or "unknown"
  local record = entry(state, index)
  record.surface = {
    state = reported,
    headY = tonumber(report.headY) and math.floor(report.headY) or record.surface.headY,
    headOffset = math.floor(tonumber(report.headOffset) or record.surface.headOffset or 0),
    reason = type(report.reason) == "string" and report.reason:sub(1, 120) or nil,
    at = stamp(now),
    by = turtleId,
  }
  return true, record.surface
end

--- Sectors whose head is believed to be open, for the dashboard and the log.
function registry.exposed(state)
  local rows = {}
  for index = 1, plan.capacity(state.plan) do
    local record = state.sectors[tostring(index)]
    if record and record.surface and record.surface.state == "open" then
      local sector = plan.sector(state.plan, index)
      rows[#rows + 1] = {
        index = index,
        headX = sector and (sector.shaftX + (record.surface.headOffset or 0)),
        headZ = sector and sector.shaftZ,
        headY = record.surface.headY,
        reason = record.surface.reason,
      }
    end
  end
  return rows
end

--- What a claiming turtle should be told about its sector's head, so it does not
--- re-probe ground another turtle has already surveyed.
function registry.surfaceOf(state, index)
  local record = state.sectors[tostring(index)]
  if not record or type(record.surface) ~= "table" then
    return nil
  end
  return {
    state = record.surface.state,
    headY = record.surface.headY,
    headOffset = record.surface.headOffset,
  }
end

--- Record progress for one profile/depth key within a sector.
function registry.report(state, turtleId, index, workKey, frontier, blocks, exhausted, now)
  if not state.plan.configured or index < 1 or index > plan.capacity(state.plan) then
    return false, "sector is outside the mine plan"
  end
  workKey = tostring(workKey or "")
  if workKey == "" then
    return false, "report has no work key"
  end

  local record = entry(state, index)
  if record.holder ~= nil and record.holder ~= turtleId then
    return false, "sector is leased to another turtle"
  end

  local work = workEntry(record, workKey)
  record.holder = turtleId
  record.holderWorkKey = workKey
  record.leasedAt = stamp(now)
  local sector = plan.sector(state.plan, index)
  local reportedFrontier = math.max(0, math.floor(tonumber(frontier) or 0))
  work.frontier =
    math.max(work.frontier or 0, math.min(reportedFrontier, sector and sector.trunkLength or 0))
  work.blocks = (work.blocks or 0) + math.max(0, math.floor(tonumber(blocks) or 0))
  work.lastMined = stamp(now)

  if exhausted == true or (sector and work.frontier >= sector.trunkLength) then
    work.exhausted = true
    if record.holder == turtleId and record.holderWorkKey == workKey then
      record.holder = nil
      record.holderWorkKey = nil
      record.leasedAt = nil
    end
  end
  return true, work
end

--- Renew a live lease from ordinary status traffic without writing on every
--- two-second heartbeat. Returns true only when the caller should save state.
function registry.renew(state, turtleId, index, workKey, now)
  if not state.plan.configured or index < 1 or index > plan.capacity(state.plan) then
    return false
  end
  local record = entry(state, index)
  if record.holder ~= turtleId or record.holderWorkKey ~= workKey then
    return false
  end
  if elapsed(record.leasedAt, now) < 30 then
    return false
  end
  record.leasedAt = stamp(now)
  return true
end

--- Give a sector back without marking progress.
function registry.release(state, turtleId, index)
  if index < 1 or index > plan.capacity(state.plan) then
    return nil
  end
  local record = entry(state, index)
  if record.holder == turtleId then
    record.holder = nil
    record.holderWorkKey = nil
    record.leasedAt = nil
  end
  return record
end

--- Rows for the console and the Fleet page.
function registry.summary(state, now)
  registry.expire(state, now)
  local rows = {}
  for index = 1, plan.capacity(state.plan) do
    local record = state.sectors[tostring(index)]
    if record then
      local sector = plan.sector(state.plan, index)
      for workKey in pairs(record.work or {}) do
        local work = workEntry(record, workKey)
        local heldForWork = record.holder ~= nil and record.holderWorkKey == workKey
        if heldForWork or (work.frontier or 0) > 0 or work.exhausted then
          rows[#rows + 1] = {
            index = index,
            workKey = workKey,
            holder = heldForWork and record.holder or nil,
            frontier = work.frontier or 0,
            length = sector and sector.trunkLength or 0,
            blocks = work.blocks or 0,
            exhausted = work.exhausted == true,
            shaftX = sector and sector.shaftX,
            shaftZ = sector and sector.shaftZ,
            surface = record.surface and record.surface.state or "unknown",
          }
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    return a.index < b.index or (a.index == b.index and a.workKey < b.workKey)
  end)
  return rows
end

return registry
