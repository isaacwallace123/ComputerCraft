--- The client: a machine that draws, and holds no authority.
---
--- §2 of docs/icos-2.md. A client has a screen and a copy of what the server
--- knows. It coordinates nothing, leases nothing and decides nothing, which is
--- the whole reason the `fleet` role was split in two: one machine was drawing
--- the fleet *and* being the fleet, so closing a page stopped the coordination
--- behind it (D018).
---
--- ## Its copy is always out of date and that is fine
---
--- The client mirrors the server's registry rather than sharing it, and the
--- mirror is a few seconds behind. That is not a compromise, it is the honest
--- shape: the server's copy is also a few seconds behind the turtles. Pretending
--- otherwise would mean a page that blocks on a radio round trip to redraw a
--- row, on a machine whose entire job is to redraw rows.
---
--- What the mirror carries is the *age* of every record, so a stale row can say
--- so. §6 again: a device that has gone quiet is the thing worth seeing, and a
--- client that silently showed twenty-minute-old positions as current would hide
--- exactly the fact it exists to surface.
---
--- ## Two services and nothing else
---
--- `sync` keeps the mirror fresh. `screen` draws it. Neither is critical: a
--- client that has lost its server still shows the last thing it knew with the
--- ages ticking up, which is more useful than a blank screen, and a client that
--- has lost its screen is a machine nobody is looking at.
---
--- The supervisor is still worth having for the same reason it is on a turtle: a
--- sync loop that throws must not take the screen down, because the screen is
--- where somebody would find out that sync is throwing.
---
--- ## What starts it
---
--- `startup.lua` on power-up, through `os/kernel/boot.lua`, which maps the role
--- in `.node` onto one of four operating systems. `icos` starts the same thing
--- by hand.

local gps = require("os.kernel.services.gps")
local peer = require("domain.protocol.peer")
local ticker = require("os.kernel.services.ticker")
local reactive = require("ui.state.reactive")
local registry = require("domain.fleet.registry")
local request = require("os.kernel.request")
local service = require("os.kernel.service")
local supervisor = require("os.kernel.supervisor")
local switches = require("os.kernel.switches")
local wire = require("domain.protocol.message")

--- The value every page recomputes from.
---
--- One scope for the machine's whole life, holding one number. It is never
--- destroyed, which is correct rather than a leak: the thing it belongs to is
--- the machine, and the machine stopping is the process ending.
---
--- Owned here rather than by a page, so every page advances together and none of
--- them has to invent a clock of its own - which is what they were all doing,
--- each with a `Value(0)` that nothing incremented.
local function machineTick()
  return reactive.scoped():Value(0)
end

local client = {}

client.PROTOCOL = wire.NAME

--- How often the mirror is refreshed.
---
--- Three seconds. Slower than a turtle's heartbeat, because a person reading a
--- screen cannot use two-second resolution and every refresh is a radio round
--- trip that the server has to answer while doing its real work.
client.SYNC = 3

--- Ask the server for its registry.
---
--- A request rather than a subscription, because a subscription means the server
--- keeping a list of who is listening, and a list of listeners on a machine that
--- reboots is a list that goes stale and gets written to forever. Asking costs
--- one message and cannot leak.
client.REQUEST = "mirror"

--- Fold a mirror reply into the local copy.
---
--- Replaces rather than merges. A merge would let a device the server has
--- forgotten live on in the client forever - and "this turtle no longer exists"
--- is exactly the kind of fact a dashboard must not quietly discard.
---
--- Returns true when something arrived, so the caller can tell a refused reply
--- from an empty fleet.
function client.absorb(context, message)
  -- The client's version gate, and `os/mobile/main.lua` gets it by calling this
  -- function rather than by having its own. One gate per receive path is the
  -- rule; a second copy on the handheld is a second thing to forget to update.
  message = wire.accept(message)
  if message == nil then
    return false
  end
  if message.kind ~= "mirror" or type(message.fleet) ~= "table" then
    return false
  end
  context.state.fleet = message.fleet

  -- Kept only when it arrives. An older server sends a mirror with no policy,
  -- and overwriting the last known one with nil would make the Automation page
  -- flicker to defaults every three seconds - which reads as the server
  -- resetting itself.
  if type(message.policy) == "table" then
    context.state.policy = message.policy
  end
  if type(message.mine) == "table" then
    context.state.mine = message.mine
  end

  -- Same rule, and it matters more here. A mirror arriving from a server with no
  -- bank must not blank the balances a page is showing: "we have not heard"
  -- reads as zero, and zero in a bank is a specific and alarming claim.
  if type(message.bank) == "table" then
    context.state.bank = message.bank
  end
  -- The audit is different: nil is a real answer. It means no vault is named or
  -- the chest is unreachable, and holding on to the last count would leave a
  -- page reporting a chest nobody can see any more.
  context.state.vault = message.vault

  context.syncedAt = context.clock.now()
  return true
end

--- How stale the mirror is, in seconds.
---
--- `math.huge` before the first successful sync, so a client that has never
--- reached its server reads as infinitely stale rather than as perfectly fresh -
--- which is what a zero would mean and is the wrong way round.
function client.staleness(context, now)
  if context.syncedAt == nil then
    return math.huge
  end
  return math.max(0, (now - context.syncedAt) / 1000)
end

--- The rows a page draws.
---
--- Quietest first, because §6: a roster sorted by name buries the one device
--- that has stopped reporting among nine that are fine.
function client.rows(context, now)
  return registry.list(context.state.fleet, now, registry.byStaleness)
end

client.sync = service.define({
  id = "sync",
  requires = { "transport", "clock", "state" },

  -- Not critical. A client that has lost its server still shows the last thing
  -- it knew with the ages ticking up, which is strictly more useful than a
  -- blank screen and is why staleness is on the record rather than implied.
  critical = false,

  run = function(context)
    while true do
      -- Addressed to the server once it has answered once. Every three seconds
      -- forever is the most frequent thing a client does, and as a broadcast it
      -- woke every machine in range to deliver a question one of them wanted.
      peer.send(
        context.peer,
        context.transport,
        wire.stamp({ kind = client.REQUEST }),
        client.PROTOCOL,
        context.clock.now()
      )

      local sender, message, protocol = context.transport.receive(client.PROTOCOL, client.SYNC)
      if sender ~= nil and protocol == client.PROTOCOL then
        peer.remember(context.peer, sender, context.clock.now())
        client.absorb(context, message)
      end
    end
  end,
})

client.screen = service.define({
  id = "screen",
  requires = { "screen", "input", "state" },

  -- Not critical either, which reads oddly for a machine whose job is drawing.
  -- But the alternative is a client that reports unhealthy when a monitor is
  -- unplugged, and the place that report would appear is the monitor.
  critical = false,

  run = function(context)
    return context.draw(context)
  end,
})

function client.services()
  return { client.sync, client.screen, gps.service, ticker.service }
end

--- Build a supervised client, ready to be stepped.
---
--- `options.draw` is the seam: a spec passes a function and no screen, and a
--- machine gets `os/client/desktop.lua`.
---
--- The shell is required *inside* the default rather than at the top of the
--- file, which is the one deliberate piece of laziness here. Requiring it pulls
--- in the whole UI framework and every app it lists, and a headless client -
--- which is what every sync test is - would pay for a screen it never opens.
function client.boot(ports, options)
  options = options or {}

  local sup = supervisor.new({
    clock = ports.clock,
    onError = options.onError,
  })

  local context = {
    clock = ports.clock,
    storage = ports.storage,
    transport = ports.transport,
    screen = ports.screen,
    input = ports.input,
    beacon = ports.beacon,
    locator = ports.locator,
    peripherals = ports.peripherals,
    saveLocation = ports.saveLocation,

    -- A client is a block, like a server. Same answer, same reason.
    anchored = function()
      return true
    end,
    serialise = ports.serialise,
    log = ports.log,

    -- Empty rather than loaded from disk, deliberately. A client's copy is a
    -- mirror, and a mirror that survives a reboot would show a fleet as it was
    -- whenever the machine was last on - which on a monitor in a corner could
    -- be days. Three seconds of blankness is the honest alternative.
    state = { fleet = registry.empty() },

    -- Which computer answered the last mirror request. See
    -- `domain/protocol/peer.lua`: a broadcast is charged to everybody.
    peer = peer.empty(),

    tick = machineTick(),

    -- How a page asks for something to change: over the radio, because a client
    -- owns nothing. The server's own copy of this delivers locally instead, and
    -- the page cannot tell which machine it is on - see `os/kernel/request.lua`.
    request = request.remote(ports.transport, wire.NAME),

    -- The default is the real desktop, not a stub. A client whose screen
    -- service does nothing is a client that boots, reports healthy, and shows a
    -- black rectangle - and the supervisor would be right to call that running.
    -- A spec overrides it; a machine gets the shell.
    draw = options.draw or function(inner)
      return require("os.client.desktop").run(inner, options.shell)
    end,
  }

  for _, definition in ipairs(client.services()) do
    sup:add(definition)
  end

  -- The Services page reads this machine's own supervisor, not the server's.
  -- Attached after construction because the context is what the supervisor is
  -- started with, and a supervisor that held a reference to a context that held
  -- a reference to it is a cycle the serialiser would refuse - which is exactly
  -- the kind of thing that is discovered when a state file stops being written.
  context.supervisor = sup

  -- What somebody switched off on the Services page, last time this machine was
  -- up. Applied before starting, so a service meant to stay off never runs at
  -- all rather than running until the first frame can stop it.
  --
  -- This is what makes a configuration a configuration: a GPS host is a client
  -- with the fleet mirror and the desktop switched off, and until the choice
  -- survived a reboot that was a thing somebody had to redo every restart.
  switches.apply(sup, switches.load(context))

  sup:start(context)

  return { supervisor = sup, context = context, ports = ports }
end

return client
