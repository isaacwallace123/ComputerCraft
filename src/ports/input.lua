--- Port: events coming in.
---
--- The mirror of `screen`. Everything the framework knows about a person
--- arrives here, which is what lets a spec drive a whole screen - click this,
--- press tab, scroll there - with no world, no terminal, and no Minecraft.
---
--- ## It hands over raw CC events, not normalised ones
---
--- `pull` returns whatever the event queue produced: `"mouse_click", 1, 12, 4`.
--- Normalising it into the framework's own model is `ui/input.lua`'s job, not
--- the adapter's, and the split matters. A port should translate, never decide.
--- The moment the cc adapter starts deciding that a `monitor_touch` is really a
--- press followed by a release, the sim adapter has to make the same decision
--- the same way or the tests stop meaning anything - and there would then be two
--- copies of a rule that lives properly in one place above both.
---
--- ## `queue` is not a convenience
---
--- A machine has to be able to wake its own event loop: the desktop's
--- `icos_open_app`, a service telling a page its data changed, a timer firing.
--- Without it every one of those needs a side channel and the loop needs a
--- polling timeout to notice them, which is the difference between an idle
--- dashboard costing nothing and costing a wakeup a second.

local contract = require("ports.contract")

local input = {}

input.NAME = "input"

input.METHODS = {
  "pull", -- (timeoutSeconds) -> name, ... | nil on timeout
  "queue", -- (name, ...) -> nil; inject an event for this machine
}

function input.check(impl)
  return contract.check(input.NAME, input.METHODS, impl)
end

--- An input that never reports anything. What a display-only monitor honestly
--- has, and what a headless server runs against - both of which must be able to
--- mount a screen without branching on whether anybody can press anything.
function input.null()
  return contract.null(input.METHODS)
end

return input
