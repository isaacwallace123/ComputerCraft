--- A turtle's screen, without a framework behind it.
---
--- ## Why a turtle does not get the UI framework
---
--- Because it cannot afford one, and it has nothing to spend it on.
---
--- CC gives every computer in a world a shared budget - `max_main_global_time`,
--- ten milliseconds a tick by default, across all of them - so a turtle drawing
--- a desktop is spending the base station's time. The framework costs about
--- three milliseconds and eighteen modules to load, keeps a reactive graph, a
--- layout solver and a double buffer alive for the life of the machine, and
--- re-solves a tree every time the tick moves.
---
--- What it buys on a turtle is an app switcher for four pages, on a 39x13 screen
--- that somebody looks at when they have walked to a stopped turtle to find out
--- why. That is not a trade worth making at any price, and at this price it is
--- the fleet paying for it.
---
--- So: no `ui.init`, no `reactive`, no layout, no buffer. Twelve lines of text
--- written straight at the screen port, redrawn only when one of them changes.
---
--- ## It still goes through the port
---
--- `ports/screen.lua`, not `term`. Not out of tidiness - it is what lets this be
--- a spec against a recording screen instead of something somebody has to fly
--- out and look at, which is the same reason the framework has the port.
---
--- ## One page, and which one depends on the job
---
--- A miner shows what it is doing and what it needs to keep doing it. A general
--- shows the turtles working under it, because that is the one thing about a
--- general nothing else can see - the base knows the fleet, but only the general
--- knows which of them are its.
---
--- There is nothing to press. A turtle's controls were taken away deliberately
--- (the fleet is managed from the base), so a screen with no input is not a
--- reduction - it is the honest shape of the machine.

local format = require("ui.format")
local theme = require("ui.theme")

local T = theme.TOKENS

local screen = {}

--- Hex digit per palette index, for `blit`.
local DIGITS = "0123456789abcdef"
local function digit(index)
  return DIGITS:sub(index + 1, index + 1)
end

--- Write one run of text in one colour.
---
--- The whole width every time, so a shorter line than last frame cannot leave
--- its own tail behind - the same rule `ui/components/text.lua` follows, for the
--- same reason, and it is the one piece of the framework worth reimplementing.
function screen.line(port, y, text, colour, background)
  local width = select(1, port.size())
  local padded = format.pad(text or "", width, "left")
  port.blit(
    1,
    y,
    padded,
    digit(colour or T.foreground):rep(#padded),
    digit(background or T.background):rep(#padded)
  )
end

--- A label and a value on one row.
---
--- Two writes rather than one built string, because the two halves are different
--- colours and a turtle's screen is narrow enough that the label being dim is
--- most of what makes it readable.
function screen.field(port, y, label, value, colour)
  local width = select(1, port.size())
  local left = format.pad(label, 8, "left")
  port.blit(1, y, left, digit(T.mutedFg):rep(#left), digit(T.background):rep(#left))

  local right = format.pad(value or "", math.max(0, width - #left), "left")
  port.blit(
    #left + 1,
    y,
    right,
    digit(colour or T.foreground):rep(#right),
    digit(T.background):rep(#right)
  )
end

--- What colour a phase should be.
local function phaseTone(phase)
  if phase == "mining" or phase == "working" then
    return T.good
  end
  if phase == "parked" or phase == "idle" then
    return T.mutedFg
  end
  if phase == "gave up" or phase == "stuck" then
    return T.destructive
  end
  return T.warn
end

--- The lines a miner's screen shows, as data.
---
--- Separated from the drawing so a spec can assert on the sentences without a
--- screen, which is the same seam `apps/*/view.lua` has and is the only part of
--- the framework's shape worth keeping here.
function screen.miner(snapshot, state)
  snapshot = snapshot or {}
  state = state or {}

  local rows = {}
  local function row(label, value, colour)
    rows[#rows + 1] = { label = label, value = value, colour = colour }
  end

  row("job", snapshot.job or "none")
  row("phase", snapshot.phase or "idle", phaseTone(snapshot.phase))

  -- Which general this turtle is working under, from the last heartbeat reply.
  -- The server derives it from the chunk claims - a miner is assigned a chunk
  -- and a general holds it - so reassigning ground moves the crew without
  -- anybody updating a list.
  local general = state.general or snapshot.general
  row("general", general and tostring(general) or "none")

  local sector = tonumber(snapshot.sector)
  row("sector", sector and sector > 0 and tostring(sector) or "none")

  local fuel = tonumber(snapshot.fuel)
  row("fuel", fuel and format.count(fuel) or "?", fuel and fuel < 1000 and T.destructive or nil)

  local world = snapshot.world
  if type(world) == "table" and world.x then
    row("at", ("%d %d %d"):format(world.x, world.y or 0, world.z or 0))
  elseif state.locateWhy then
    -- Why, not just that. "no position" on a turtle standing under a working
    -- constellation is a fact with no next step attached, and the reason was
    -- going to the log - which a turtle no longer has a page for.
    row("at", format.ellipsis(tostring(state.locateWhy), 30), T.warn)
  else
    row("at", "locating...", T.warn)
  end

  local goal = state.desired and state.desired.mode
  if goal then
    row("orders", tostring(goal))
  end

  return rows
end

--- The lines a general's screen shows.
---
--- A general commands miners, so its screen is the list of them. Nothing else on
--- this machine knows it: the base has the fleet and the chunk claims, but the
--- pairing of a miner to the general covering its ground is the general's own.
function screen.general(snapshot, state)
  snapshot = snapshot or {}
  state = state or {}

  local rows = {}
  rows[#rows + 1] =
    { label = "phase", value = snapshot.phase or "idle", colour = phaseTone(snapshot.phase) }

  local fuel = tonumber(snapshot.fuel)
  rows[#rows + 1] = {
    label = "fuel",
    value = fuel and format.count(fuel) or "?",
    colour = fuel and fuel < 1000 and T.destructive or nil,
  }

  local crew = state.crew or {}
  rows[#rows + 1] = {
    label = "crew",
    value = #crew == 0 and "nobody yet" or ("%d turtle%s"):format(#crew, #crew == 1 and "" or "s"),
    colour = #crew == 0 and T.mutedFg or T.good,
  }

  for _, member in ipairs(crew) do
    rows[#rows + 1] = {
      label = "  " .. tostring(member.label or member.id or "?"),
      value = tostring(member.phase or "?"),
      colour = phaseTone(member.phase),
    }
  end

  return rows
end

--- Everything the screen should say right now.
function screen.rows(context)
  local snapshot = context.snapshot and context.snapshot() or {}
  local state = context.state or {}
  if (snapshot.job or "") == "general" then
    return screen.general(snapshot, state), snapshot
  end
  return screen.miner(snapshot, state), snapshot
end

--- One frame, as a single string, so two frames can be compared.
---
--- Redrawing costs a `blit` per row and a turtle redraws once a second forever,
--- which on a shared budget is worth not doing when nothing moved. Comparing
--- rendered text rather than the snapshot is what makes that correct: two
--- different snapshots that say the same thing are the same frame.
function screen.digest(rows, label)
  local parts = { tostring(label or "") }
  for _, row in ipairs(rows) do
    parts[#parts + 1] = row.label .. "\1" .. tostring(row.value)
  end
  return table.concat(parts, "\2")
end

--- Draw, and say whether anything was drawn.
function screen.draw(port, rows, label, last)
  local digest = screen.digest(rows, label)
  if digest == last then
    return false, digest
  end

  local width, height = port.size()
  port.clear(T.background)

  -- A quiet header, not the desktop's chrome bar.
  --
  -- The desktop's bar is window management - tabs, a clock, a way home - and
  -- earns a saturated block across the top. A turtle has none of that: this line
  -- is a name. On a 39-cell screen a full-width block of colour for one word is
  -- most of what you see, so it is `muted` with the name in `accent` and a rule
  -- under it, which is the restraint `docs/ui-design.md` argues for at this
  -- resolution.
  local title = format.pad(" " .. tostring(label or "turtle"), width, "left")
  port.blit(1, 1, title, digit(T.accent):rep(width), digit(T.muted):rep(width))
  port.blit(1, 2, (" "):rep(width), digit(T.border):rep(width), digit(T.border):rep(width))

  local y = 4
  for _, row in ipairs(rows) do
    if y > height then
      break
    end
    screen.field(port, y, row.label, row.value, row.colour)
    y = y + 1
  end

  return true, digest
end

--- How long between frames, in seconds.
---
--- One, matching the heartbeat that changes most of what is on screen. A frame
--- costs building seven short strings and comparing them; it costs a `blit` only
--- when one of them moved, which on a parked turtle is never.
screen.EVERY = 1

--- The turtle's screen loop.
---
--- Waits on the clock, never on the input port - and that is a correctness rule
--- rather than a preference. `ports/input.lua`'s null implementation returns
--- immediately, which is what a spec has, what a machine with no keyboard has,
--- and what a computer whose input has died has. A loop that waited on `pull`
--- would spin at full speed on all three, which is the failure
--- `os/kernel/services/ticker.lua` was written to avoid and which this file
--- reproduced within an hour of being written.
---
--- `clock.sleep` yields to the supervisor like every other service, so a dead
--- input port stays dead rather than becoming busy.
function screen.run(context)
  local port = context.screen
  local label = context.node and context.node.label or "turtle"
  local last = nil

  -- The palette, once.
  --
  -- Every other surface gets this from `ui/host.lua` when it mounts. A turtle
  -- does not mount anything any more, so nothing was uploading it - and the
  -- theme's slot numbers were being drawn in CC's *default* colours, where slot
  -- 14 is red rather than indigo and slot 3 is light blue rather than grey. The
  -- screen looked wrong in a way that reads as a design choice rather than as a
  -- missing call.
  --
  -- Sixteen calls at boot and never again, which is what `theme.apply`'s own
  -- header says it is for.
  if port ~= nil then
    theme.apply(port, theme.dark)
  end

  while true do
    if port ~= nil then
      local rows = screen.rows(context)
      local _, digest = screen.draw(port, rows, label, last)
      last = digest
    end

    -- A turtle with no screen sleeps and does nothing, rather than returning:
    -- the supervisor treats a service that returns as a fault, and a turtle
    -- whose display is unreadable is not a broken turtle.
    context.clock.sleep(context.screenEvery or screen.EVERY)

    -- The same guard every other service loop has, and it is not belt and
    -- braces. `clock.sleep` yields on real hardware because CC's `sleep` waits
    -- on an event; a clock that does not - a spec's, a simulated one - turns
    -- this into an infinite loop inside a single resume, which hangs the
    -- machine rather than slowing it. Written after doing exactly that.
    if coroutine.isyieldable() then
      coroutine.yield()
    end
  end
end

return screen
