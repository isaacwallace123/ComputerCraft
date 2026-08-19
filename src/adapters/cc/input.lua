--- Input port over CC's event queue.
---
--- `os.pullEvent` blocks until something happens, which is exactly what an idle
--- machine should do - it yields, and every other coroutine on the computer runs.
--- A timeout is implemented with a timer rather than by polling, for the same
--- reason: a loop that woke twenty times a second to ask whether anything had
--- happened would be a busy-wait on a machine that is also running a fleet.

local input = require("ports.input")

local adapter = {}

--- Build an input port.
---
--- `options.accept(name, ...)` decides whether an event belongs to this port.
--- Absent means everything does, which is what a machine with one screen wants.
---
--- ## Why a filter belongs here rather than in the shell
---
--- A base station runs two screens at once - a keyboard desktop on its terminal
--- and a display-only dashboard on the wall - and the supervisor hands **every**
--- event to **every** service. Without a filter both shells see the same
--- keypress, so typing at the terminal drives the monitor's page as well, and a
--- tap on the wall moves the terminal's selection.
---
--- Filtering at the port rather than in the page is what keeps D020 structural.
--- A display-only surface is one whose input port never yields a keystroke, so
--- there is no code path in any app that could act on one - the same shape as
--- passing no callbacks, one layer down.
function adapter.new(options)
  options = options or {}
  local accept = options.accept

  local impl = {}

  --- Does this event belong to this surface?
  ---
  --- `terminate` always does, whatever the filter says. It is the machine going
  --- down rather than somebody interacting with a screen, and a shell that
  --- filtered it out would keep painting through a Ctrl-T.
  local function mine(event)
    if accept == nil or event[1] == "terminate" then
      return true
    end
    return accept(table.unpack(event)) == true
  end

  --- Pull the next event, or give up after `timeoutSeconds`.
  ---
  --- Uses `pullEventRaw` so that `terminate` arrives as an ordinary event rather
  --- than as an error thrown through the middle of a frame. A UI that is halfway
  --- through painting when somebody holds Ctrl-T should finish the frame and
  --- then stop, not leave a half-drawn screen and a stack trace.
  function impl.pull(timeoutSeconds)
    if timeoutSeconds == nil then
      while true do
        local event = { os.pullEventRaw() }
        if mine(event) then
          return table.unpack(event)
        end
      end
    end

    local timer = os.startTimer(timeoutSeconds)
    while true do
      local event = { os.pullEventRaw() }
      if event[1] == "timer" and event[2] == timer then
        return nil
      end
      if mine(event) then
        -- Cancel rather than let it fire later into somebody else's loop. CC has
        -- no way to filter a stray timer by owner, so an uncancelled one arrives
        -- as an anonymous `timer` event that another component may act on.
        os.cancelTimer(timer)
        return table.unpack(event)
      end
      -- Not ours, and the timer is still running: keep waiting rather than
      -- returning a nil that the host would read as "the session ended".
    end
  end

  function impl.queue(name, ...)
    os.queueEvent(name, ...)
  end

  return input.check(impl)
end

--- Events for the machine's own terminal.
---
--- Everything except a touch on a wall. A monitor tap arriving at the keyboard
--- desktop would move a selection on a screen nobody is looking at, and the two
--- surfaces would fight over which row is highlighted.
function adapter.terminal()
  return adapter.new({
    accept = function(name, ...)
      if name == "monitor_touch" or name == "monitor_resize" then
        return false
      end
      local _ = ...
      return true
    end,
  })
end

--- Events for one named monitor, and nothing else.
---
--- Touches on *this* wall and its own resize. No keys, no characters, no mouse -
--- which is D020 as a property of the port rather than as a branch: a
--- display-only surface is one that cannot be typed at, so no app running on it
--- can act on a keystroke however it was written.
function adapter.monitor(name)
  return adapter.new({
    accept = function(event, surface)
      if event == "monitor_touch" or event == "monitor_resize" then
        return surface == name
      end
      return false
    end,
  })
end

return adapter
