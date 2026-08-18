--- The UI framework, running on real hardware, measuring itself.
---
--- Run it in game by typing `apps/showcase` on a computer whose files are this
--- repository - see "Testing in a local world" in docs/operations.md.
---
--- ## Why this exists
---
--- Everything measured so far was measured on desktop Lua. Section 12 of
--- docs/ui-framework.md applies a conservative 10x margin for Cobalt and says,
--- in as many words, to re-measure on hardware before trusting it. This is that
--- measurement, and it is the gate on two things: wiring the framework into the
--- desktop, and building the Blackjack showcase - which is a full-screen
--- animated canvas, precisely the workload D037 says does not fit a contended
--- slice.
---
--- ## It is deliberately not an app
---
--- No entry in `core/apps.lua`, no `requiresInput` declaration, nothing in the
--- registry, and nothing on the desktop. A live fleet is running the release;
--- this must be reachable only by somebody typing its name on a machine they
--- are standing in front of. Wiring a framework screen into the desktop is a
--- separate change with an in-world test of its own.
---
--- ## What it is a worked example of
---
--- The composition root pattern, at its smallest. It builds the two cc adapters,
--- hands them to `ui.page`, and runs. Everything above the ports is the same
--- code the specs drive with a recording screen and a scripted keyboard; the
--- only difference is which two tables get passed in. That is the whole point of
--- the ports layer, and this is the shortest demonstration of it.

local ccInput = require("adapters.cc.input")
local ccScreen = require("adapters.cc.screen")
local devicesView = require("apps.devices.view")
local fleetView = require("apps.fleet.view")
local ui = require("ui.init")

local T = ui.tokens

---------------------------------------------------------------------------
-- Fake fleet
---------------------------------------------------------------------------

local PHASES = { "mining", "returning", "unloading", "parked", "travelling" }

--- A roster that moves, so the numbers on screen are not a still life.
---
--- Deliberately changes only a little per tick: two turtles report, everything
--- else recomputes to the string it already had. That is the shape of a real
--- heartbeat and the one the blit count needs to be honest about - a demo that
--- changed everything every frame would measure a full repaint and call it a
--- dashboard update.
local function roster(tick)
  local devices = {}
  for index = 1, 14 do
    local moving = index % 7 == tick % 7
    devices[index] = {
      id = index,
      label = ("miner-%d"):format(index),
      phase = index == 4 and "no cap block"
        or PHASES[((index + (moving and tick or 0)) % #PHASES) + 1],
      job = index % 2 == 0 and "rare" or "resources",
      fuel = math.max(400, 90000 - index * 5200 - (moving and tick * 137 or 0)),
      fuelLimit = 100000,
      since = index * 23,
      online = index % 9 ~= 0,
      alert = index == 4,
    }
  end
  return devices
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

local pages = {}

pages[1] = {
  name = "Fleet",
  build = function(scope, state)
    return fleetView.build(scope, {
      devices = state.devices,
      selected = state.selected,
      capacity = state.rows,
      onDeploy = function() end,
      onRecall = function() end,
      onStop = function() end,
    })
  end,
}

pages[2] = {
  name = "Devices",
  build = function(scope, state)
    return devicesView.build(scope, {
      devices = state.devices,
      selected = state.selected,
      offset = state.offset,
      capacity = state.rows,
      onSelect = function(device)
        state.selected:set(device.id)
      end,
      onDeploy = function() end,
      onRecall = function() end,
      onStop = function() end,
    })
  end,
}

--- Components and motion, on one page.
---
--- The springs are the part worth watching on hardware: D034 records that a
--- spring integrated in one 50ms step diverges, and the sub-stepping that fixes
--- it was verified on desktop Lua. If the frame time on a real computer is much
--- worse than the bench predicts, this is where it shows - the bars stop being
--- smooth long before the numbers below get alarming.
pages[3] = {
  name = "Motion",
  build = function(scope, state)
    local swing = scope:Value(0)
    state.swing = swing

    local function bar(speed, damping, tint)
      return scope:Row({
        Height = 1,
        Gap = 1,
        Children = {
          scope:Muted({ Text = ("s%d d%.1f"):format(speed, damping), Width = 9 }),
          scope:Meter({
            Grow = 1,
            Value = scope:Spring(swing, speed, damping),
            Tint = tint,
          }),
        },
      })
    end

    return scope:Page({
      Title = "Motion",
      Status = "space to swing",
      Gap = 0,
      Children = {
        bar(8, 1, T.accent),
        bar(20, 1, T.good),
        bar(25, 0.6, T.warn),
        bar(40, 1.4, T.destructive),
        scope:Spacer({ Height = 1 }),
        scope:Row({
          Height = 1,
          Gap = 1,
          Children = {
            scope:Badge({ Text = "online", Tone = T.good }),
            scope:Badge({ Text = "stalled", Tone = T.warn }),
            scope:Badge({ Text = "open shaft", Tone = T.destructive }),
            scope:Badge({ Text = "idle" }),
          },
        }),
        scope:Spacer({ Grow = 1 }),
        scope:Row({
          Height = 1,
          Gap = 2,
          Children = {
            scope:Button({ Text = "Primary", Variant = "primary" }),
            scope:Button({ Text = "Secondary" }),
            scope:Button({ Text = "Ghost", Variant = "ghost" }),
            scope:Button({ Text = "Disabled", Disabled = true }),
          },
        }),
      },
      Actions = {
        scope:Button({
          Text = "Swing",
          Variant = "primary",
          OnClick = function()
            swing:set(swing:get() > 0.5 and 0 or 1)
          end,
        }),
      },
    })
  end,
}

---------------------------------------------------------------------------

--- Measure a frame the way the bench does, but on this machine.
---
--- `os.epoch("utc")` has millisecond resolution, which is far too coarse for a
--- sub-millisecond frame - so frames are accumulated and the mean reported. A
--- single reading here would be either 0ms or 1ms and would mean nothing.
local function newMeter()
  return { frames = 0, blits = 0, elapsed = 0, worst = 0 }
end

local function sample(meter, blits, milliseconds)
  meter.frames = meter.frames + 1
  meter.blits = meter.blits + blits
  meter.elapsed = meter.elapsed + milliseconds
  if milliseconds > meter.worst then
    meter.worst = milliseconds
  end
end

local function report(meter)
  if meter.frames == 0 then
    return "no frames yet"
  end
  return ("%d frames  %.1f blits  %.2f ms mean  %d ms worst"):format(
    meter.frames,
    meter.blits / meter.frames,
    meter.elapsed / meter.frames,
    meter.worst
  )
end

--- Put the terminal's colours back.
---
--- `ui.page` applies the ICOS palette, which redefines all sixteen slots. Those
--- are per-terminal and persist after a program exits, so quitting without
--- restoring them leaves the shell, `edit` and every other program running in
--- ICOS's greys until the computer reboots. `term.nativePaletteColour` is the
--- factory value for a slot, which is what CC's own programs expect to find.
local function restorePalette()
  for index = 0, 15 do
    local value = 2 ^ index
    term.setPaletteColour(value, term.nativePaletteColour(value))
  end
end

local function run()
  local screen = ccScreen.new(term.current())
  local input = ccInput.new()
  local width, height = screen.size()

  local index = 1
  local quit = false
  local meter = newMeter()
  local tick = 0

  while not quit do
    local scope = ui.scoped()
    local state = {
      devices = scope:Value(roster(0)),
      selected = scope:Value(nil),
      offset = scope:Value(0),
      -- Page chrome, two separators, the action row and the readout. Explicit
      -- because a table's capacity is given rather than measured (D031), and
      -- knowing the surface is the composition root's job.
      rows = math.max(2, height - 10),
    }

    local page = pages[index]
    local root = ui.page({
      scope = scope,
      screen = screen,
      build = function(s)
        return page.build(s, state)
      end,
      onError = function(err)
        state.lastError = tostring(err)
      end,
    })

    local switchTo, running = nil, true
    local heartbeat = os.startTimer(1)
    root:render()

    while running do
      -- The same gate `ui/host.lua` uses: a timeout only while something is
      -- moving, and a blocking pull otherwise. Written out here rather than
      -- calling `ui.run` because this loop also owns the heartbeat, the page
      -- keys and the readout, which is exactly what a real composition root
      -- does.
      local timeout = root:animating() and ui.anim.FRAME or nil
      local event = { input.pull(timeout) }
      local name = event[1]

      -- Ctrl-T and `q` both mean stop. Handled together so the two paths cannot
      -- drift, and because `terminate` arriving as an ordinary event rather than
      -- an error is the whole reason the cc adapter uses `pullEventRaw`.
      local quitting = name == "terminate" or (name == "key" and event[2] == keys.q)

      if quitting then
        running, quit = false, true
      elseif name == "timer" and event[2] == heartbeat then
        tick = tick + 1
        state.devices:set(roster(tick))
        heartbeat = os.startTimer(1)
      elseif name == "key" and event[2] >= keys.one and event[2] <= keys.three then
        switchTo, running = event[2] - keys.one + 1, false
      elseif name ~= nil then
        root:handle(table.unpack(event))
      end

      if root:animating() then
        root:advance(os.epoch("utc"))
      end

      local started = os.epoch("utc")
      local blits = root:render()
      local elapsed = os.epoch("utc") - started
      if blits > 0 then
        sample(meter, blits, elapsed)
      end

      -- Painted straight to the terminal underneath the page rather than through
      -- the framework. It has to describe the frame that just happened, and a
      -- node bound to its own frame cost would change the number by reporting it.
      term.setCursorPos(1, height)
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.lightGray)
      term.write(
        ("%-" .. width .. "s"):format(
          (" %s | %s | 1-3 page, q quit"):format(page.name, report(meter))
        )
      )
    end

    root:destroy()
    if switchTo then
      index = switchTo
      meter = newMeter()
    end
  end

  restorePalette()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("ICOS UI showcase")
  print(report(meter))
  print("")
  print("Compare with docs/ui-framework.md section 12. The bench there is")
  print("desktop Lua with a 10x margin assumed for Cobalt; these are the real")
  print("numbers, and they gate wiring this into the desktop.")
end

run()
