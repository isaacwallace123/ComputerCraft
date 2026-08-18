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
