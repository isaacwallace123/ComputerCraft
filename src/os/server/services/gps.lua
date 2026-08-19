--- The constellation beacon.
---
--- §2 folds the `gps` role into the server, because a GPS host already has to be
--- always-on and already has to know exactly where it is - which is the
--- definition of a server. A dedicated machine that does nothing but answer
--- pings was a role in ICOS 1 and is a service here.
---
--- ## It refuses to guess
---
--- A GPS host that is wrong is worse than no host at all. A missing host makes
--- `gps.locate` return nil, and every caller in this codebase treats nil as "I
--- do not know" and falls back to dead reckoning. A host announcing the wrong
--- position makes `gps.locate` return a confident number, and a turtle that
--- believes it is thirty blocks from where it is will drive into a wall and
--- keep going.
---
--- So this serves only what `locator.saved` reports - what a person entered at
--- setup - and never what `locator.gps` returns. Serving a GPS fix would let a
--- constellation bootstrap itself off its own error, and the error would drift
--- with every host that joined.
---
--- ## It fails loudly rather than parking quietly
---
--- No wireless modem, or no saved position, and this raises. That is deliberate,
--- and the alternative was tempting: sleep forever, report "running", let the
--- machine look healthy. A service that is running and doing nothing is the
--- worst of the three states, because the health page - the one place somebody
--- looks when turtles cannot find themselves - would be showing green.
---
--- Raising puts it through the supervisor's backoff, so a modem attached in the
--- next minute is picked up without a reboot, and after that it gives up with
--- the reason attached and the server reports unhealthy. A base with no wireless
--- modem cannot reach a turtle either, so unhealthy is the honest answer.

local service = require("os.kernel.service")

local gps = {}

--- How long a single answer waits before the loop comes round again.
---
--- Short, because the loop body is the only place this service can notice it has
--- been told to stop. Long enough that an idle constellation is not a busy poll.
gps.WAIT = 2

--- What this server should tell the world it is.
---
--- Returns nil and a reason rather than a position when it must not answer, and
--- every reason here is a configuration problem with an action attached rather
--- than a fault.
function gps.position(context)
  local saved = context.locator.saved()
  if type(saved) ~= "table" then
    return nil, "this machine has no saved position - run `commands/locate` on this machine"
  end
  local x, y, z = tonumber(saved.x), tonumber(saved.y), tonumber(saved.z)
  if x == nil or y == nil or z == nil then
    return nil, "the saved position is incomplete - run `commands/locate` on this machine"
  end
  return { x = x, y = y, z = z }
end

gps.service = service.define({
  id = "gps",
  requires = { "beacon", "locator" },

  -- Critical. Four hosts have to answer for anything in the world to get a fix,
  -- so one going quiet degrades navigation for every turtle in range - and the
  -- symptom is a turtle that cannot confirm where it is, which is the failure
  -- everything else in the fleet is built to avoid.
  critical = true,

  run = function(context)
    local position, reason = gps.position(context)
    if position == nil then
      context.gpsReason = reason
      error(reason, 0)
    end

    local opened, detail = context.beacon.open()
    if not opened then
      context.gpsReason = detail or "no wireless modem"
      error(context.gpsReason, 0)
    end

    context.gpsPosition = position
    context.gpsReason = nil

    while true do
      context.beacon.answer(position, gps.WAIT)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return gps
