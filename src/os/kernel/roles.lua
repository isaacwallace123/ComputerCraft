--- Which operating system a machine runs, and how today's roles become one.
---
--- §2 of docs/icos-2.md turns five roles into four operating systems, and §13
--- gives the mapping. This is that mapping, plus the capability rules that
--- decide whether a machine can actually be what its `.node` says it is.
---
--- ## The migration is a read, not a write
---
--- `roleOf` translates on every boot rather than rewriting `.node` once. That is
--- deliberate and it is the rolling-update rule from `docs/ai-handoff.md`:
--- readers must tolerate old snapshots during a rolling OTA. A machine that
--- rewrote its own role on first boot would be unable to go back if the update
--- were rolled back, and a fleet half-migrated by a partial update would have
--- two incompatible ideas of what a `fleet` computer is.
---
--- Translating instead means an old `.node` keeps working forever and a
--- downgrade is just a downgrade.
---
--- ## `fleet` is the awkward one
---
--- Every other role maps one-to-one. `fleet` does not: §2 splits it into a
--- **server** that holds authoritative state and a **client** that draws it, and
--- one machine was doing both. The split is real - a base with a monitor is a
--- server *and* a client - so the mapping answers "server", and the client is
--- started beside it by the composition root when the machine has a screen.
---
--- Getting this backwards - mapping to client, and starting a server beside it -
--- would mean a base that lost its monitor stopped being the fleet's brain.

local roles = {}

--- The four operating systems.
---
--- Every one of these is a *form factor*, not a job. That is the whole rule, and
--- it was worth restating because `miner` broke it: a mining turtle and a farming
--- turtle are the same machine running different code, and giving one of them a
--- role would have meant a second operating system that differed from the first
--- only in which file it required.
---
--- What a turtle does is a **job**, chosen at setup and changeable from the base
--- without reinstalling anything. What a turtle *is* is a turtle.
roles.SERVER = "server"
roles.CLIENT = "client"
roles.TURTLE = "turtle"
roles.MOBILE = "mobile"

--- §13's table, and the reason for each row that is not obvious.
---
--- `gps` becomes a server because a GPS host already has to be permanently
--- loaded and already has to know exactly where it is, which is the entire job
--- description of a server. Running them as separate roles meant maintaining two
--- always-on machines with the same requirements and no shared state.
---
--- `utility` has no ICOS 2 equivalent and maps to client: it is a machine
--- somebody uses, holding no authority, which is what a client is.
local FROM_ROLE = {
  fleet = roles.SERVER,
  gps = roles.SERVER,
  -- ICOS 1 had no turtle role, it had a miner role - because mining was the
  -- only thing a turtle did. The mapping keeps every existing turtle working:
  -- the role becomes `turtle` and the job it was already running becomes its
  -- job, which is where mining belonged all along.
  miner = roles.TURTLE,
  controller = roles.MOBILE,
  utility = roles.CLIENT,

  -- Already migrated. Listed so a machine that has been set up under ICOS 2
  -- reads its own role back unchanged rather than falling through to the
  -- default.
  server = roles.SERVER,
  client = roles.CLIENT,
  mobile = roles.MOBILE,
  turtle = roles.TURTLE,
}

--- What operating system this node runs.
---
--- Defaults to client rather than to server or turtle. A machine whose role is
--- unreadable should end up as the thing that holds no authority and moves
--- nothing: a client shows a screen and is wrong harmlessly, while a turtle
--- starts driving a turtle and a server starts answering for the fleet.
function roles.roleOf(node)
  local declared = node and node.role
  return FROM_ROLE[tostring(declared or "")] or roles.CLIENT
end

--- Does this machine also draw?
---
--- A base station is a server and a client at once - §2 splits the two
--- responsibilities without requiring two computers. The server half is what the
--- role says; the client half is started beside it whenever the machine has a
--- screen a person could look at.
function roles.alsoClient(node, capabilities)
  return roles.roleOf(node) == roles.SERVER and (capabilities or {}).screen == true
end

--- Can this machine be what it claims to be?
---
--- Returns true, or false and a reason a person can act on. Checked at boot
--- rather than at first use, because "this turtle has no modem" is a sentence
--- somebody can do something about and "attempt to index a nil value" at three
--- in the morning is not.
---
--- The rules are the ones already enforced across the current codebase, gathered
--- into one place:
---
---   * a **server** hosts GPS and answers the fleet, so it needs a modem and it
---     needs to know where it is (§10)
---   * a **turtle** is a turtle, and nothing else can be one - whatever job it
---     is running
---   * a **mobile** is a pocket computer; it may run without a modem, but it is
---     offline until one is attached (D019)
---   * a **client** needs a screen, which every computer has
function roles.check(role, capabilities)
  capabilities = capabilities or {}

  if role == roles.TURTLE then
    if not capabilities.turtle then
      return false, "the turtle operating system must run on a turtle"
    end
    return true
  end

  if role == roles.SERVER then
    if capabilities.turtle and not capabilities.chunkLoaded then
      -- Allowed, and worth saying out loud: a Chunky Turtle can be a GPS host
      -- and keep the shared host chunk loaded (D022). A plain turtle cannot,
      -- because a server that unloads is a constellation with three hosts.
      return true, "a turtle server must be chunk-loaded to stay a GPS host"
    end
    if not capabilities.modem then
      return false, "a server needs a wireless or ender modem"
    end
    if not capabilities.located then
      return false, "a server must know where it is before it can host GPS"
    end
    return true
  end

  if role == roles.MOBILE then
    if not capabilities.pocket then
      return false, "a mobile must run on a pocket computer"
    end
    if not capabilities.modem then
      -- D019: setup offers this role without a modem, and fleet traffic stays
      -- offline until one is attached. A warning rather than a refusal, because
      -- a handheld with no modem is still a usable handheld.
      return true, "no modem: this handheld will not see the fleet until one is attached"
    end
    return true
  end

  return true
end

--- The roles a machine may be *offered*, in menu order.
---
--- Distinct from `check`, and the difference matters. `check` answers "is this
--- machine allowed to be what it already claims to be" and is asked at boot;
--- this answers "what should somebody be shown at setup" and is asked once, by
--- a person. A role can be offerable and still warn - a handheld with no modem
--- is a usable handheld (D019) - and a role can be checkable and never offered.
---
--- **A server is offered without a position**, even though `check` refuses one.
--- That is deliberate: setup is where somebody is standing at the machine and
--- can be told to run `commands/locate`, and hiding the role until they have would leave
--- them with no way to discover that a server is what they wanted. The refusal
--- comes later, with an instruction, from the place that can act on it.
---
--- `detail` is what the role *is*, not what it needs. What it needs is `warn`,
--- which is shown after it is chosen, because a menu of caveats is a menu
--- nobody reads.
roles.OFFERED = {
  {
    key = roles.TURTLE,
    label = "Turtle",
    detail = "Runs jobs, moves, reports to the base",
    offer = function(caps)
      return caps.turtle == true
    end,
    warn = function(caps)
      if not caps.modem then
        return "no modem: it will work, but nothing will track it"
      end
      return nil
    end,
  },
  {
    key = roles.SERVER,
    label = "Server",
    detail = "Holds the fleet's state and hosts GPS",
    offer = function(caps)
      -- Not a pocket computer: a server must stay loaded, and a machine in
      -- somebody's pocket is the definition of one that does not (D019).
      return caps.pocket ~= true
    end,
    warn = function(caps)
      if not caps.modem then
        return "a server needs a wireless or ender modem before it can start"
      end
      if not caps.wireless then
        return "wired modem: turtles will not reach this"
      end
      if not caps.located then
        return "run `commands/locate` before starting: a GPS host must know where it is"
      end
      if caps.turtle and not caps.chunkLoaded then
        return "not a Chunky Turtle: keep this chunk loaded another way"
      end
      return nil
    end,
  },
  {
    key = roles.CLIENT,
    label = "Client",
    detail = "Screens and controls. Holds no authority",
    offer = function(caps)
      return caps.turtle ~= true and caps.pocket ~= true
    end,
    warn = function(caps)
      if not caps.modem then
        return "no modem: it will show nothing until one is attached"
      end
      if not caps.monitor then
        return "no monitor: the dashboard will draw on this screen"
      end
      return nil
    end,
  },
  {
    key = roles.MOBILE,
    label = "Handheld",
    detail = "The same screens, in your pocket",
    offer = function(caps)
      return caps.pocket == true
    end,
    warn = function(caps)
      if not caps.modem then
        return "no modem: the screens work offline; fleet control needs one"
      end
      if not caps.wireless then
        return "wired modem: use a wireless or ender one while mobile"
      end
      return nil
    end,
  },
}

--- The offerable roles for these capabilities, in menu order.
---
--- Never empty for any real machine: every form factor matches at least one
--- entry, which is what stops setup showing somebody a list with nothing in it
--- and no way forward. A turtle gets Turtle and Server; a pocket gets Handheld;
--- a computer gets Server and Client.
function roles.offered(capabilities)
  capabilities = capabilities or {}
  local out = {}
  for _, entry in ipairs(roles.OFFERED) do
    if entry.offer(capabilities) then
      out[#out + 1] = entry
    end
  end
  return out
end

--- What the composition root should start on this machine.
---
--- One place that answers "what runs here", so `startup.lua` does not grow a
--- second opinion. Returns the primary role and whether to bring up a client
--- beside it.
function roles.plan(node, capabilities)
  local role = roles.roleOf(node)
  local ok, note = roles.check(role, capabilities)
  return {
    role = role,
    client = roles.alsoClient(node, capabilities),
    ok = ok,
    note = note,
    migrated = node ~= nil and node.role ~= nil and node.role ~= role,
  }
end

return roles
