--- Noticing hardware that arrives while the machine is running.
---
--- ## Why this is not a page's problem
---
--- Every machine discovered its peripherals exactly once, in `boot.lua`, and
--- never looked again. Plug a modem into a running server and it has no radio
--- until somebody reboots it; plug in a disk drive and the Hardware page shows
--- the old list until its next tick, with nothing to say the list is old.
---
--- Neither of those looks broken. A server with a modem in its side and no radio
--- looks exactly like a server whose turtles have wandered out of range, and the
--- fix - reboot it - is not something anyone would think to try, because from
--- the outside nothing changed.
---
--- CC already announces this. `peripheral` and `peripheral_detach` fire on
--- attach and removal with the side that changed. Nothing in ICOS was listening.
---
--- ## What "turn it on" means, per kind
---
--- Only one thing can honestly be switched on from here, and it is the one that
--- matters most: **a modem gets opened**. `transport.open` is idempotent and
--- cheap, so a machine that gains a radio starts using it within a tick, with no
--- reboot and nothing for anybody to notice and act on.
---
--- A monitor is different and this service deliberately does not pretend
--- otherwise. The wall is chosen at boot, its size decides the layout, and its
--- input port is bound to that monitor's name - re-deriving all of it at runtime
--- is a second boot, not a hot-plug. So a new monitor is *reported*, in words,
--- with the one action that will use it. Saying "reboot to use this as a
--- display" is worth more than silently doing nothing, and much more than half
--- mounting it.
---
--- Everything else needs no switching on at all: it is listed the moment the
--- page next computes, which is what the tick is for.

local service = require("os.kernel.service")

local hotplug = {}

--- Events CC raises when the hardware changes.
hotplug.ATTACH = "peripheral"
hotplug.DETACH = "peripheral_detach"

--- Deal with one change. Returns a sentence for the log, or nil.
---
--- Split from the loop so a spec can attach a modem to a fake machine and
--- assert the radio came up, with no event queue anywhere.
function hotplug.changed(context, event, side)
  if type(side) ~= "string" then
    return nil
  end

  if event == hotplug.DETACH then
    -- Nothing to undo. `transport` already checks `rednet.isOpen` before every
    -- send and answers false rather than raising, so a machine whose modem has
    -- been taken off the wall degrades on its own - which is the behaviour a
    -- turtle out of range needs anyway.
    return ("hardware removed: %s"):format(side)
  end

  if event ~= hotplug.ATTACH then
    return nil
  end

  local kinds = hotplug.kindsOf(context, side)

  -- Anything arriving is grounds to try the services that gave up.
  --
  -- `revive` is documented as the operator's "I have fixed it, try again", and
  -- deliberately not on a timer - a supervisor that reset its own counter would
  -- turn "gave up" into "retries forever, slowly". Hardware being plugged in is
  -- not a timer. It is the evidence that the thing the service was failing for
  -- has arrived, which is exactly the judgement a person makes before pressing
  -- it, and the alternative is a base whose radio is open and whose bridge quit
  -- four minutes ago.
  local revived = hotplug.revive(context)

  if kinds.modem and context.transport and context.transport.open then
    -- Idempotent, so a second modem on a machine that already has one open is
    -- a no-op rather than a swap. Which modem is the radio is `transport`'s
    -- decision and it made it at boot; re-deciding here would move a fleet's
    -- radio because somebody hung a wired modem on the back.
    local opened = context.transport.open()
    if revived > 0 then
      return ("modem attached on %s - radio %s, %d service%s restarted"):format(
        side,
        opened and "open" or "not open",
        revived,
        revived == 1 and "" or "s"
      )
    end
    return ("modem attached on %s - radio %s"):format(side, opened and "open" or "not open")
  end

  if kinds.monitor then
    -- Named rather than mounted. The wall's size decides the layout and its
    -- input port is bound to its name, both fixed at boot; standing one up here
    -- would be a second boot wearing a smaller word.
    return ("monitor attached on %s - reboot to use it as a display"):format(side)
  end

  return ("hardware attached: %s (%s)"):format(side, kinds.primary or "unknown")
end

--- What CC says is now on that side.
---
--- Through the port rather than `peripheral.getType`, so this is drivable from a
--- spec - and so a peripheral that is pulled off again between the event and
--- this call is an empty answer rather than an error.
function hotplug.kindsOf(context, side)
  local out = {}
  if context.peripherals == nil then
    return out
  end

  for _, entry in ipairs(context.peripherals.list() or {}) do
    if entry.name == side then
      out.primary = entry.primary
      for kind in pairs(entry.types or {}) do
        out[kind] = true
      end
      return out
    end
  end

  return out
end

--- Start the services that had given up, and say how many.
---
--- Every one of them, not only the ones that named a radio. A service does not
--- record what it was waiting for, and the failures that hardware fixes are not
--- limited to the obvious: GPS needs a modem, the bridge needs a modem, and a
--- page needs a monitor that a person has just walked over and replaced.
---
--- Costs nothing when nothing has failed, which is the normal case.
function hotplug.revive(context)
  local supervisor = context.supervisor
  if supervisor == nil or type(supervisor.health) ~= "function" then
    return 0
  end

  local now = context.clock and context.clock.now() or 0
  local count = 0
  for _, row in ipairs(supervisor:health(now) or {}) do
    if row.gaveUp and supervisor:revive(row.id) then
      count = count + 1
    end
  end
  return count
end

hotplug.service = service.define({
  id = "hotplug",
  requires = { "input" },

  -- Not critical. A machine that stops noticing new hardware still runs the
  -- hardware it booted with, which is every machine in a finished base.
  critical = false,

  run = function(context)
    while true do
      local event, side = context.input.pull()

      if event == hotplug.ATTACH or event == hotplug.DETACH then
        local said = hotplug.changed(context, event, side)
        if said and context.log then
          context.log.info(said)
        end

        -- Wake whatever is drawing. The Hardware page derives its list from the
        -- tick, so without this a machine notices new hardware and shows the
        -- old list until the next second - which is the same staleness this
        -- service exists to remove, just shorter.
        if context.tick then
          context.tick:set(context.tick:get() + 1)
        end
      end

      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return hotplug
