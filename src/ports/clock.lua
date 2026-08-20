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
  "time", -- () -> the world's hour as 0-24, or nil where there is no world
}

function clock.check(impl)
  return contract.check(clock.NAME, clock.METHODS, impl)
end

--- `time` is the *other* clock, and the two are not interchangeable.
---
--- `now` is real time and is what every comparison between machines uses, for
--- the reasons above. `time` is the in-game hour, which runs at the world's day
--- length and stops when nobody is loading the chunk - useless for a lease and
--- exactly right for a bar that says what time it is, because the person
--- reading it is standing in the world rather than in UTC.
---
--- Nil where there is no world: a spec, a simulated run, anything that is not a
--- computer in Minecraft. A caller draws nothing rather than drawing a zero,
--- because midnight and "no clock" are different facts.

--- A clock frozen at zero that never waits. Time only moves when a test moves
--- it, so use `adapters.sim.clock` if the behaviour under test cares.
function clock.null()
  return contract.null(clock.METHODS, { now = 0 })
end

return clock
