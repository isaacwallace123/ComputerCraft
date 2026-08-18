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
--- ## It does not run yet
---
--- Nothing calls `boot`. `src/startup.lua` still starts the ICOS 1 paths, and
--- switching it over is the change that alters what an existing machine does on
--- power-up. That is the one thing in this branch that reaches a running fleet,
--- so it waits for an in-world test rather than riding along with the rest.

local depotList = require("domain.depot.list")
local discovery = require("os.server.services.discovery")
local leases = require("os.server.services.leases")
local mine = require("domain.mine.registry")
local persist = require("os.server.services.persist")
local reconcile = require("os.server.services.reconcile")
local registry = require("domain.fleet.registry")
local supervisor = require("os.supervisor")

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
}

function server.state()
  return {
    fleet = registry.empty(),
    depots = depotList.empty(),
    mine = mine.empty(),
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
---   reconcile   nudge devices that are behind             built
---   persist     write state to disk, batched              built
---   leases      sector claims and frontiers                built
---   gps         the constellation beacon
---   policy      conservative auto-recovery
---   logrotate   keep the log from filling the disk
function server.services()
  return { discovery.service, reconcile.service, persist.service, leases.service }
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
    serialise = ports.serialise,
    state = state,
    paths = server.PATHS,
    handlers = server.handlers(),
    pollSeconds = options.pollSeconds,

    -- §12's dual run. Both the desired-state reply and the ICOS 1 command go out
    -- until every device is converging, then this goes false and the old path is
    -- deleted. Defaulting to on is the safe direction: an unupgraded turtle
    -- ignores a reply it does not understand, and a turtle that never obeys a
    -- recall is how a fleet gets stranded.
    events = options.events,
  }

  for _, definition in ipairs(server.services()) do
    sup:add(definition)
  end
  sup:start(context)

  return { supervisor = sup, context = context, state = state, ports = ports }
end

return server
