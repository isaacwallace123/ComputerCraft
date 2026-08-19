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
--- ## Pure, finally
---
--- This file was moved into `domain/` without being de-globalised - it read
--- `os.epoch` and it persisted through `core/config` - and was the last entry
--- in the layering check's allow list. The move and the de-globalising were
--- deliberately two changes: doing both at once would have destroyed the only
--- evidence available that a live fleet's sector bookkeeping came through the
--- move unaltered, which was that the specs passed untouched.
---
--- The second change is now done. `now` is a required argument to everything
--- that stamps or compares a time, and reading and writing `.mine` belongs to
--- the caller. The ICOS 1 callers get both back from
--- `legacy/mine/registry.lua`, a facade that supplies the CC clock and the CC
--- file, so nothing about what the live fleet does changed.
---
--- **`now` is required, not optional, and that is the point.** An optional one
--- looks harmless and is not: a caller holding a clock port and this module
--- were briefly measuring against two different clocks, and the leases service
--- found it immediately - every lease it took looked fifteen minutes stale the
--- instant it was written, so two turtles were handed the same shaft. A
--- defaulted clock is a second clock nobody declared. Required means the
--- mismatch is a nil arithmetic error at the call site rather than a lease that
--- quietly never expires.

local plan = require("domain.mine.plan")

local registry = {}

--- Seconds between two stamps taken from the same clock.
---
--- A comparison is as much a use of the clock as a stamp is, which is why this
--- takes `now` rather than reading one. `at` of nil is `math.huge` - a lease
--- that was never taken is infinitely old, which is what makes an absent record
--- expire rather than persist forever.
local function elapsed(at, now)
  if at == nil then
    return math.huge
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

--- Place or reshape the mine, and say whether the ground moved under it.
---
--- Merged into the existing plan rather than replacing it, so `mine at x y z`
--- moves the centre without forgetting the cell size somebody tuned, and a
--- later `cellSize` change does not un-place the mine.
---
--- **The second return value is the dangerous one.** Anything that changes which
--- ground a sector *number* refers to makes every recorded frontier and lease
--- meaningless - sector 7 is now a different patch of world, and a turtle sent
--- to resume its tunnel would be sent to a tunnel that does not exist. So those
--- changes clear the sectors, and the caller is told it happened because
--- somebody needs to be shown that a day of progress was just discarded on
--- purpose.
---
--- The keep-out radius counts as moving the ground. It is not obvious and it was
--- got wrong once: raising `minRing` shifts every sector outward along the
--- spiral, so the numbers stay and the places change, which is the worst version
--- of this bug because nothing looks different.
---
--- `configured` latches. A mine that has been placed stays placed, and a later
--- call that tunes one field without naming a centre must not un-place it.
function registry.configure(state, fields)
  fields = type(fields) == "table" and fields or {}
  state = registry.normalise(state)

  local merged = {}
  for key, value in pairs(state.plan) do
    merged[key] = value
  end
  for key, value in pairs(fields) do
    merged[key] = value
  end

  local placed = fields.centreX ~= nil and fields.centreZ ~= nil
  merged.configured = state.plan.configured == true or placed

  local normalised = plan.normalise(merged)

  local moved = normalised.centreX ~= state.plan.centreX
    or normalised.centreZ ~= state.plan.centreZ
    or normalised.cellSize ~= state.plan.cellSize
    or normalised.minRing ~= state.plan.minRing

  state.plan = normalised
  if moved then
    state.sectors = {}
  end
  return normalised, moved
end

--- Look at a sector without bringing it into existence.
---
--- `entry` below is get-**or-create**, and it was being called from four scan
--- loops that only wanted to read - so the first claim on a fresh mine
--- materialised a record for every sector in the plan, each carrying an empty
--- work entry and `surface = unknown`. A live base's `.mine` was 10,626 bytes of
--- forty-eight records with **zero holders** between them: almost entirely
--- bookkeeping for ground no turtle had ever visited.
---
--- That is not only waste on disk. `leases` flushes the whole file on every
--- claim, surface report and release, so the write was ten times the size it
--- needed to be on a computer with a one-megabyte disk - and at `maxRing = 8`
--- the plan holds 288 sectors rather than 48.
---
--- Nil means free and untouched, which is exactly what an absent record means.
local function peek(state, index)
  return state.sectors[tostring(index)]
end

--- The work a sector has recorded for this key, or nothing.
---
--- The read-only half of `workEntry`. Returns a frozen default rather than nil so
--- a caller can compare frontiers without a nil check on every branch, and
--- **never writes it back** - which is the whole point.
local EMPTY_WORK = { frontier = 0, exhausted = false, blocks = 0 }

local function peekWork(record, workKey)
  if record == nil or type(record.work) ~= "table" then
    return EMPTY_WORK
  end
  local work = record.work[workKey]
  if work == nil then
    return EMPTY_WORK
  end
  return work
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
    --
    -- Over the records that exist, not over `1..capacity`: a turtle can only
    -- hold a sector somebody has already claimed, so the sectors nobody has
    -- touched cannot be holding anything and do not need creating to find out.
    for key, other in pairs(state.sectors) do
      if key ~= tostring(index) and other.holder == turtleId then
        other.holder = nil
        other.holderWorkKey = nil
        other.leasedAt = nil
      end
    end
    record.holder = turtleId
    record.holderWorkKey = workKey
    record.leasedAt = now
    return index, work
  end

  -- Prefer the turtle's cached sector. This is what lets offline progress and a
  -- reboot resume the same ground once the base becomes reachable again.
  if preferredIndex >= 1 and preferredIndex <= capacity then
    local existing = peek(state, preferredIndex)
    local free = existing == nil or not held(existing, now) or existing.holder == turtleId
    if free and not peekWork(existing, workKey).exhausted then
      -- Only now is it worth creating: this sector is about to be leased, so a
      -- record for it is a record of something rather than of nothing.
      local record = entry(state, preferredIndex)
      local work = workEntry(record, workKey)
      local sector = plan.sector(state.plan, preferredIndex)
      local trunkLength = sector and sector.trunkLength or 0
      work.frontier = math.max(work.frontier or 0, math.min(localFrontier, trunkLength))
      return take(preferredIndex, record, work)
    end
  end

  -- A sector this turtle already holds. Again over what exists: it cannot be
  -- holding one nobody has ever claimed.
  for key, record in pairs(state.sectors) do
    local index = tonumber(key)
    if index and record.holder == turtleId and not peekWork(record, workKey).exhausted then
      return take(index, record, workEntry(record, workKey))
    end
  end

  -- A sector whose head is a known hole in the ground comes first, ahead of
  -- both partly worked and untouched ground, and even when its own tunnel is
  -- finished. This is the whole patrol mechanism: a turtle sent there caps the
  -- head on the way in as it would on any other trip, finds nothing left to
  -- mine, and comes home. No separate job, no separate route, and an exposed
  -- shaft is repaired by the next turtle that asks for work rather than by
  -- somebody noticing it.
  -- An open shaft head can only be known about from a record somebody wrote, so
  -- this is a scan over what exists by definition. Ordered by index rather than
  -- by `pairs`, because `pairs` has no order and a patrol that picked a
  -- different hole each time it was asked would leave the same ones open.
  local exposedIndex = nil
  for key, record in pairs(state.sectors) do
    local index = tonumber(key)
    if index and index <= capacity and not held(record, now) and exposed(record) then
      if exposedIndex == nil or index < exposedIndex then
        exposedIndex = index
      end
    end
  end
  if exposedIndex then
    local record = entry(state, exposedIndex)
    return take(exposedIndex, record, workEntry(record, workKey))
  end

  -- Partly worked sectors before untouched ones: finishing a tunnel the fleet
  -- already paid to reach is cheaper than opening another shaft.
  --
  -- This is the one scan that genuinely has to walk the whole plan, because an
  -- untouched sector is a candidate and has no record. It reads through `peek`,
  -- so walking past four hundred sectors costs four hundred table lookups and
  -- creates nothing.
  local best = nil
  local bestFrontier = -1
  for index = 1, capacity do
    local record = peek(state, index)
    local work = peekWork(record, workKey)
    if (record == nil or not held(record, now)) and not work.exhausted then
      if work.frontier > bestFrontier then
        best, bestFrontier = index, work.frontier
      end
    end
  end

  if not best then
    return nil, "every sector in the plan is exhausted - raise maxRing or move the mine"
  end

  local record = entry(state, best)
  return take(best, record, workEntry(record, workKey))
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
    at = now,
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
  record.leasedAt = now
  local sector = plan.sector(state.plan, index)
  local reportedFrontier = math.max(0, math.floor(tonumber(frontier) or 0))
  work.frontier =
    math.max(work.frontier or 0, math.min(reportedFrontier, sector and sector.trunkLength or 0))
  work.blocks = (work.blocks or 0) + math.max(0, math.floor(tonumber(blocks) or 0))
  work.lastMined = now

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
  record.leasedAt = now
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
