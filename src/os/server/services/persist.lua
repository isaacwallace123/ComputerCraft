--- Writing state to disk, and mostly not writing it.
---
--- The registry changes on every heartbeat. Ten turtles at one heartbeat every
--- two seconds is five writes a second, and a CC filesystem write is a real file
--- operation on the host - so the naive version turns a base station into a disk
--- thrash and spends its scheduling slice (§2 of ui-framework.md) on I/O nobody
--- asked for.
---
--- So this service's actual job is to *not* write. It batches: something marks
--- the state dirty, and at most once every few seconds the dirty things are
--- written.
---
--- ## What a crash costs
---
--- At most one interval of heartbeats, and that is the right trade. Everything
--- lost is re-reported by the devices themselves within a minute - a heartbeat
--- is a fact about now, not a ledger entry. The one thing that is *not*
--- re-reported is a device's last known position while it is missing, which is
--- exactly the case §6 cares about; so `mark` is called on a position change and
--- the interval is short enough that the window is a few seconds of a search
--- that was already twenty minutes old.
---
--- Drop-offs are different: a person edited those, nothing will re-report them,
--- and there are none of them per second. They are written immediately.

local service = require("os.service")

local persist = {}

--- Seconds between writes of a batched section.
---
--- Five: shorter than the sixty seconds that makes a device "offline", so a
--- server restart cannot lose a device's transition from online to missing,
--- which is the transition worth keeping.
persist.EVERY = 5

--- Sections that batch, against those written the moment they change.
---
--- The test is not importance, it is whether anything else in the world holds a
--- copy. A registry can be rebuilt from the devices themselves; a drop-off list
--- exists nowhere but this disk.
persist.BATCHED = { fleet = true }

--- Note that a section has changed.
function persist.mark(context, section)
  context.dirty = context.dirty or {}
  context.dirty[section] = true
end

--- Write one section now, regardless of the batch timer.
function persist.flush(context, section)
  local path = context.paths[section]
  local value = context.state[section]
  if path == nil or value == nil then
    return false
  end
  local ok = context.storage.write(path, context.serialise.encode(value))
  if ok then
    context.dirty = context.dirty or {}
    context.dirty[section] = nil
    context.wroteAt = context.wroteAt or {}
    context.wroteAt[section] = context.clock.now()
  end
  return ok
end

--- Sections that should be written right now.
---
--- Separated from the writing so a spec can ask "what would be written?" without
--- a filesystem, and so the timing rule is one function rather than an `if`
--- buried in a loop.
function persist.due(context, now)
  local ready = {}
  for section in pairs(context.dirty or {}) do
    if not persist.BATCHED[section] then
      ready[#ready + 1] = section
    else
      local last = (context.wroteAt or {})[section]
      local elapsed = last == nil and math.huge or (now - last) / 1000
      if elapsed >= (context.persistEvery or persist.EVERY) then
        ready[#ready + 1] = section
      end
    end
  end
  table.sort(ready)
  return ready
end

function persist.pass(context, now)
  local written = 0
  for _, section in ipairs(persist.due(context, now)) do
    if persist.flush(context, section) then
      written = written + 1
    end
  end
  return written
end

persist.service = service.define({
  id = "persist",
  requires = { "storage", "clock", "state", "serialise" },

  -- Critical. A server that has stopped writing looks perfectly healthy right up
  -- until it reboots, at which point it has forgotten where every missing turtle
  -- was - which is the one thing §6 exists to remember. Silent data loss is the
  -- case the health model is most worth spending on.
  critical = true,

  run = function(context)
    while true do
      persist.pass(context, context.clock.now())
      context.clock.sleep(1)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return persist
