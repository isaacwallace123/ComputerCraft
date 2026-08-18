--- Shared autonomous-mining safety policy.

local fuel = require("device.fuel")
local nav = require("device.nav")

local safety = {}

--- Check whether another potentially outward move is safe.
---
--- Two fuel units are reserved here: one for the move itself and one because
--- that move may increase Manhattan distance from home. Fuel is deliberately
--- not loaded into the tank yet; nav consumes inventory fuel lazily.
function safety.check(ctx, margin, returnDistance)
  local abort = ctx.aborted()
  if abort then
    return false, abort, "recalled"
  end

  local required = (returnDistance or nav.distanceHome()) + margin + 2
  if fuel.available() < required then
    return false, "fuel reserve reached", "fuel"
  end

  return true
end

return safety
