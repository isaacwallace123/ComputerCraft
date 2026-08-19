--- Posting generals, and spreading miners across the ground they hold.
---
--- `domain/fleet/coverage.lua` holds the rules and `domain/chunk/grid.lua` holds
--- the geometry. This is the service that owns the state, decides where the next
--- general goes, and turns an assignment into a desired-state goal.
---
--- ## It sets goals; it never sends orders
---
--- §5, and the same discipline as `os/server/services/policy.lua`. Posting a
--- general is `desired.want(record, "deploy", { job = "general", settings = ... })`
--- and nothing more - `reconcile` carries it, retries it, and reports whether the
--- device converged. A service that transmitted its own orders would be a second
--- control path with different semantics from every button on the Devices page.
---
--- ## Presence, not claims
---
--- A general never tells the base which chunk it holds. The base reads the world
--- position out of the heartbeat every device already sends and derives the
--- chunk itself, because "I am standing here" is an observation and "I hold this
--- chunk" is an assertion - and the invariant that two loaders never share a
--- chunk is only worth as much as the evidence behind it.
---
--- That is also what makes recovery work without an operator: a general posted
--- to a chunk whose previous holder has gone quiet takes the claim over by
--- arriving, and nothing has to decide that the old one is dead.
---
--- ## Why the miners are not told about generals at all
---
--- A miner receives a quarry over an area. It does not know a general exists, it
--- has no dependency on one, and if every general vanished it would carry on
--- mining exactly as it does today until it left the loaded region - at which
--- point it simply stops executing, which is what it did before any of this. The
--- coupling is entirely on the base, which is where it can be reasoned about.

local coverage = require("domain.fleet.coverage")
local desired = require("domain.fleet.desired")
local grid = require("domain.chunk.grid")
local persist = require("os.server.services.persist")
local registry = require("domain.fleet.registry")
local service = require("os.kernel.service")

local service_ = {}

--- The section this service persists under.
service_.SECTION = "coverage"

--- Seconds between passes.
---
--- Six, matching `reconcile.EVERY`. A pass costs a walk over ten device records
--- and no I/O unless something changed, and the thing it is reacting to - a
--- general arriving, a miner going quiet - happens on the timescale of a turtle
--- flying somewhere.
service_.EVERY = 6

--- How deep a chunk quarry goes, unless the mine says otherwise.
---
--- Bedrock-ish at the bottom and the surface at the top. Taken from the mine
--- plan when there is one, because the plan already carries the surface height
--- somebody measured, and two answers to "where is the ground" is one too many.
service_.TOP = 64
service_.BOTTOM = -59

--- The Y a chunk quarry runs between.
function service_.bounds(context)
  local mine = context.state.mine
  local plan = mine and mine.plan
  if plan and plan.configured then
    return { topY = plan.surfaceY, bottomY = service_.BOTTOM }
  end
  return { topY = service_.TOP, bottomY = service_.BOTTOM }
end

--- Where the base is, in chunks.
---
--- Taken from the mine plan's centre, which is the one coordinate on the server
--- that a person has already been asked for and that means "here". Falling back
--- to the server's own saved position would be better still, and is what happens
--- once `.location` is written by setup - so this reads the locator first and the
--- plan second.
function service_.root(context)
  if context.state[service_.SECTION].root ~= nil then
    return context.state[service_.SECTION].root
  end

  local saved = context.locator and context.locator.saved()
  if type(saved) == "table" and tonumber(saved.x) and tonumber(saved.z) then
    return coverage.setRoot(context.state[service_.SECTION], saved.x, saved.z)
  end

  local mine = context.state.mine
  local plan = mine and mine.plan
  if plan and plan.configured then
    return coverage.setRoot(context.state[service_.SECTION], plan.centreX, plan.centreZ)
  end

  return nil
end

--- Is this device a general, as far as the base can tell?
---
--- The job it reports, not the capability. A turtle with a chunk loader that is
--- currently quarrying is a miner; what makes a general is what it was told to
--- do. Reading the capability instead would have the base re-posting a turtle
--- that somebody deliberately put on something else.
--- `state` is optional and is the third piece of evidence: a device holding a
--- post is a general even in the moment between being told to be one and saying
--- that it is. Without it, a turtle promoted earlier in the same pass reads as a
--- spare miner and is handed a quarry on top of its posting - two orders, one
--- turtle, in one pass.
function service_.isGeneral(record, state)
  local snap = record.snap
  if type(snap) == "table" and snap.job == "general" then
    return true
  end
  local goal = record.desired
  if goal ~= nil and goal.mode == "deploy" and goal.job == "general" then
    return true
  end
  if state ~= nil then
    for _, post in pairs(state.posts) do
      if post.general == record.id then
        return true
      end
    end
  end
  return false
end

--- A turtle that could be a general but has not been given a job.
---
--- The auto-promotion rule, and it is deliberately narrow: it fires only for a
--- parked turtle carrying a chunk loader that the base has no opinion about. A
--- turtle somebody has assigned to anything at all is left alone, because a base
--- that re-tasked a machine an operator had just configured would be a base
--- nobody trusts with a fleet.
function service_.isCandidate(record)
  local snap = record.snap
  if type(snap) ~= "table" or not snap.parked then
    return false
  end
  if snap.chunky ~= true then
    return false
  end
  return record.desired == nil
end

--- Record where a general is standing, and claim the chunk it is in.
---
--- Called for every heartbeat rather than only for generals, because the cheap
--- half - noticing that a device is not one - is a table lookup, and the
--- expensive half only runs for the handful of machines that are.
function service_.observe(context, record, now)
  if not service_.isGeneral(record, context.state[service_.SECTION]) then
    return nil
  end

  local snap = record.snap
  local world = type(snap) == "table" and snap.world or nil
  if type(world) ~= "table" or tonumber(world.x) == nil or tonumber(world.z) == nil then
    -- A general that does not know where it is cannot hold a chunk, because
    -- nobody - including the general - can say which chunk that would be.
    return nil
  end

  local state = context.state[service_.SECTION]
  local cx, cz = grid.of(world.x, world.z)
  local existing = nil
  for key, post in pairs(state.posts) do
    if post.general == record.id then
      existing = key
    end
  end

  -- Standing where it already claims to stand is the common case by far, and it
  -- is a renewal rather than a claim - so it costs a timestamp and no write.
  if existing == grid.key(cx, cz) then
    coverage.renew(state, record.id, now)
    return existing
  end

  local post, why = coverage.claim(state, record.id, cx, cz, now)
  if post == nil then
    return nil, why
  end

  -- A claim is written immediately, for the reason `leases` writes one
  -- immediately: a lost claim is a chunk the server has forgotten is held, and
  -- the next general it dispatches goes to a chunk that already has one in it.
  persist.flush(context, service_.SECTION)
  return grid.key(cx, cz)
end

--- Everything the base wants of the fleet this pass.
---
--- Returns a list of `{ id, mode, job, settings, reason }` rather than setting
--- anything, so a spec can ask "what would this do?" with a table and no radio -
--- the same split every service here makes between the decision and the loop.
function service_.plan(context, now)
  local state = context.state[service_.SECTION]
  local wants = {}

  if service_.root(context) == nil then
    return wants
  end

  coverage.expireMiners(state, now)

  local records = registry.records(context.state.fleet)
  local bounds = service_.bounds(context)

  -- Generals first, so a chunk claimed this pass is available to the miners
  -- assigned in the same one. The other order costs a whole cycle of latency
  -- every time the region grows.
  for _, record in ipairs(records) do
    if registry.health(record, now) ~= "offline" then
      service_.observe(context, record, now)
    end
  end

  for _, record in ipairs(records) do
    if registry.health(record, now) ~= "offline" and service_.isCandidate(record) then
      local post, why = coverage.postFor(state, now)
      if post then
        local px, pz = grid.post(post.cx, post.cz)
        wants[#wants + 1] = {
          id = record.id,
          mode = "deploy",
          job = "general",
          settings = { postX = px, postZ = pz, postY = bounds.topY + 1 },
          reason = ("holding chunk %d, %d"):format(post.cx, post.cz),
        }
        -- Claimed the moment it is offered, not when the turtle arrives.
        -- Without this every candidate in the same pass is sent to the same
        -- chunk, and the invariant would be broken by the base itself.
        coverage.claim(state, record.id, post.cx, post.cz, now)
      elseif why then
        context.coverageReason = why
      end
    end
  end

  -- Then the miners, into whatever is now covered.
  for _, record in ipairs(records) do
    local snap = record.snap
    if
      registry.health(record, now) ~= "offline"
      and not service_.isGeneral(record, state)
      and type(snap) == "table"
      and snap.role ~= nil
    then
      local held = state.miners[tostring(record.id)]

      -- Two cases, and the distinction is what keeps this out of an operator's
      -- way. A device this service already placed is one it may move; a device
      -- carrying somebody else's goal is not, and is skipped entirely rather
      -- than argued with. A device with no goal at all is nobody's decision yet.
      if held ~= nil or record.desired == nil then
        local assignment, isNew = coverage.assign(state, record.id, now)

        -- A running turtle keeps its slot refreshed but is never re-tasked
        -- mid-cycle: `control.apply` would refuse the job change anyway and the
        -- order would sit pending forever, which reads on the Devices page as a
        -- turtle that is ignoring the base.
        if assignment and isNew and snap.parked then
          wants[#wants + 1] = {
            id = record.id,
            mode = "deploy",
            job = "quarry",
            settings = coverage.quarry(assignment, bounds),
            reason = ("quarrying chunk %s, slice %d of %d"):format(
              assignment.chunk,
              assignment.slot,
              coverage.PER_CHUNK
            ),
          }
        elseif assignment and isNew and not snap.parked then
          -- Assigned but not yet ordered. Handing the slot back keeps it
          -- available to a turtle that can actually take it now, and this one
          -- is offered the same chunk the moment it parks.
          coverage.forget(state, record.id)
        end
      end
    end
  end

  return wants
end

--- Turn the plan into desired state.
---
--- `desired.want` bumps a generation only when the goal actually differs, which
--- is what makes this safe to run every six seconds - and why
--- `domain/fleet/coverage.lua` works so hard to return the same assignment twice
--- when nothing has changed.
function service_.pass(context, now)
  local acted = {}
  for _, want in ipairs(service_.plan(context, now)) do
    local record = registry.get(context.state.fleet, want.id)
    if record then
      local _, changed = desired.want(record, want.mode, {
        job = want.job,
        settings = want.settings,
        reason = want.reason,
      }, now)
      if changed then
        acted[#acted + 1] = want
      end
    end
  end

  if #acted > 0 then
    persist.mark(context, "fleet")
  end
  return acted
end

service_.service = service.define({
  id = "coverage",
  requires = { "clock", "state", "storage", "serialise" },

  -- Not critical. A fleet with no coverage service still mines exactly as well
  -- as it does today - it simply stops when nobody is nearby, which is the
  -- condition this exists to improve rather than a condition it creates. Losing
  -- `leases` costs a shaft; losing this costs an unattended night.
  critical = false,

  run = function(context)
    while true do
      service_.pass(context, context.clock.now())
      context.clock.sleep(context.coverageEvery or service_.EVERY)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return service_
