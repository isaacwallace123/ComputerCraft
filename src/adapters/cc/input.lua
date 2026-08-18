--- Input port over CC's event queue.
---
--- `os.pullEvent` blocks until something happens, which is exactly what an idle
--- machine should do - it yields, and every other coroutine on the computer runs.
--- A timeout is implemented with a timer rather than by polling, for the same
--- reason: a loop that woke twenty times a second to ask whether anything had
--- happened would be a busy-wait on a machine that is also running a fleet.

local input = require("ports.input")

local adapter = {}

function adapter.new()
  local impl = {}

  --- Pull the next event, or give up after `timeoutSeconds`.
  ---
  --- Uses `pullEventRaw` so that `terminate` arrives as an ordinary event rather
  --- than as an error thrown through the middle of a frame. A UI that is halfway
  --- through painting when somebody holds Ctrl-T should finish the frame and
  --- then stop, not leave a half-drawn screen and a stack trace.
  function impl.pull(timeoutSeconds)
    if timeoutSeconds == nil then
      return os.pullEventRaw()
    end

    local timer = os.startTimer(timeoutSeconds)
    while true do
      local event = { os.pullEventRaw() }
      if event[1] == "timer" and event[2] == timer then
        return nil
      end
      -- Cancel rather than let it fire later into somebody else's loop. CC has
      -- no way to filter a stray timer by owner, so an uncancelled one arrives
      -- as an anonymous `timer` event that another component may act on.
      os.cancelTimer(timer)
      return table.unpack(event)
    end
  end

  function impl.queue(name, ...)
    os.queueEvent(name, ...)
  end

  return input.check(impl)
end

return adapter
