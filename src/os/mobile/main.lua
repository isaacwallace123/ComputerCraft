--- The mobile: a pocket computer, which is a client that keeps going out of range.
---
--- §2 of docs/icos-2.md. A Pocket Computer holds no authority, has a small
--- screen, and spends a good part of its life somewhere the base cannot hear it.
--- Structurally it is a client, and this file is deliberately thin because of
--- that - it reuses `os/client/main.lua` wholesale and changes the three things
--- that are actually different.
---
--- ## What is actually different
---
--- **It goes out of range, routinely.** A monitor on a wall either can reach the
--- server or has a broken modem. A pocket computer in somebody's inventory is
--- out of range every time they walk into a cave, and coming back is the normal
--- case rather than a recovery. So a failed sync is not worth reporting and the
--- interval backs off while it is failing - a handheld that retried every three
--- seconds forever would be a handheld with a flat battery and a hot chunk.
---
--- **Its screen is 26x20.** Which is not a smaller version of a monitor, it is a
--- different layout, and pretending otherwise is how a fleet page ends up with
--- three visible rows and a horizontally scrolling table. The framework already
--- handles that: the page decides, not this file.
---
--- **It is the machine somebody is holding when something has gone wrong.** The
--- staleness of the mirror matters more here than anywhere else, because the
--- person reading it is standing in a cave wondering where a turtle went. A
--- pocket computer that showed a twenty-minute-old position as current would be
--- actively sending somebody to the wrong place.
---
--- ## What is not different, and was tempting
---
--- It does not get authority "because it is the thing you are holding". A pocket
--- computer that could lease sectors would be a coordinator that walks out of
--- range, and D018 is exactly the lesson that coordination must not live
--- somewhere that can disappear. It asks the server, like every other client.
---
--- ## What starts it
---
--- `startup.lua` on power-up, through `os/kernel/boot.lua`, which maps the role
--- in `.node` onto one of four operating systems. `icos` starts the same thing
--- by hand.

local client = require("os.client.main")
local service = require("os.kernel.service")
local supervisor = require("os.kernel.supervisor")
local wire = require("domain.protocol.message")

local mobile = {}

mobile.PROTOCOL = client.PROTOCOL
mobile.REQUEST = client.REQUEST

--- Seconds between syncs while the server is answering.
---
--- Slower than a wall-mounted client's three, because nobody reads a handheld
--- continuously - it comes out of a pocket, gets looked at, and goes back.
mobile.SYNC = 5

--- The longest gap between attempts once it has gone quiet.
---
--- Thirty seconds. Long enough that a pocket computer left in a chest is not
--- transmitting all night; short enough that walking back into range is noticed
--- inside the time it takes to look at the screen.
mobile.MAX_BACKOFF = 30

--- How long to wait before the next attempt, given how many have failed.
---
--- Doubling, capped. Deliberately not the supervisor's backoff: that one exists
--- for a service that is *broken* and counts towards giving up, and being out of
--- range is neither. A handheld that reported unhealthy for walking into a cave
--- would be reporting the world rather than itself.
function mobile.backoff(misses)
  if misses <= 0 then
    return mobile.SYNC
  end
  local wait = mobile.SYNC * 2 ^ math.min(misses, 8)
  return math.min(wait, mobile.MAX_BACKOFF)
end

mobile.sync = service.define({
  id = "sync",
  requires = { "transport", "clock", "state" },

  -- Not critical, and more emphatically so than on a client. Out of range is
  -- this machine's normal condition, not a fault.
  critical = false,

  run = function(context)
    while true do
      context.transport.broadcast(wire.stamp({ kind = mobile.REQUEST }), mobile.PROTOCOL)
      local sender, message, protocol = context.transport.receive(mobile.PROTOCOL, mobile.SYNC)

      local heard = sender ~= nil
        and protocol == mobile.PROTOCOL
        and client.absorb(context, message)

      if heard then
        context.misses = 0
      else
        context.misses = (context.misses or 0) + 1
        -- Only the extra wait. The receive above has already burned `SYNC`
        -- seconds listening, and sleeping the full backoff on top of that would
        -- make the actual interval twice what this function says it is.
        local extra = mobile.backoff(context.misses) - mobile.SYNC
        if extra > 0 then
          context.clock.sleep(extra)
        end
      end
    end
  end,
})

function mobile.services()
  return { mobile.sync, client.screen }
end

--- Build a supervised mobile, ready to be stepped.
---
--- Reuses the client's context wholesale and swaps the service list. Everything
--- a page reads - `client.rows`, `client.staleness` - works unchanged, which is
--- the point: a Fleet page written for a monitor runs on a pocket computer
--- because the data underneath it is identical and only the layout is not.
function mobile.boot(ports, options)
  options = options or {}

  -- The shell needs to know it is on a handheld, or it offers the desktop's
  -- apps on a 26x20 screen. Filled in rather than required from the caller,
  -- because a mobile that had to be told it was mobile would be a mobile that
  -- worked until somebody forgot.
  options.shell = options.shell or {}
  options.shell.role = options.shell.role or "mobile"
  options.shell.surface = options.shell.surface or "handheld"

  local machine = client.boot(ports, options)

  -- Rebuilt rather than adjusted. A supervisor with the client's `sync` already
  -- registered would either run both loops - two radios asking the same
  -- question - or need a remove, and a supervisor that can remove a service is
  -- a supervisor whose service list changes at runtime, which is a machine
  -- whose shape cannot be read off one function.
  local sup = supervisor.new({
    clock = ports.clock,
    onError = options.onError,
  })
  for _, definition in ipairs(mobile.services()) do
    sup:add(definition)
  end
  machine.context.supervisor = sup
  sup:start(machine.context)

  machine.supervisor = sup
  return machine
end

return mobile
