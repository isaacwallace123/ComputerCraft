--- Running a machine by hand, and looking at one that is already running.
---
--- `startup.lua` boots this on power-up, so `icos` is not how a machine normally
--- starts - it is how somebody starts one *deliberately*, forces a role onto a
--- computer that has not been set up, or asks a running server what it thinks is
--- happening.
---
--- It was called `icos2` while there were two operating systems to tell apart.
--- There are not any more.
---
---     icos              boot the role in .node and run
---     icos server       force a role, for a machine that has not been set up
---     icos status       build the machine, print its health, and stop
---     icos watch        run, and show the fleet while it does
---     icos mine <x> <z> <y>   place the shared mine and stop
---
--- ## Why `watch` exists
---
--- A running ICOS 2 server prints nothing. Every service deliberately returns
--- what it did rather than drawing or logging, the composition root records
--- only failures, and the Devices page belongs to the *client* role on a
--- different machine. All of that is right, and together it makes a server
--- indistinguishable from a crashed one from across the room - and impossible
--- to test by hand, because "did the turtle register" has no answer on screen.
---
--- So this is the diagnostic view: the same registry the client would draw,
--- rendered as plain text, repainted on a timer. Deliberately not built on the
--- UI framework - a diagnostic that could fail for rendering reasons is one that
--- confuses the thing it was meant to clarify.
---
--- ## Why `status` builds the machine rather than reading a file
---
--- Because the interesting failures are all in the wiring. "No wireless modem",
--- "no saved position", "this role has no operating system" are discovered when
--- the ports are constructed and the services are registered, and a status
--- command that read a file would report a healthy machine that cannot start.
--- Building it and stopping costs one tick.

package.path = "/?.lua;/?/init.lua;" .. package.path

local boot = require("os.kernel.boot")
local config = require("adapters.cc.config")
local roles = require("os.kernel.roles")

local args = { ... }
local command = args[1]

--- `watch` is a way of running, not a role, so it is peeled off before the
--- role is worked out and the rest of the argument handling is untouched.
local watching = command == "watch"
if watching then
  command = args[2]
end

local node = config.load(".node", {})

---------------------------------------------------------------------------
-- mine
---------------------------------------------------------------------------

--- Place the shared mine, without a running server.
---
--- Configuring a mine is a `mine` message answered by `leases`, which is right
--- and is also useless to somebody standing in front of a base that has no mine
--- *yet* - there is nothing to send it to and no client to send it from. This
--- reads the state, calls the same domain function the service would, and
--- writes it back.
---
--- The coordinates are `x z y`, not `x y z`. A mine is a place on the ground
--- and a depth, and asking for them in world order invites somebody to type
--- their Y where the Z goes - which places a mine a hundred blocks sideways and
--- looks entirely plausible until turtles start walking. The prompt says which
--- is which.
local function placeMine(words)
  local x, z, y = tonumber(words[2]), tonumber(words[3]), tonumber(words[4])
  if not (x and z and y) then
    printError("usage: icos mine <x> <z> <surfaceY>")
    print("The centre of the mine on the ground, then how deep the")
    print("surface is. Read all three off F3 standing at the base.")
    return
  end
  if y < -63 or y > 310 then
    printError("surface Y must be between -63 and 310 so cruise lanes fit")
    return
  end

  local mine = require("domain.mine.registry")
  local storage = require("adapters.cc.storage").new()
  local serialise = require("adapters.cc.serialise").new()

  local state = mine.empty()
  local text = storage.read(mine.PATH)
  if text then
    local ok, saved = pcall(serialise.decode, text)
    if ok and type(saved) == "table" then
      state = mine.normalise(saved)
    end
  end

  local placed, moved = mine.configure(state, { centreX = x, centreZ = z, surfaceY = y })
  storage.write(mine.PATH, serialise.encode(state))

  print(
    ("Mine centred on %d, %d with the surface at %d."):format(
      placed.centreX,
      placed.centreZ,
      placed.surfaceY
    )
  )
  if moved then
    -- Said plainly, because it is the destructive half. Sector numbers now mean
    -- different ground, so every recorded frontier was meaningless and has gone.
    printError("The ground moved: every recorded sector frontier was cleared.")
  end
end

if command == "mine" then
  placeMine(args)
  return
end

--- A forced role, if the first argument is one.
---
--- Checked against the role table rather than passed through, so a typo becomes
--- "unknown role: sever" here instead of "no operating system for role sever"
--- three frames later.
local forced = nil
for _, name in pairs(roles) do
  if type(name) == "string" and name == command then
    forced = name
  end
end

if command ~= nil and command ~= "status" and forced == nil then
  printError("unknown role: " .. tostring(command))
  print("expected one of: server, client, turtle, mobile")
  print("or a command: status, watch, mine <x> <z> <y>")
  return
end

local machine, why = boot.machine(node, { role = forced })
if machine == nil then
  printError(why)
  return
end

if command == "status" then
  -- One step, so every service has been resumed once and has had the chance to
  -- fail on something it needs. A status printed before that has only checked
  -- that the modules load.
  machine.supervisor:step()

  print("ICOS - " .. machine.role)

  -- The radio first, because it is upstream of most of what follows. A server
  -- with no modem shows five services running and hears nothing, and reading
  -- that list without this line would send somebody looking in the wrong place.
  local blocked = nil

  local radio = machine.ports and machine.ports.radio
  if radio then
    print(radio.open and "  ok   radio" or (" FAIL  radio - " .. tostring(radio.reason)))
    blocked = blocked or (not radio.open and "radio" or nil)
  end

  -- Whether this machine can be what it claims, and which screens it found.
  -- Both are configuration problems with an action attached rather than faults,
  -- so they are printed beside the services rather than stopping the boot.
  local roleCheck = machine.ports and machine.ports.role
  if roleCheck and roleCheck.note then
    print((roleCheck.ok and "  warn " or " FAIL ") .. " role - " .. tostring(roleCheck.note))
    blocked = blocked or (not roleCheck.ok and "role" or nil)
  end

  local wall = machine.ports and machine.ports.wallSize
  if wall then
    print(("  ok   wall - %dx%d at scale %s"):format(wall.width, wall.height, tostring(wall.scale)))
  elseif machine.role == "server" or machine.role == "client" then
    print("  warn wall - no monitor attached; drawing on this terminal")
  end

  -- Three states, not two.
  --
  -- This printed FAIL for anything not running, which included a service that
  -- had failed once and was backing off - so the screen said `FAIL gps` and
  -- `healthy` at the same time and both were correct. `healthy` only turns
  -- false when a critical service has *given up*, after five failures, and a
  -- service still retrying has not. Saying so is the difference between a
  -- status somebody trusts and one they learn to argue with.
  for _, row in ipairs(machine.supervisor:health()) do
    local mark = "  ok  "
    if row.state ~= "running" then
      if row.gaveUp then
        mark = row.critical and " FAIL " or " warn "
      else
        mark = " retry"
      end
    end
    local line = mark .. " " .. row.id
    if row.retryIn then
      line = line .. (" (in %ds)"):format(math.ceil(row.retryIn))
    end
    if row.lastError then
      line = line .. " - " .. tostring(row.lastError)
    end
    print(line)
  end

  -- The summary counts the preflight too.
  --
  -- The first in-world boot printed ` FAIL role` and `healthy` three lines
  -- apart, and both were true of what they measured: `supervisor:healthy()`
  -- asks whether a *critical service has given up*, and a machine that cannot
  -- be what it claims has no service to give up about it.
  --
  -- Being true of what it measures is not the same as being right. A status
  -- screen with a FAIL on it and "healthy" underneath is the exact failure the
  -- Services page has a rule against, arriving through the command that a
  -- person reaches for first.
  local healthy, reason = machine.supervisor:healthy()

  if blocked then
    print(("unhealthy: %s"):format(roleCheck and roleCheck.note or blocked))
  elseif not healthy then
    print("unhealthy: " .. tostring(reason))
  else
    -- A service still retrying is not a failure, but it is not nothing either.
    -- Naming it here means the one word at the bottom is never at odds with a
    -- line above it.
    local waiting = {}
    for _, row in ipairs(machine.supervisor:health()) do
      if row.state ~= "running" and not row.gaveUp then
        waiting[#waiting + 1] = row.id
      end
    end
    if #waiting > 0 then
      print(("healthy, %s still starting"):format(table.concat(waiting, ", ")))
    else
      print("healthy")
    end
  end
  machine.supervisor:stop()
  return
end

---------------------------------------------------------------------------
-- watch
---------------------------------------------------------------------------

--- Repaint the fleet as plain text, and set goals from it.
---
--- Reads the same state a client would mirror, on the machine that owns it.
--- Drawing changes nothing; the keys go through `discovery.want`, which is
--- exactly where a client's button press lands.

local registry = require("domain.fleet.registry")
local desired = require("domain.fleet.desired")
local discovery = require("os.server.services.discovery")

--- Which row a keypress refers to. The order is by staleness and therefore
--- moves, so this is an index into the paint rather than a device id - the same
--- compromise a list with a cursor always makes.
local selection = 1
local notice = nil

local function fleetRows(state, now)
  return registry.list(state.fleet, now, registry.byStaleness)
end

local function draw(state, clock)
  local now = clock.now()
  local rows = fleetRows(state, now)

  term.clear()
  term.setCursorPos(1, 1)

  print(("ICOS server - %d device(s)"):format(#rows))
  print(("%-2s %-4s %-9s %-7s %-5s %s"):format("", "id", "label", "health", "wire", "goal"))

  for index, row in ipairs(rows) do
    local record = registry.get(state.fleet, row.id)
    local goal = desired.reply(record)
    print(("%-2s %-4s %-9s %-7s %-5s %s"):format(
      index == selection and ">" or tostring(index),
      tostring(row.id),
      tostring((row.snap and row.snap.label) or "?"):sub(1, 9),
      row.health,
      -- Which protocol this device is actually reachable on. The whole point of
      -- the bridge is that `icos1` devices are heard at all, so it is the first
      -- thing worth seeing.
      record.legacy and "icos1" or "icos",
      goal and (goal.mode .. " " .. desired.status(record, now)) or "-"
    ))
  end

  if #rows == 0 then
    print("")
    print("Nothing has reported yet. An ICOS 1 miner")
    print("broadcasts every 2s once it is running.")
  end

  -- What the selected device said the last time it was told something.
  --
  -- Without this the screen can show `deploy pending` for ten minutes while the
  -- device has already answered "no fuel" - the answer arrived, was recorded,
  -- and was not shown. An ICOS 1 device refuses with a reason and that reason is
  -- the single most useful line on this page when something is not moving.
  local chosen = rows[selection] and registry.get(state.fleet, rows[selection].id)
  local last = chosen and chosen.lastResult
  if last then
    print("")
    print(
      ("last: %s %s - %s"):format(
        tostring(last.action),
        last.ok and "ok" or "REFUSED",
        tostring(last.message or "")
      )
    )
  end

  print("")
  print("digit select  r recall  d deploy  p park  ^T stop")
  if notice then
    print(notice)
  end
end

--- Ask the server to want something of the selected device.
---
--- Through `discovery.want`, and not by writing to the record. The validation,
--- the generation bump and the persist mark all live in that function, so a
--- diagnostic that set the field directly would report success for an order the
--- real path would have refused - which is the one thing a diagnostic must not
--- do.
local function want(context, mode)
  local rows = fleetRows(context.state, context.clock.now())
  local row = rows[selection]
  if row == nil then
    notice = "nothing selected"
    return
  end
  local reply = discovery.want(context, { id = row.id, mode = mode })
  notice = ("%s %s: %s"):format(
    mode,
    tostring(row.id),
    reply.ok and ("generation " .. tostring(reply.generation)) or tostring(reply.message)
  )
end

if watching then
  print("ICOS - " .. machine.role .. " - hold Ctrl-T to stop")

  -- The repaint rides on the event loop's own `pull`, which `boot.run` takes as
  -- a parameter precisely so the loop can be driven from outside. The event is
  -- still returned to the supervisor untouched: a diagnostic that swallowed
  -- events would change which services woke up, and then it would be measuring
  -- itself.
  local timer = os.startTimer(1)
  local outcome, reason = boot.run(machine, function()
    local event = { os.pullEventRaw() }
    local repaint = false

    if event[1] == "timer" and event[2] == timer then
      timer = os.startTimer(1)
      repaint = true
    elseif event[1] == "char" then
      local key = event[2]
      local digit = tonumber(key)
      if digit then
        selection = digit
      elseif key == "r" then
        want(machine.context, "recall")
      elseif key == "d" then
        want(machine.context, "deploy")
      elseif key == "p" then
        want(machine.context, "park")
      end
      repaint = true
    end

    if repaint then
      -- Wrapped, because a diagnostic that throws takes the machine down with
      -- it - and a base station that stopped serving because its status screen
      -- had a formatting bug would be the worst possible trade.
      local ok, drawError =
        pcall(draw, machine.state or machine.context.state, machine.context.clock)
      if not ok then
        term.clear()
        term.setCursorPos(1, 1)
        printError("watch: " .. tostring(drawError))
      end
    end

    return event
  end)

  if outcome == "stopped" then
    printError("every service gave up: " .. tostring(reason))
  end
  return
end

print("ICOS - " .. machine.role .. " - hold Ctrl-T to stop")

local outcome, reason = boot.run(machine)

if outcome == "stopped" then
  printError("every service gave up: " .. tostring(reason))
  print("Run `icos status` to see which, or reboot for ICOS 1.")
elseif outcome == "halted" then
  print("Stopped on request.")
else
  print("ICOS 2 stopped.")
end
