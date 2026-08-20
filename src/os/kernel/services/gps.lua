--- Every machine carries coordinates, and every machine that can be trusted
--- with them serves the constellation.
---
--- It lives in `os/kernel/services/` rather than under one operating system
--- because all four run it. That is the change: GPS was a server-only service,
--- which meant a world needed four dedicated always-on computers before anything
--- else could find itself, and every turtle and pocket computer was a consumer
--- that gave nothing back.
---
--- Now a machine that boots, locates itself, and stands still is a host. The
--- constellation grows with the fleet.
---
--- ## On boot it asks before it answers
---
--- `refresh` tries `locator.gps` first and writes the result down. A machine
--- that was moved, or replaced, or set up by somebody reading the wrong F3 line,
--- corrects itself the moment there are four hosts to ask - and a machine with
--- no constellation to ask keeps the position it had, which is the only answer
--- available and the one a person entered.
---
--- The order matters: locate, *then* serve. Serving first would put a stale
--- position into the constellation for as long as the fix took, and the machines
--- listening are exactly the ones that cannot tell.
---
--- ## Why `domain/gps/host.lua` decides and this does not
---
--- The rule that a turtle serves only while parked is worth a spec, and a rule
--- inside a `while true` is a rule nobody can test. So this asks and obeys.

local host = require("domain.gps.host")
local service = require("os.kernel.service")

local gps = {}

--- How long a single answer waits before the loop comes round again.
---
--- Short, because the loop body is the only place this service can notice it has
--- been told to stop. Long enough that an idle constellation is not a busy poll.
gps.WAIT = 2

--- How often a serving machine re-checks whether it still may.
---
--- A turtle parks and deploys many times an hour, and each transition changes
--- whether it is allowed to answer. Ten seconds is far shorter than the time it
--- takes a turtle to leave the area it was parked in.
gps.RECHECK = 10

--- Ask the constellation where we are, and write it down if it disagrees.
---
--- Returns the position and what happened, so a caller can print "confirmed" or
--- "corrected" rather than the same word for both.
---
--- A failed fix is not an error. Four hosts have to answer, and on a fresh world
--- there are none - which is exactly when somebody is setting the first four by
--- hand.
function gps.refresh(context)
  local saved = context.locator.saved()

  local x, y, z = context.locator.gps(2)
  if x == nil then
    return saved, "no constellation"
  end

  local fresh = { x = x, y = y, z = z }
  local changed, why = host.changed(saved, fresh)
  if not changed then
    return saved, "confirmed"
  end

  local merged = host.merge(saved, fresh)
  if context.saveLocation then
    context.saveLocation(merged)
  end
  return merged, why
end

--- What this machine would answer with right now, or nil and why not.
---
--- `context.anchored` is a **function**, not a flag, because the answer changes
--- between one call and the next: a turtle parks and deploys many times an hour,
--- and a flag read once at boot would have it serving its home position from
--- halfway down a shaft.
---
--- Each composition root supplies its own. A server and a client are blocks and
--- say yes; a turtle says "only while parked"; a mobile says no and gives the
--- reason. Absent, the answer is no - a machine that has not said whether it can
--- vouch for its position has not said yes.
function gps.position(context)
  local anchored, why = false, "this machine cannot tell whether it has moved"
  if type(context.anchored) == "function" then
    anchored, why = context.anchored()
  end

  local ok, reason = host.mayServe({
    position = context.locator.saved(),
    anchored = anchored,
    why = why,
    modem = true,
  })
  if not ok then
    return nil, reason
  end
  return context.locator.saved()
end

gps.service = service.define({
  id = "gps",
  requires = { "beacon", "locator" },

  -- Not critical, which is a change and a deliberate one.
  --
  -- It was critical when one machine hosted GPS for the whole fleet: that
  -- machine going quiet broke navigation for everybody, so it deserved to make
  -- the base report unhealthy. Now every machine hosts, so any one of them being
  -- unable to - a turtle that is mining, a pocket computer nobody has located -
  -- is ordinary rather than a fault. A fleet needs four; it does not need this
  -- one.
  --
  -- Reporting a mining turtle as unhealthy because it is not currently a GPS
  -- host would make `healthy` mean nothing on the machines that move.
  critical = false,

  run = function(context)
    -- Locate before serving. See the header: a stale position handed to the
    -- constellation is worse than no position, and the machines listening are
    -- the ones least able to tell.
    local located, note = gps.refresh(context)
    context.gpsNote = note
    context.gpsPosition = located

    local opened, detail = context.beacon.open()
    if not opened then
      context.gpsReason = detail or "no wireless modem"
      -- Returning rather than raising. A machine with no wireless modem is a
      -- perfectly good machine that cannot be a host, and on a fleet where every
      -- device runs this that is a configuration fact rather than a failure -
      -- the supervisor reports it as stopped and nothing else changes.
      return
    end

    while true do
      local position, reason = gps.position(context)
      context.gpsReason = reason

      if position then
        context.beacon.answer(position, gps.WAIT)
      else
        -- Still here, still not answering. A turtle that is mining will park
        -- again, and re-checking is cheaper than restarting a service.
        context.clock.sleep(gps.RECHECK)
      end

      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return gps
