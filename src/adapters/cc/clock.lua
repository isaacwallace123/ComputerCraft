--- Clock port over CC's `os`.

local clock = require("ports.clock")

local adapter = {}

function adapter.new()
  return clock.check({
    --- `os.epoch("utc")` rather than the default "ingame" epoch.
    ---
    --- The in-game clock runs at the world's day length and stops when nobody
    --- is loading the chunk, so two machines comparing timestamps across a
    --- night of nobody being online would disagree by hours. Lease expiry and
    --- "last seen twenty minutes ago" only mean anything against real time.
    now = function()
      return os.epoch("utc")
    end,

    sleep = function(seconds)
      sleep(seconds or 0)
    end,

    --- The world's hour, 0-24, as a fraction.
    ---
    --- `os.time()` with no argument is the *local* in-game time, which is the
    --- one somebody standing next to the computer would agree with. The "utc"
    --- and "ingame" variants answer different questions and neither is the
    --- question a clock in a title bar is asking.
    time = function()
      return os.time()
    end,
  })
end

return adapter
