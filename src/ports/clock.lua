--- Port: time.
---
--- `now` is wall-clock milliseconds, matching `os.epoch("utc")` rather than
--- `os.clock`. Two reasons. Lease expiry, heartbeat staleness, and "last seen"
--- are all comparisons between machines, and only an absolute epoch survives
--- that; and `os.clock` on a CC computer resets on reboot, which is exactly the
--- moment those numbers matter most.
---
--- `sleep` is in seconds because every caller already thinks in seconds and CC
--- rounds up to the nearest tick (0.05s) regardless of what it is handed.

local contract = require("ports.contract")

local clock = {}

clock.NAME = "clock"

clock.METHODS = {
  "now", -- () -> milliseconds since the epoch, UTC
  "sleep", -- (seconds) -> nil; yields for at least that long
}

function clock.check(impl)
  return contract.check(clock.NAME, clock.METHODS, impl)
end

--- A clock frozen at zero that never waits. Time only moves when a test moves
--- it, so use `adapters.sim.clock` if the behaviour under test cares.
function clock.null()
  return contract.null(clock.METHODS, { now = 0 })
end

return clock
