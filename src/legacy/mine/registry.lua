--- ICOS 1's face on the mine registry: the CC clock and the `.mine` file.
---
--- `domain/mine/registry.lua` is pure. It takes `now` as an argument and it
--- neither reads nor writes a file, which is what `domain/` means and what
--- `tools\check.ps1` now enforces with an empty allow list.
---
--- ICOS 1 has neither a clock port nor a storage port and never will - it is
--- being replaced, not upgraded. So the two things the domain module stopped
--- doing are done here instead, once, in a file that is deleted when
--- `legacy/` is.
---
--- ## Why a facade rather than changing the callers
---
--- `legacy/fleet/coordinator.lua` has nineteen call sites and it is the code a
--- running fleet leases every sector through. Threading `os.epoch("utc")`
--- through all nineteen would be nineteen chances to pass the wrong thing to
--- the wrong argument position in the module that decides whether two turtles
--- get the same shaft. One file that adds the same argument in one place cannot
--- have that bug, and the diff on the live path stays a changed `require`.
---
--- ## Every name is re-exported explicitly
---
--- An `__index` metatable would be shorter and would forward the pass-through
--- functions for free. It is not used, because a forwarded name is invisible to
--- the type checker and to a person reading this file: "what does ICOS 1 still
--- use the mine registry for" should be answerable by reading it, and the
--- answer is the list below.

local config = require("adapters.cc.config")
local registry = require("domain.mine.registry")

local mine = {}

mine.PATH = registry.PATH
mine.LEASE_SECONDS = registry.LEASE_SECONDS

--- The one clock ICOS 1 has.
---
--- Named rather than inlined at six call sites so there is exactly one place
--- that says which clock the ICOS 1 base measures leases against. That was the
--- bug behind two turtles in one shaft: stamps taken from one clock and
--- compared against another.
local function now()
  return os.epoch("utc")
end

function mine.empty()
  return registry.empty()
end

function mine.normalise(state)
  return registry.normalise(state)
end

--- Read `.mine`, normalised.
---
--- Normalising on the way in rather than trusting the file is not defensive
--- padding: a plan written by an older build has fields this one divides by,
--- and `plan.capacity` on a raw decoded table is arithmetic on nil the first
--- time a turtle asks for a sector.
function mine.load()
  return registry.normalise(config.load(registry.PATH, registry.empty()))
end

function mine.save(state)
  config.save(registry.PATH, state)
end

--- Place or reshape the mine. No clock involved, so a straight pass-through.
function mine.configure(state, fields)
  return registry.configure(state, fields)
end

function mine.expire(state)
  return registry.expire(state, now())
end

function mine.claim(state, turtleId, workKey, preferredIndex, localFrontier)
  return registry.claim(state, turtleId, workKey, preferredIndex, localFrontier, now())
end

function mine.report(state, turtleId, index, workKey, frontier, blocks, exhausted)
  return registry.report(state, turtleId, index, workKey, frontier, blocks, exhausted, now())
end

function mine.surface(state, turtleId, index, report)
  return registry.surface(state, turtleId, index, report, now())
end

function mine.surfaceOf(state, index)
  return registry.surfaceOf(state, index)
end

function mine.exposed(state)
  return registry.exposed(state)
end

function mine.renew(state, turtleId, index, workKey)
  return registry.renew(state, turtleId, index, workKey, now())
end

function mine.release(state, turtleId, index)
  return registry.release(state, turtleId, index)
end

function mine.summary(state)
  return registry.summary(state, now())
end

return mine
