--- Input port over a scripted list of events.
---
--- This is the half of the ports layer that makes a whole screen testable. A
--- spec writes down what a person did - click here, press tab, scroll there -
--- and the framework cannot tell the difference between that and a keyboard.
---
--- Needs no world. `adapters/sim/world.lua` simulates a Minecraft; this
--- simulates a pair of hands, and a UI test wants the second without the first.

local port = require("ports.input")

local adapter = {}

--- A queue that can be written to from either end.
---
--- `push` appends, which is what a script does. `queue` also appends, which is
--- what the code under test does when it wakes its own loop - and the two share
--- one queue on purpose, so that a spec sees an app's own events in the order
--- the app produced them relative to the ones the spec supplied.
function adapter.new(scripted)
  local self = { events = {}, pulls = 0 }

  for _, event in ipairs(scripted or {}) do
    self.events[#self.events + 1] = event
  end

  local impl = {}

  --- Returns nil once the script is exhausted, whatever the timeout says.
  ---
  --- A test that runs out of events is finished, and blocking would hang the
  --- suite rather than fail it. Returning nil makes an over-long run loop
  --- terminate on its own, which is the behaviour that produces a readable
  --- failure instead of a stopped build.
  function impl.pull()
    self.pulls = self.pulls + 1
    local event = table.remove(self.events, 1)
    if not event then
      return nil
    end
    return table.unpack(event)
  end

  function impl.queue(name, ...)
    self.events[#self.events + 1] = { name, ... }
  end

  self.port = port.check(impl)

  --- Append an event, as a person would have caused it.
  function self.push(...)
    self.events[#self.events + 1] = { ... }
    return self
  end

  --- Convenience for the three that every UI test needs.
  function self.click(x, y, button)
    return self.push("mouse_click", button or 1, x, y)
  end

  function self.touch(x, y)
    return self.push("monitor_touch", "monitor_0", x, y)
  end

  function self.press(key)
    return self.push("key", key, false)
  end

  function self.type(char)
    return self.push("char", char)
  end

  function self.scroll(x, y, direction)
    return self.push("mouse_scroll", direction or 1, x, y)
  end

  function self.pending()
    return #self.events
  end

  return self
end

return adapter
