--- The server: authoritative state, and the services that maintain it.
---
--- §2 of docs/icos-2.md. A server is a permanently loaded advanced computer that
--- holds the device registry, the desired state, the mine, the drop-offs, and
--- hosts GPS. The `gps` role disappears into it, because a GPS host already has
--- to be always-on and already has to know exactly where it is.
---
--- ## A composition root and nothing else
---
--- This file wires ports to services and hands both to the supervisor. It
--- contains no logic worth testing, which is the point: everything that decides
--- anything lives in `domain/`, and everything that loops lives in a service
--- whose decisions are a separate function. If this file ever grows a rule, the
--- rule is in the wrong place.
---
--- ## What starts it
---
--- `startup.lua` on power-up, through `os/kernel/boot.lua`, which maps the role
--- in `.node` onto one of four operating systems. `icos` starts the same thing
--- by hand.

local bridge = require("os.server.services.bridge")
local coverage = require("domain.fleet.coverage")
local coverageService = require("os.server.services.coverage")
local depotList = require("domain.depot.list")
local discovery = require("os.server.services.discovery")
local gps = require("os.server.services.gps")
local leases = require("os.server.services.leases")
local logrotate = require("os.server.services.logrotate")
local mine = require("domain.mine.registry")
local persist = require("os.server.services.persist")
local policy = require("os.server.services.policy")
local reconcile = require("os.server.services.reconcile")
local registry = require("domain.fleet.registry")
local service = require("os.kernel.service")
local supervisor = require("os.kernel.supervisor")

local server = {}

--- Where each piece of state is persisted.
---
--- Separate files rather than one, because they are written at different rates
--- and by different services. The registry changes on every heartbeat; the
--- drop-off list changes when a person edits it, perhaps monthly. One file would
--- mean rewriting the depots ten times a minute, and a crash during that write
--- would risk a list that has nothing to do with the thing being saved.
--- `.mine` is shared with ICOS 1 rather than renamed, which is the opposite
--- choice from `.fleet2` and deliberate. The registry has a different shape in
--- ICOS 2, so sharing that name would mean a rollback reading a roster it cannot
--- parse. The mine has the *same* shape - `domain/mine/registry.lua` is the
--- ICOS 1 file, moved - so sharing the name means a rollback keeps every sector
--- lease and every surveyed shaft head. Only one of the two servers is ever
--- running, because `startup.lua` picks one, so there is no question of both
--- writing it at once.
server.PATHS = {
  fleet = ".fleet2",
  depots = ".depots",
  mine = mine.PATH,
  -- Chunk claims. Its own file rather than a section of `.fleet2` for the
  -- reason every other one is separate: it is written when a general arrives,
  -- which is minutes apart, while the registry is written every few seconds -
  -- and a claim lost to a crash during somebody else's write is a chunk the
  -- server has forgotten is occupied.
  coverage = ".coverage",
}

--- The state a server holds, empty.
---
--- `.fleet2` rather than `.fleet`, deliberately. The ICOS 1 roster lives in
--- `.fleet` and has a different shape; sharing the filename would mean a
--- downgrade reading an ICOS 2 registry as a roster and finding every device
--- malformed. Two files, and a rollback is just a rollback.
--- How a section read off disk is made safe to use.
---
--- Only the sections that need it. A device registry rebuilds itself from the
--- next heartbeat, so a malformed one costs a minute; a mine plan does not
--- rebuild from anything, so a malformed one is arithmetic on nil.
server.NORMALISE = {
  mine = mine.normalise,
  -- For the same reason the mine needs one: a half-written claim table is
  -- arithmetic on nil the first time a general reports, and unlike the device
  -- registry nothing in the world re-reports a chunk claim.
  coverage = coverage.normalise,
}

function server.state()
  return {
    fleet = registry.empty(),
    depots = depotList.empty(),
    mine = mine.empty(),
    coverage = coverage.empty(),
  }
end

--- Read persisted state, falling back to empty.
---
--- A missing file is a new server, not a fault. A corrupt one is also treated as
--- a new server rather than as a reason not to boot: a base that refuses to
--- start because its roster is unreadable is a base that cannot be used to fix
--- its roster, and every device re-reports itself within a minute anyway.
function server.load(ports)
  local state = server.state()
  for key, path in pairs(server.PATHS) do
    local text = ports.storage.read(path)
    if text then
      local ok, saved = pcall(ports.serialise.decode, text)
      if ok and type(saved) == "table" then
        -- Normalised where the section knows how, raw where it does not. A mine
        -- read off disk has a plan that has to be made whole before anything
        -- asks it for a sector count, and a rollback-and-upgrade cycle is
        -- exactly how a half-written plan gets there.
        local repair = server.NORMALISE[key]
        state[key] = repair and repair(saved) or saved
      end
    end
  end
  return state
end

function server.save(ports, state)
  for key, path in pairs(server.PATHS) do
    ports.storage.write(path, ports.serialise.encode(state[key]))
  end
end

--- The services a server runs.
---
--- §8's list, in the order it gives them. The unbuilt ones are named here rather
--- than omitted so that the shape of the machine is visible in one place, and so
--- adding one is an edit to this table rather than an archaeology exercise.
---
---   discovery   heartbeats in, desired state out          built
---   bridge      the same, for devices still on ICOS 1     built
---   reconcile   nudge devices that are behind             built
---   persist     write state to disk, batched              built
---   leases      sector claims and frontiers                built
---   gps         the constellation beacon                   built
---   policy      conservative auto-recovery                 built
---   coverage    post generals, spread miners across them   built
---   logrotate   keep the log from filling the disk          built
---
--- `bridge` is a second inbox, not a second reader of the first: it receives on
--- the ICOS 1 protocol, which `discovery` does not. Without it this server is
--- deaf to every device in the current fleet, because they all talk `ccfleet`.
--- It is listed second so that the two ears are next to each other.
function server.services()
  return {
    discovery.service,
    bridge.service,
    reconcile.service,
    persist.service,
    leases.service,
    gps.service,
    policy.service,
    coverageService.service,
    logrotate.service,
  }
end

--- Handlers that read the server's single inbox.
---
--- `discovery` owns the radio because only one loop can, so anything else that
--- needs to see a message registers here instead of opening its own receive. The
--- list is a composition-root decision rather than something a service
--- discovers, which keeps "what reads the radio" answerable by reading one
--- function.
function server.handlers()
  return { leases.handle }
end

--- The two screens a base station has, and why it has two.
---
--- §2 splits `fleet` into a **server** that holds state and a **client** that
--- draws it, and `roles.alsoClient` says a machine can be both - a base with a
--- monitor is exactly that. What it must not be is two supervisors and two event
--- loops on one computer, so the client half arrives here as a service rather
--- than as a second machine.
---
--- That turns out to be better than mirroring. A client on another computer syncs
--- a copy of the registry every three seconds; a client that **is** the server
--- reads `context.state.fleet` directly, so its pages are never stale and there
--- is no sync service to run at all.
---
--- Two surfaces, and the difference between them is D020 rather than layout. The
--- terminal has a keyboard, so it gets the full desktop with every control. The
--- wall has touch coordinates and nothing else, so it gets `readOnly` - and its
--- input port cannot yield a keystroke in the first place, which is the same
--- boundary enforced one layer further down.
server.desktop = service.define({
  id = "desktop",
  requires = { "screen", "input", "state" },
  critical = false,

  run = function(context)
    return context.draw(context)
  end,
})

server.wall = service.define({
  id = "wall",
  requires = { "wall", "wallInput", "state" },
  critical = false,

  run = function(context)
    return context.drawWall(context)
  end,
})

--- Build a supervisor with everything a server runs, ready to be stepped.
---
--- `ports` is the adapter bundle; `state` defaults to whatever is on disk. The
--- context handed to each service is the ports plus the state, which is the only
--- thing a service is allowed to reach - a service that wanted anything else
--- would be a service that knew what machine it was on.
function server.boot(ports, options)
  options = options or {}
  local state = options.state or server.load(ports)

  local sup = supervisor.new({
    clock = ports.clock,
    onError = options.onError,
  })

  local context = {
    clock = ports.clock,
    storage = ports.storage,
    transport = ports.transport,
    locator = ports.locator,
    beacon = ports.beacon,
    serialise = ports.serialise,
    log = ports.log,
    state = state,
    paths = server.PATHS,
    handlers = server.handlers(),
    pollSeconds = options.pollSeconds,

    -- §12's dual run. Both the desired-state reply and the ICOS 1 command go out
    -- until every device is converging, then this goes false and the old path is
    -- deleted. Defaulting to on is the safe direction: an unupgraded turtle
    -- ignores a reply it does not understand, and a turtle that never obeys a
    -- recall is how a fleet gets stranded.
    --
    -- Note what this flag is *not*: it sends the old command shape on the new
    -- protocol, so it only ever reaches a device that already speaks ICOS 2.
    -- Reaching a device that does not is `bridge`'s job, and it is not optional.
    events = options.events,

    -- How `bridge` turns a goal into something an ICOS 1 turtle understands.
    -- Injected here rather than required there, because the authority on that
    -- translation is `reconcile.legacy` and having each require the other would
    -- be a cycle. The composition root is the right place to close it.
    toCommand = reconcile.legacy,

    -- The screens, when this machine has any. A headless server - which is every
    -- spec, and a real base with the monitor unplugged - simply has no `screen`
    -- port, and the supervisor refuses to start a service whose ports are absent
    -- rather than this file having to branch.
    screen = ports.screen,
    input = ports.input,
    wall = ports.wall,
    wallInput = ports.wallInput,

    draw = options.draw or function(inner)
      return require("os.client.shell").run(inner, { role = "server", surface = "desktop" })
    end,

    -- The wall gets its own context so the shell reads the right pair of ports,
    -- and `readOnly` so no page on it builds a control. Both halves matter: the
    -- callbacks are absent *and* the input port cannot yield a keystroke.
    drawWall = options.drawWall or function(inner)
      local wallContext = {}
      for key, value in pairs(inner) do
        wallContext[key] = value
      end
      wallContext.screen = inner.wall
      wallContext.input = inner.wallInput
      return require("os.client.shell").run(wallContext, {
        role = "server",
        surface = "monitor",
        readOnly = true,
      })
    end,
  }

  for _, definition in ipairs(server.services()) do
    sup:add(definition)
  end

  -- The client half, when this machine has a screen to be one on.
  --
  -- `roles.alsoClient` has answered this question since it was written and
  -- nothing had ever asked it. A base with a monitor is a server *and* a client
  -- (§2), and getting the split backwards - a client with a server bolted on -
  -- would mean a base that stopped being the fleet's brain when its monitor was
  -- unplugged.
  if options.screens ~= false then
    if ports.screen then
      sup:add(server.desktop)
    end
    if ports.wall then
      sup:add(server.wall)
    end
  end

  -- What the Services page reads. Attached after construction rather than built
  -- into the context, because a context holding the supervisor that was started
  -- with that context is a cycle the serialiser would refuse - and that is
  -- discovered when a state file quietly stops being written.
  context.supervisor = sup

  sup:start(context)

  return { supervisor = sup, context = context, state = state, ports = ports }
end

return server
