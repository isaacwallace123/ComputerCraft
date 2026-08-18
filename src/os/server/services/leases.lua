--- Sector leasing: who is allowed to be in which shaft.
---
--- The ICOS 2 half of what `legacy/fleet/coordinator.lua` does today. The rules are all
--- in `domain/mine/registry.lua` and are not restated here; this is the service
--- that owns the state, answers requests about it, and expires leases nobody is
--- renewing.
---
--- ## Why this is a service and not part of an app
---
--- D018, and it is the clearest case in the codebase. Sector leasing used to
--- live inside the Fleet page, so closing the page stopped two turtles being
--- kept out of the same shaft - a UI decision silently became a mining
--- collision. §4's rule exists because of this file: services own state, apps
--- read it.
---
--- ## It does not own the radio
---
--- `discovery` does. Only one loop can call `transport.receive`, because a
--- received message is consumed - two services polling the same protocol would
--- each silently eat half the fleet's traffic, and both would look healthy while
--- doing it. So `handle` is registered on the server's single inbox, and this
--- service's own loop does only the work that is genuinely timer-shaped:
--- expiring leases whose holder has gone quiet.
---
--- ## Claims are written immediately, reports are not
---
--- The opposite of the device registry, and for a reason worth stating. A lost
--- report costs a few blocks of re-counted progress and the turtle re-reports
--- within seconds. A lost *claim* is a sector the server has forgotten is
--- occupied, and the next turtle to ask for work can be sent down a shaft that
--- already has a turtle in it. One is arithmetic; the other is two turtles in
--- one hole.
---
--- The cost of writing immediately is nothing: a claim happens when a turtle
--- finishes a sector, which is minutes apart, while reports arrive constantly.

local persist = require("os.server.services.persist")
local plan = require("domain.mine.plan")
local registry = require("domain.mine.registry")
local service = require("os.kernel.service")

local leases = {}

leases.PROTOCOL = "icos"

--- The message kind that carries a mine request.
---
--- The *body* is deliberately the same shape ICOS 1 sends - `action`, `sector`,
--- `workKey`, `frontier` - and only the envelope is new. A turtle being ported
--- to ICOS 2 changes how it addresses the letter, not what it writes inside,
--- which keeps the diff on the device small enough to read in one sitting.
leases.MINE = "mine"

--- The section name this service persists under.
leases.SECTION = "mine"

--- How often stale leases are swept.
---
--- Well under `registry.LEASE_SECONDS`, because the sweep is what turns "the
--- holder went quiet fifteen minutes ago" into "this sector is available", and a
--- turtle that asks for work in between is told there is none.
leases.SWEEP = 30

local function refuse(body, message)
  return { kind = "mine_result", ok = false, requestId = body.requestId, message = message }
end

--- Hand a turtle a sector to work.
function leases.claim(context, state, sender, body, now)
  if not state.plan.configured then
    return refuse(body, "no mine configured at base - run `mine here` on the console")
  end

  local index, work = registry.claim(state, sender, body.workKey, body.sector, body.frontier, now)
  if not index or type(work) ~= "table" then
    -- `work` is the reason string when the claim failed. Passing it straight
    -- through means the turtle's own log says why, rather than saying "no" and
    -- leaving the explanation on a screen nobody is standing in front of.
    return refuse(body, work)
  end

  persist.flush(context, leases.SECTION)

  return {
    kind = "mine_result",
    ok = true,
    requestId = body.requestId,
    plan = state.plan,
    sector = index,
    frontier = work.frontier or 0,
    -- What the fleet already knows about this shaft head, so a replacement
    -- turtle does not re-survey ground somebody has already surveyed and, more
    -- importantly, knows before it arrives that there may be a hundred-block
    -- drop waiting there.
    surface = registry.surfaceOf(state, index),
    describe = plan.describe(state.plan, index),
  }
end

--- Record progress down a shaft.
function leases.report(context, state, sender, body, now)
  local index = math.floor(tonumber(body.sector) or 0)
  if index < 1 then
    return nil
  end

  local recorded, work = registry.report(
    state,
    sender,
    index,
    body.workKey,
    body.frontier,
    body.blocks,
    body.exhausted,
    now
  )
  if not recorded then
    return refuse(body, work)
  end

  -- Batched. Progress is re-reported continuously and a crash costs a few blocks
  -- of double-counted footage, which is the cheap half of the trade this file's
  -- header describes.
  persist.mark(context, leases.SECTION)

  return {
    kind = "mine_result",
    ok = true,
    requestId = body.requestId,
    exhausted = work.exhausted == true,
  }
end

--- Record what a turtle saw at a shaft head.
function leases.surface(context, state, sender, body, now)
  local index = math.floor(tonumber(body.sector) or 0)
  if index < 1 then
    return nil
  end

  local recorded, surface = registry.surface(state, sender, index, body, now)
  if not recorded then
    return refuse(body, surface)
  end

  -- Immediate, like a claim. An open shaft head is a hole a player can fall
  -- into, and it is the one fact here that nothing in the world will re-report
  -- if the server forgets it: the turtle that saw it has moved on.
  persist.flush(context, leases.SECTION)

  return { kind = "mine_result", ok = true, requestId = body.requestId, surface = surface }
end

--- Give a sector back without marking progress.
function leases.release(context, state, sender, body)
  local index = math.floor(tonumber(body.sector) or 0)
  if index < 1 then
    return nil
  end
  registry.release(state, sender, index)
  persist.flush(context, leases.SECTION)
  return { kind = "mine_result", ok = true, requestId = body.requestId }
end

--- Keep a working turtle's lease alive from its heartbeat.
---
--- `registry.renew` returns false unless the lease is actually getting old,
--- which is what stops a two-second heartbeat becoming a two-second disk write.
--- A parked turtle is skipped: parking is how a turtle says it has stopped, and
--- a stopped turtle holding a sector for fifteen more minutes is fifteen minutes
--- of a shaft nobody else can use.
function leases.renew(context, sender, snapshot)
  if type(snapshot) ~= "table" or snapshot.parked then
    return false
  end
  local index = math.floor(tonumber(snapshot.sector) or 0)
  if index < 1 then
    return false
  end
  local state = context.state[leases.SECTION]
  if registry.renew(state, sender, index, snapshot.workKey, context.clock.now()) then
    persist.mark(context, leases.SECTION)
    return true
  end
  return false
end

--- Answer a mine request.
---
--- Returns a reply table, or nil when the message is not one of ours. Every
--- failure is a reply with `ok = false` rather than silence: a turtle waits
--- about three seconds for this and then falls back to its cached plan, so "no"
--- arriving promptly is worth more than a correct answer arriving after the
--- turtle has stopped listening.
function leases.handle(context, sender, message)
  if type(message) ~= "table" then
    return nil
  end

  -- A lease is renewed from ordinary status traffic, which is why this service
  -- looks at a message kind it does not otherwise care about. A working turtle
  -- says where it is every two seconds; making it *also* send "and I still want
  -- my sector" would be a second message carrying what the first already said.
  if message.kind == "status" then
    leases.renew(context, sender, message.snapshot)
    return nil
  end

  if message.kind ~= leases.MINE or type(message.body) ~= "table" then
    return nil
  end

  local body = message.body
  local state = context.state[leases.SECTION]
  local now = context.clock.now()

  if body.action == "claim" then
    return leases.claim(context, state, sender, body, now)
  elseif body.action == "report" then
    return leases.report(context, state, sender, body, now)
  elseif body.action == "surface" then
    return leases.surface(context, state, sender, body, now)
  elseif body.action == "release" then
    return leases.release(context, state, sender, body)
  end

  return nil
end

--- Drop leases whose holder has gone quiet, returning how many were released.
function leases.sweep(context)
  local released = registry.expire(context.state[leases.SECTION], context.clock.now())
  if released > 0 then
    persist.flush(context, leases.SECTION)
  end
  return released
end

leases.service = service.define({
  id = "leases",
  requires = { "clock", "state", "storage", "serialise" },

  -- Critical. Without this every turtle either mines nothing or mines the same
  -- sector as its neighbour, and the second is worse than the first because it
  -- looks like it is working.
  critical = true,

  run = function(context)
    while true do
      leases.sweep(context)
      context.clock.sleep(context.sweepSeconds or leases.SWEEP)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return leases
