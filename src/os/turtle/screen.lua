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

local fix = require("domain.gps.fix")
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

--- Where a machine is, as a row.
---
--- Shared, because a general needs it for the same reason a miner does: chunk
--- coverage is worked out from world positions, so a general with no position
--- holds no ground and a general that holds no ground has no crew. "nobody yet"
--- and "no position" are the same fact reported twice.
local function placeRow(snapshot, state)
  local world = snapshot.world
  if type(world) == "table" and world.x then
    return { label = "at", value = ("%d %d %d"):format(world.x, world.y or 0, world.z or 0) }
  end

  if state.locateWhy then
    return {
      label = "at",
      value = format.ellipsis(tostring(state.locateWhy), 30),
      colour = T.warn,
    }
  end

  return { label = "at", value = "locating...", colour = T.warn }
end

--- Which way it faces, or what it is doing about not knowing.
---
--- Its own row rather than a mark on the position, and the reason is that this
--- said `(fix)` for a while and somebody had to ask what it meant. It was
--- jargon for "a GPS reading with no heading", which is a sentence about the
--- *heading* wearing a position's clothes.
---
--- The distinction is real and worth a row of a thirteen-row screen: GPS gives
--- three numbers and withholds the fourth, a turtle needs all four to dead
--- reckon, and "why will this turtle not deploy" has its answer here and
--- nowhere else.
local function headingRow(snapshot, state)
  local heading = tonumber(snapshot.heading)
  if heading ~= nil then
    return { label = "facing", value = fix.compass(heading), colour = T.good }
  end

  if state.locateWhy then
    return {
      label = "facing",
      value = format.ellipsis(tostring(state.locateWhy), 30),
      colour = T.warn,
    }
  end

  -- No "not set, reboot to set it" branch, and it is worth saying why it is
  -- absent: `locateWhy` is written alongside the failure that raises the prompt,
  -- so it always wins the test above and that branch could never be reached. The
  -- reason is the better message anyway - "blocked: Movement obstructed" says
  -- what to do about it and "not set" does not.
  return { label = "facing", value = "working it out", colour = T.warn }
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

  local place = placeRow(snapshot, state)
  row(place.label, place.value, place.colour)

  local facing = headingRow(snapshot, state)
  row(facing.label, facing.value, facing.colour)

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

  -- A general with no position holds no chunk, and a general that holds no chunk
  -- has no crew - so these two rows are the explanation for the one under them.
  rows[#rows + 1] = placeRow(snapshot, state)
  rows[#rows + 1] = headingRow(snapshot, state)

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

--- A service that has stopped, if any has.
---
--- A turtle has no Services page - taking the framework off it was the point -
--- so a service that fails and backs off is invisible on the one machine
--- somebody has walked to. That is how "locating..." forever looked identical to
--- "the locate service died on its first attempt".
---
--- Only the worst one, and only when there is one. A row that said "5 services"
--- every time would be a row nobody reads.
function screen.fault(supervisor)
  if supervisor == nil then
    return nil
  end

  for _, row in ipairs(supervisor:health()) do
    if row.gaveUp or (row.state ~= "running" and not row.disabled) then
      return {
        label = row.id,
        value = format.ellipsis(tostring(row.lastError or row.state), 30),
        colour = row.gaveUp and T.destructive or T.warn,
      }
    end
  end
  return nil
end

--- Everything the screen should say right now.
function screen.rows(context)
  -- The decorated snapshot, so the screen and the base agree about where this
  -- turtle is. `os/turtle/main.lua` folds in the saved fix when the navigator
  -- has nothing to report; reading the raw one here would put a position on the
  -- fleet page and "locating..." on the machine itself.
  local snapshot = {}
  if context.snapshot then
    local turtleOs = require("os.turtle.main")
    snapshot = turtleOs.snapshot(context) or {}
  end

  -- What the screen reads, gathered from the two places it lives: the applied
  -- state the base wrote, and the machine's own transient notes. Assembled here
  -- so the drawing functions take one table and can be handed a literal in a
  -- spec.
  local state = {
    crew = (context.state or {}).crew,
    general = (context.state or {}).general,
    locateWhy = context.locateWhy,
  }

  local rows
  if (snapshot.job or "") == "general" then
    rows = screen.general(snapshot, state)
  else
    rows = screen.miner(snapshot, state)
  end

  local fault = screen.fault(context.supervisor)
  if fault then
    rows[#rows + 1] = { label = "", value = "" }
    rows[#rows + 1] = fault
  end

  return rows, snapshot
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

--- The two things a person standing in front of a turtle can ask it for.
---
--- Both exist because the automatic path can fail in ways only somebody looking
--- at the machine can resolve. `locate` re-measures a turtle that has been
--- picked up and put down somewhere else - `calibrate.needed` refuses that on
--- its own, correctly, because a turtle re-deriving a position it already has
--- would spend a move on every boot. `facing` is the manual answer for a turtle
--- boxed in on all four sides, where no amount of retrying will ever work.
---
--- Keys rather than only clicks: a plain turtle's terminal raises no mouse
--- events at all, so a control that could only be clicked would be a control
--- that does not exist on half the fleet.
screen.ACTIONS = {
  { key = "l", label = "locate" },
  { key = "f", label = "facing" },
}

--- The footer text, and where each action sits on it.
---
--- Returned together so that drawing and hit-testing cannot disagree about
--- where a word is - which is the bug every hand-placed control has once.
function screen.footer()
  local text, spans = "", {}
  for _, action in ipairs(screen.ACTIONS) do
    local piece = ("[%s] %s  "):format(action.key:upper(), action.label)
    spans[#spans + 1] = { from = #text + 1, to = #text + #piece, action = action }
    text = text .. piece
  end
  return text, spans
end

--- Which action a click landed on, or nil.
---
--- `y` must be the footer row, which the caller knows from the screen height.
--- Pure, so the mapping between a cell and an action is a spec rather than
--- something only discoverable by clicking a real turtle.
function screen.hit(x, y, height)
  if y ~= height then
    return nil
  end
  local _, spans = screen.footer()
  for _, span in ipairs(spans) do
    if x >= span.from and x <= span.to then
      return span.action.key
    end
  end
  return nil
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
    -- One short of the bottom: the last row belongs to the actions, and a
    -- status line that overwrote them would remove the only two controls the
    -- machine has exactly when there is most to say.
    if y >= height then
      break
    end
    screen.field(port, y, row.label, row.value, row.colour)
    y = y + 1
  end

  screen.line(port, height, format.pad(" " .. screen.footer(), width, "left"), T.mutedFg, T.muted)

  return true, digest
end

--- Ask which way this turtle faces, when it cannot work that out itself.
---
--- ## Automatic first, always
---
--- `os/turtle/calibrate.lua` finds the heading by stepping one block and
--- comparing two GPS fixes, and that is the path that scales: nobody walks to a
--- turtle. This runs only once that has *tried and failed* - a turtle boxed in
--- on every side, or one whose constellation is not up yet.
---
--- Which is why it waits for `locateFailed` rather than for the absence of an
--- origin. Those look identical for the first few seconds of every boot, and a
--- prompt that appeared in that window would be a prompt somebody answers
--- before the machine has had a chance to answer it better.
---
--- ## Before the status page, not instead of it
---
--- A turtle that cannot say which way it points cannot be deployed, so its
--- status page is a list of things it is not doing. Asking first puts the one
--- answerable question in front of the person standing there.
---
--- Cancelling is always possible and always means "leave it alone". The page
--- then says so, and the automatic path keeps trying in the background.
function screen.askFacing(context, options)
  options = options or {}
  local nav = context.nav
  if nav == nil or context.screen == nil then
    return false
  end

  -- Normally refused for a turtle that already knows, because re-asking a
  -- question the machine has answered is how a good answer gets replaced by a
  -- typed one. `force` is somebody pressing the button, which is the case where
  -- they can see something the turtle cannot - that it is facing the other way.
  if nav.hasOrigin() and not options.force then
    return false
  end

  -- The position comes first and comes free: `os/kernel/services/gps.lua`
  -- refreshes it from the constellation. Without one there is nothing to anchor
  -- a heading to, and asking would collect an answer that cannot be written
  -- down.
  local saved = context.locator and context.locator.saved()
  if type(saved) ~= "table" or tonumber(saved.x) == nil then
    return false
  end

  local console = require("os.kernel.console")
  local prompt = require("os.kernel.prompt")

  local entries = {}
  for _, name in ipairs(fix.COMPASS) do
    entries[#entries + 1] = { label = name }
  end

  local chosen = prompt.choose(console.new(context.screen), entries, {
    title = tostring(context.node and context.node.label or "turtle"),
    note = "F3 shows Facing. Turtles point away.",
    footer = "up/down   enter choose   Q skip",
  })

  if chosen == nil then
    return false
  end

  -- The automatic path may have won while the question was on screen. Its answer
  -- is measured and this one is typed, so it keeps its own - unless the typed
  -- one was asked for on purpose, in which case it is the correction.
  if nav.hasOrigin() and not options.force then
    return false
  end

  nav.setOrigin(saved.x, saved.y, saved.z, chosen - 1)
  if context.saveLocation then
    context.saveLocation({
      x = saved.x,
      y = saved.y,
      z = saved.z,
      heading = chosen - 1,
    })
  end
  context.locateWhy = nil
  context.locateFailed = nil
  return true
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
  local asked = false

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
    -- Once, and only after the automatic attempt has given up. See `askFacing`.
    if not asked and context.locateFailed then
      asked = true
      screen.askFacing(context)
      last = nil
    end

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
