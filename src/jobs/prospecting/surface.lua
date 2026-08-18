--- Opening and closing a sector's shaft head, for one trip.
---
--- `turtle/access` knows what a safe cap is. This knows when to move one, which
--- is a different job and a much fussier one: the ground has to be found, the
--- turtle has to end up under it, power can be lost between breaking a block and
--- replacing it, and the head the plan nominated may be under a pond.
---
--- Pulling it out of the runner is not tidying. The runner was one function
--- holding twenty closures over the same job table, and every rule about the
--- surface was interleaved with rules about ore. Here the surface is one object
--- with one piece of persisted state, which is what makes the crash recovery
--- readable enough to trust.

local access = require("device.access")
local inv = require("device.inv")
local nav = require("device.nav")

local surface = {}
surface.__index = surface

--- How far along the trunk a head may be relocated when the nominated column
--- cannot be sealed. The trunk runs along X through the shaft, so sliding the
--- head along X keeps it on the tunnel the turtle was going to walk anyway.
surface.MAX_OFFSET = 6

--- Fuel set aside for head probing and crash recovery. Moving a cap is digs and
--- placements, which cost nothing; this covers walking back to it.
surface.RESERVE = 16

--- `trip` supplies everything about the current run: the job table, how to
--- persist it, how to report, the movement guard, and the coordinate helpers
--- that only the runner knows how to build.
function surface.new(trip)
  local self = setmetatable({}, surface)
  self.trip = trip
  self.job = trip.job
  self.state = access.normalise(trip.job.access)
  return self
end

---------------------------------------------------------------------------
-- Position and persisted state
---------------------------------------------------------------------------

--- World X of the head actually in use, which may be offset along the trunk
--- from the one the plan nominated.
function surface:headX()
  return self.job.shaftX + (tonumber(self.job.shaftOffset) or 0)
end

function surface:headZ()
  return self.job.shaftZ
end

function surface:worldY()
  local _, y = nav.position()
  return self.trip.originY + y
end

--- Record where the cap is and which half of a transition we are in.
---
--- Written before the block is touched and again after it is observed, so a
--- reboot in between lands on a state that names the risk rather than one that
--- quietly claims the surface is fine.
function surface:record(state, capWorldY)
  self.job.access = { state = state, y = capWorldY }
  self.state = self.job.access
  self.trip.save()
end

function surface:capRelY()
  if not self.state.y then
    return nil
  end
  -- A recorded head that is nowhere near the worksite surface describes some
  -- other ground: a previous lease, a job file carried over from a turtle that
  -- was re-homed, a plan whose centre moved. Acting on it means doing cap work
  -- at a coordinate that is not a shaft, and near a base that is a computer or a
  -- chest. Discard it and let the way out find the head by probing.
  if math.abs(self.state.y - self.job.surfaceY) > access.HEAD_TOLERANCE then
    return nil
  end
  return self.state.y - self.trip.originY
end

--- Is the turtle standing in the column it believes it capped?
---
--- Cap work breaks and replaces blocks directly above and below the turtle, so
--- doing it anywhere other than the shaft is how a mining job ends up trying to
--- mine the base. Every path into it checks this first; nothing about the
--- persisted record is trusted to imply position.
function surface:inHeadColumn()
  local here = nav.worldPosition()
  if not here then
    return false
  end
  return here.x == self:headX() and here.z == self:headZ()
end

--- Relative coordinate of the head column at the cap's height.
function surface:column(offset)
  local x = self.job.shaftX + (offset or (tonumber(self.job.shaftOffset) or 0))
  return self.trip.relative(x, self.state.y or self.job.surfaceY, self:headZ())
end

function surface:describe()
  return ("sector %d shaft %d,%d"):format(self.job.sector, self:headX(), self:headZ())
end

---------------------------------------------------------------------------
-- Cap material
---------------------------------------------------------------------------

--- Guarantee cap material, mining the shaft wall for it as a last resort.
function surface:ensureFiller()
  local isWanted = self.trip.isWanted
  if access.reserve(isWanted) then
    return true
  end
  if inv.freeSlots() == 0 then
    inv.dropJunk(self.trip.isJunk, access.SLOT)
  end
  local harvested, harvestError = access.harvest(isWanted)
  if harvested then
    return true
  end
  return false,
    ("no cap block for %s (%s) - carry cobblestone or free a slot"):format(
      self:describe(),
      tostring(harvestError)
    )
end

local function capError(self, reason)
  return ("could not cap %s: %s"):format(self:describe(), tostring(reason))
end

--- Close the shaft from underneath, which is how the turtle gets in.
function surface:sealAbove()
  if access.above() == "solid" then
    return true
  end
  local ready, readyError = self:ensureFiller()
  if not ready then
    return false, readyError
  end
  local placed, placeError = access.capUp()
  if not placed then
    return false, capError(self, placeError)
  end
  return true
end

--- Close the shaft from above, which is how every trip ends.
function surface:sealBelow()
  if access.below() == "solid" then
    return true
  end
  local ready, readyError = self:ensureFiller()
  if not ready then
    return false, readyError
  end
  local placed, placeError = access.capDown()
  if not placed then
    return false, capError(self, placeError)
  end
  return true
end

---------------------------------------------------------------------------
-- Going in
---------------------------------------------------------------------------

--- Break into the ground and pull the surface shut overhead.
---
--- Deliberately uninterruptible. A recall or fuel stop between the ground
--- opening and the cap going back on is precisely the hole this whole mechanism
--- exists to prevent, and the window is two moves long; the guard before it
--- already reserved enough fuel for the entire route home.
function surface:enterGround(atLevel)
  local _, y = nav.position()
  local capY = atLevel and y or (y - 1)
  local capWorld = self.trip.originY + capY

  -- Written before the first block is broken. Everything past this point is
  -- recoverable from the persisted record alone.
  self:record("opening", capWorld)
  self.trip.report("opening", "opening " .. self:describe())

  -- Keep room for the blocks about to come out of the ground: they are the cap
  -- material, and a full inventory would drop them on the floor.
  if inv.freeSlots() == 0 then
    inv.dropJunk(self.trip.isJunk, access.SLOT)
  end

  while select(2, nav.position()) > capY - 1 do
    local moved, moveError, moveKind = nav.down()
    if not moved then
      return false, "could not open the shaft head: " .. tostring(moveError), moveKind
    end
  end

  local sealed, sealError = self:sealAbove()
  if not sealed then
    return false, sealError
  end

  self:record("below", capWorld)
  return true
end

--- Walk down one column looking for the top of the ground.
---
--- Returns `"below"` or `"here"` when ground is found, `"obstructed"` with a
--- reason when this column cannot be sealed at all, or nil plus a stop when the
--- trip itself has to end.
function surface:searchColumn()
  local trip = self.trip
  local probes = 0

  while true do
    local _, y = nav.position()
    if y <= trip.targetRelY then
      -- Nothing solid between the cruise lane and the target depth, so no
      -- ground was broken and there is nothing here to seal.
      return "open-sky"
    end

    local belowKind, belowName = access.below()
    if belowKind == "liquid" then
      return "obstructed", ("under %s"):format(belowName)
    end
    if belowKind == "protected" then
      return "obstructed", ("blocked by %s"):format(belowName)
    end

    if belowKind == "solid" then
      return "below"
    end

    if belowKind == "air" and probes < access.PROBE_LIMIT then
      -- A shaft left open by an older build never reports ground downwards,
      -- because the hole runs to the mining depth. It does report walls, and
      -- the level where the column becomes enclosed is that old shaft head.
      if access.ahead() == "solid" then
        probes = probes + 1
        if access.enclosed() then
          return "here"
        end
      end
    end

    local allowed, guardReason, guardKind = trip.guard()
    if not allowed then
      return nil, guardReason, guardKind
    end
    local moved, moveError, moveKind = nav.down()
    if not moved then
      return nil, "shaft head blocked: " .. tostring(moveError), moveKind
    end
    trip.report("opening", "looking for the surface over " .. self:describe())
  end
end

--- Head positions to try, nearest first, bounded to this sector's own trunk.
---
--- The head the plan nominates is the centre of the trunk. Sliding it along X
--- keeps it on the tunnel and inside the sector, so a relocated head costs a few
--- blocks of walking rather than a different route.
function surface:candidates()
  local job = self.job
  local low = (job.trunkFromX or job.shaftX) - job.shaftX
  local high = (job.trunkToX or job.shaftX) - job.shaftX
  local list, seen = {}, {}

  local function add(offset)
    if offset < low or offset > high or seen[offset] then
      return
    end
    seen[offset] = true
    list[#list + 1] = offset
  end

  -- Whatever worked last time first: a sector that has been opened once should
  -- reuse its own hole rather than re-probing from the middle.
  add(tonumber(job.shaftOffset) or 0)
  add(0)
  for step = 1, surface.MAX_OFFSET do
    add(step)
    add(-step)
  end
  return list
end

function surface:toLane(offset)
  local head = self.trip.relative(self.job.shaftX + offset, self.job.laneY, self:headZ())
  if not head then
    return false, "no world origin - run where on this turtle"
  end
  return nav.goTo(head.x, self.trip.laneRelY, head.z, self.trip.guard)
end

--- Find a sealable head for this sector and get under it.
---
--- A column under water or lava is not a failure of the sector, only of one
--- block of it. Refusing to dig there is right; refusing to mine the other
--- 47 columns because of it is not, and it used to park a turtle permanently on
--- ground it could have worked.
function surface:open()
  local problems = {}

  for _, offset in ipairs(self:candidates()) do
    local reached, reachError, reachKind = self:toLane(offset)
    if not reached then
      return false, reachError, reachKind
    end

    local result, detail, kind = self:searchColumn()
    if result == "below" or result == "here" then
      -- The cap sits at the surface and the turtle has to end up under it, so
      -- there must be at least two levels between the surface and the target.
      -- Without that the descent would seal the shaft and then climb straight
      -- back out through its own cap to reach the mining depth.
      local _, y = nav.position()
      local head = result == "here" and y or (y - 1)
      if head < self.trip.targetRelY + 2 then
        return false,
          ("%s ground is at target Y %d - mine deeper than the surface"):format(
            self:describe(),
            self.job.targetY
          )
      end

      self.job.shaftOffset = offset
      self.trip.save()
      return self:enterGround(result == "here")
    end
    if result == "open-sky" then
      self.job.shaftOffset = offset
      self:record("unknown", nil)
      return true
    end
    if result ~= "obstructed" then
      return false, detail, kind
    end

    problems[#problems + 1] = ("%+d %s"):format(offset, tostring(detail))
    self.trip.report(
      "opening",
      ("head %+d is %s - trying another"):format(offset, tostring(detail))
    )
  end

  self.blocked = ("no sealable head near %d,%d (%s)"):format(
    self.job.shaftX,
    self:headZ(),
    table.concat(problems, "; ", 1, math.min(3, #problems))
  )
  return false,
    ("no sealable shaft head for sector %d near %d,%d (%s) - clear it or move the mine"):format(
      self.job.sector,
      self.job.shaftX,
      self:headZ(),
      table.concat(problems, "; ", 1, math.min(3, #problems))
    ),
    "blocked"
end

---------------------------------------------------------------------------
-- Coming back out
---------------------------------------------------------------------------

--- Seal a shaft opened by a build that never recorded where its head was.
---
--- Inside the ground every wall is solid; the first level whose walls are not is
--- the first level above the surface, and the cap belongs one block below it.
--- Bounded by the plan's surface so a cave ceiling on the way up is not mistaken
--- for daylight, and it refuses rather than guesses when the two disagree - a
--- cap in the wrong place hides the real hole instead of closing it.
function surface:probeAndSeal()
  local trip = self.trip
  trip.report("sealing", "locating the " .. self:describe() .. " head")
  local lastSolid = nil

  while true do
    local _, y = nav.position()
    if access.ahead() == "solid" then
      lastSolid = y
    elseif lastSolid == y - 1 then
      local capWorld = trip.originY + lastSolid
      if math.abs(capWorld - self.job.surfaceY) <= access.HEAD_TOLERANCE then
        self:record("resealing", capWorld)
        local sealed, sealError = self:sealBelow()
        if not sealed then
          return false, sealError
        end
        self:record("sealed", capWorld)
        return true
      end
      lastSolid = nil
    end

    if y >= trip.laneRelY then
      if lastSolid == nil then
        -- Never inside the ground at all, so nothing here was ever opened.
        self:record("unknown", nil)
        return true
      end
      return false, ("could not find the %s head - cap it by hand"):format(self:describe())
    end

    local climbed, climbError = nav.up()
    if not climbed then
      return false, "could not climb the shaft: " .. tostring(climbError)
    end
  end
end

--- Climb out, taking the cap from underneath and putting it back from above.
--- This is the only moment the surface is open, and it lasts exactly the two
--- moves it takes to pass through.
function surface:leave()
  local capY = self:capRelY()
  local column = self:column()
  local _, y = nav.position()

  -- Never move a cap from outside the shaft. If the turtle is not standing in
  -- its own head column, whatever is above and below it belongs to somebody
  -- else - at the depot that is the base computer and the haul chests.
  if not self:inHeadColumn() then
    self:record("unknown", nil)
    return true
  end

  if self.state.state == "legacy" or not capY or not column then
    return self:probeAndSeal()
  end

  if y >= capY then
    -- Above the opening already: the descent stopped before going under it, or
    -- a crash recovery has already put the turtle here. Only confirm.
    if self.state.state == "sealed" then
      return true
    end
    local reached, reachError = nav.goTo(column.x, capY + 1, column.z)
    if not reached then
      return false, "could not reach the shaft head: " .. tostring(reachError)
    end
    local confirmed, confirmError = self:sealBelow()
    if not confirmed then
      return false, confirmError
    end
    self:record("sealed", self.state.y)
    return true
  end

  while select(2, nav.position()) < capY - 1 do
    local climbed, climbError = nav.up()
    if not climbed then
      return false, "could not climb the shaft: " .. tostring(climbError)
    end
  end

  self.trip.report("sealing", "resealing " .. self:describe())
  -- Cap material has to be secured from down here. The wall below the surface
  -- is rock and can be mined for one; the wall above it is sky and cannot.
  self:ensureFiller()

  local capWorld = self.state.y
  self:record("reopening", capWorld)
  local cleared, clearError = access.clearUp()
  if not cleared then
    return false, clearError
  end

  for _ = 1, 2 do
    local climbed, climbError = nav.up()
    if not climbed then
      return false, "could not climb through the shaft head: " .. tostring(climbError)
    end
  end

  self:record("resealing", capWorld)
  local sealed, sealError = self:sealBelow()
  if not sealed then
    return false, sealError
  end
  self:record("sealed", capWorld)
  return true
end

---------------------------------------------------------------------------
-- Crash recovery
---------------------------------------------------------------------------

--- Is the turtle genuinely under a cap, rather than merely recorded as such?
---
--- A record left by a trip that never got home - or a turtle picked up and put
--- back on its chest by hand - would otherwise skip the opening entirely and
--- sink a fresh uncapped shaft from the cruise lane.
function surface:sealedIn()
  local state = self.state.state
  if state ~= "below" and state ~= "legacy" then
    return false
  end
  local capY = self:capRelY()
  local _, y = nav.position()
  if capY then
    return y < capY
  end
  return state == "legacy" and self:worldY() < self.job.surfaceY
end

--- Put the surface back into a known state after power was lost part-way
--- through moving the cap.
---
--- Which way to resolve the transition is decided by where the turtle actually
--- is, not by which half was recorded: below the opening it seals upward and
--- carries on with the trip, at or above it seals downward and the descent
--- starts again. The observation comes first in both cases, because the block
--- may already be exactly where it belongs.
function surface:restore()
  local state = self.state.state
  if state ~= "opening" and state ~= "reopening" and state ~= "resealing" then
    return true
  end

  local capY = self:capRelY()
  local column = self:column()
  local _, y = nav.position()

  -- Every half of a cap move happens within one block of the cap, so anything
  -- further away means the record no longer describes this turtle. Refuse to
  -- navigate to it: `goTo` climbs before it crosses, and from mining depth that
  -- would cut a second vertical hole to the surface in the wrong place.
  if not capY or not column or math.abs(y - capY) > 2 or not self:inHeadColumn() then
    -- Nothing actionable, or the turtle is not in the shaft. Either way this
    -- record cannot be resolved from here; find the head on the way out.
    self:record("legacy", nil)
    return true
  end

  if y < capY then
    self.trip.report("sealing", "restoring the cap after an interrupted descent")
    local reached, reachError = nav.goTo(column.x, capY - 1, column.z)
    if not reached then
      return false, "could not reach the shaft cap: " .. tostring(reachError)
    end
    local sealed, sealError = self:sealAbove()
    if not sealed then
      return false, sealError
    end
    self:record("below", self.state.y)
    return true
  end

  self.trip.report("sealing", "closing the shaft after an interrupted return")
  local reached, reachError = nav.goTo(column.x, capY + 1, column.z)
  if not reached then
    return false, "could not reach the shaft head: " .. tostring(reachError)
  end
  local sealed, sealError = self:sealBelow()
  if not sealed then
    return false, sealError
  end
  self:record("sealed", self.state.y)
  return true
end

--- A job file written before shafts were capped records nothing about the
--- surface. If such a turtle is already underground its opening exists but its
--- position was never saved, so say exactly that: the way out probes for the
--- head rather than guessing, and the descent is not re-run from below ground
--- where every block downwards looks like a surface.
function surface:adoptLegacy()
  if self.state.state ~= "unknown" then
    return
  end
  if self.job.phase == "travel" or self:worldY() >= self.job.surfaceY then
    return
  end
  self:record("legacy", nil)
end

--- What the base should be told about this sector's head after the trip.
---
--- Deliberately conservative in one direction only: anything the turtle is not
--- sure it closed is reported open, because the cost of a needless patrol trip
--- is a commute and the cost of a missed one is somebody falling down a shaft.
function surface:snapshot(sealFailure)
  local reported = "unknown"
  if self.blocked then
    reported = "blocked"
  elseif sealFailure or (self.state.state ~= "sealed" and self.state.state ~= "unknown") then
    -- Either the reseal failed, or the record still says mid-transition or below
    -- ground at the end of a trip. Both mean the surface was never confirmed
    -- shut, and unconfirmed has to count as open.
    reported = "open"
  elseif self.state.state == "sealed" then
    reported = "sealed"
  end

  return {
    state = reported,
    headY = self.state.y,
    headOffset = tonumber(self.job.shaftOffset) or 0,
    reason = sealFailure or self.blocked,
  }
end

--- Never descend below a cap that was just put back. On ground higher than the
--- plan's surface a head can sit above the cruise lane, and dropping to the lane
--- would mean digging straight back through the block just replaced.
function surface:lowestSafeY(laneRelY)
  local capY = self:capRelY()
  if self.state.state == "sealed" and capY then
    return math.max(laneRelY, capY + 1)
  end
  return laneRelY
end

return surface
