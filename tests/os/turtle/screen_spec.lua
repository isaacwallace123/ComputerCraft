--- A turtle's screen, which is no longer a framework.
---
--- The UI framework came off turtles because CC charges every computer in a
--- world out of one ten-millisecond budget, so a turtle drawing a desktop was
--- spending the base station's time. What replaced it is a page written straight
--- at the screen port - which means the things the framework guaranteed have to
--- be guaranteed here instead, and that is what this file is.

local expect = require("support.expect")
local it = require("support.spec").it

local screen = require("os.turtle.screen")
local theme = require("ui.theme")

local T = theme.TOKENS

--- A screen that records what was written rather than showing it.
local function recorder(width, height)
  local state = { writes = {}, cleared = 0, width = width or 39, height = height or 13 }
  state.port = {
    size = function()
      return state.width, state.height
    end,
    blit = function(x, y, text, fg, bg)
      state.writes[#state.writes + 1] = { x = x, y = y, text = text, fg = fg, bg = bg }
    end,
    clear = function()
      state.cleared = state.cleared + 1
    end,
    isColour = function()
      return true
    end,
    setPalette = function() end,
    setCursor = function() end,
  }
  return state
end

local function values(rows)
  local out = {}
  for _, row in ipairs(rows) do
    out[row.label] = row.value
  end
  return out
end

it("a miner says what it is doing and what it needs to keep doing it", function()
  local rows = screen.miner({
    job = "rare",
    phase = "mining",
    general = "general-8",
    sector = 7,
    fuel = 51000,
    world = { x = 138, y = -59, z = -1176 },
  }, {})

  local seen = values(rows)
  expect.equal(seen.job, "rare")
  expect.equal(seen.phase, "mining")

  -- The one fact a miner knows that the base cannot infer. Coverage is assigned
  -- per chunk, so a turtle that has been reassigned knows before anybody else.
  expect.equal(seen.general, "general-8")
  expect.equal(seen.sector, "7")
  expect.equal(seen.fuel, "51.0k")
  expect.equal(seen.at, "138 -59 -1176")
end)

it("a turtle that does not know where it is says so rather than showing zeroes", function()
  local seen = values(screen.miner({ job = "rare" }, {}))

  -- `0 0 0` is a real place and this turtle is not at it. Showing coordinates
  -- for a turtle with no position is how somebody ends up looking for it there.
  expect.equal(seen.at, "locating...", "and it says what it is doing about it")

  -- And once it has a reason, that is what it says. "no position" on a turtle
  -- standing under a working constellation is a fact with no next step attached,
  -- and a turtle no longer has a Logs page for the reason to hide in.
  local stuck = values(screen.miner({ job = "rare" }, {
    locateWhy = "boxed in on all four sides",
  }))
  expect.contains(stuck.at, "boxed in")
  expect.equal(seen.sector, "none")
  expect.equal(seen.general, "none")
end)

it("empty fuel is red, because it is the one number that stops everything", function()
  local rows = screen.miner({ fuel = 0 }, {})
  for _, row in ipairs(rows) do
    if row.label == "fuel" then
      expect.equal(row.colour, T.destructive)
    end
  end

  -- And an unknown level is not drawn as though it were fine. A default that
  -- read as full is exactly the bug the fuel bar had.
  expect.equal(values(screen.miner({}, {})).fuel, "?")
end)

it("a general shows the turtles under it, which nothing else knows", function()
  local rows = screen.general({ phase = "working", fuel = 20000 }, {
    crew = {
      { label = "miner-4", phase = "mining" },
      { label = "miner-6", phase = "parked" },
    },
  })

  local seen = values(rows)
  expect.equal(seen.crew, "2 turtles")
  expect.equal(seen["  miner-4"], "mining")
  expect.equal(seen["  miner-6"], "parked")
end)

it("a general with nobody says so instead of showing an empty list", function()
  expect.equal(values(screen.general({}, {})).crew, "nobody yet")
end)

it("which page it is depends on the job, not on the machine", function()
  local general = screen.rows({
    snapshot = function()
      return { job = "general" }
    end,
    state = { crew = { { label = "miner-4" } } },
  })
  expect.equal(values(general).crew, "1 turtle")

  local miner = screen.rows({
    snapshot = function()
      return { job = "rare" }
    end,
    state = {},
  })
  expect.equal(values(miner).job, "rare")
end)

it("a frame that says the same thing is not drawn again", function()
  local rec = recorder()
  local rows = screen.miner({ job = "rare", phase = "mining", fuel = 51000 }, {})

  local drew, digest = screen.draw(rec.port, rows, "miner-4", nil)
  expect.truthy(drew, "the first frame is drawn")
  expect.truthy(#rec.writes > 0)

  -- A turtle redraws forever, and on a shared budget the cheapest frame is the
  -- one that does not happen. Comparing rendered text rather than the snapshot
  -- is what makes this correct: two different snapshots that say the same thing
  -- are the same frame.
  local before = #rec.writes
  local again = screen.draw(rec.port, rows, "miner-4", digest)
  expect.falsy(again, "the second is not")
  expect.equal(#rec.writes, before, "and nothing was written")
end)

it("a frame that changed is drawn", function()
  local rec = recorder()
  local _, digest = screen.draw(rec.port, screen.miner({ phase = "mining" }, {}), "miner-4", nil)
  local drew = screen.draw(rec.port, screen.miner({ phase = "parked" }, {}), "miner-4", digest)
  expect.truthy(drew)
end)

it("every write covers its whole box, so nothing leaves a tail behind", function()
  local rec = recorder(39, 13)
  screen.draw(rec.port, screen.miner({ job = "a-very-long-job-name" }, {}), "miner-4", nil)

  -- The one rule from the framework worth reimplementing: a shorter string than
  -- last frame that painted only itself would leave the old characters showing,
  -- which looks like a layout bug and is not.
  for _, write in ipairs(rec.writes) do
    expect.equal(#write.fg, #write.text, "one colour per character")
    expect.equal(#write.bg, #write.text)
    expect.truthy(write.x + #write.text - 1 <= rec.width, "and it stays on the screen")
  end
end)

it("the palette is uploaded, because nothing else does it here", function()
  -- Every other surface gets this from `ui/host.lua` when it mounts. A turtle
  -- mounts nothing, so the theme's slot numbers were being drawn in CC's default
  -- colours - slot 14 is red there rather than indigo, slot 3 light blue rather
  -- than grey. The screen looked wrong in a way that reads as a design choice
  -- rather than as a missing call.
  local uploaded = {}
  local rec = recorder()
  rec.port.setPalette = function(index)
    uploaded[index] = true
  end

  local slept = 0
  local ok = pcall(screen.run, {
    screen = rec.port,
    node = { label = "miner-6" },
    snapshot = function()
      return { job = "rare" }
    end,
    state = {},
    clock = {
      now = function()
        return 0
      end,
      sleep = function()
        slept = slept + 1
        error("parked", 0)
      end,
    },
  })

  expect.falsy(ok, "stopped by the spec, not by itself")
  expect.truthy(uploaded[0], "the whole palette")
  expect.truthy(uploaded[15])
end)

it("the loop waits on the clock, never on the input port", function()
  -- `ports/input.lua`'s null implementation returns immediately, which is what
  -- a spec has, what a machine with no keyboard has, and what a computer whose
  -- input has died has. A loop that waited on `pull` spins at full speed on all
  -- three - the failure `os/kernel/services/ticker.lua` exists to avoid, and one
  -- this file reproduced within an hour of being written.
  local pulls, slept = 0, 0
  local context = {
    input = {
      pull = function()
        pulls = pulls + 1
        return nil
      end,
      queue = function() end,
    },
    clock = {
      now = function()
        return 0
      end,
      sleep = function()
        slept = slept + 1
        if slept > 2 then
          error("parked", 0)
        end
      end,
    },
  }

  local ok = pcall(screen.run, context)
  expect.falsy(ok, "it stayed in its loop until the spec stopped it")
  expect.truthy(slept > 1, "sleeping between frames")
  expect.equal(pulls, 0, "and never asking the input port for anything")
end)

it("a general shows where it is, because that is why it has no crew", function()
  -- Chunk coverage is worked out from world positions, so a general with no
  -- position holds no ground - and a general that holds no ground has no crew.
  -- "nobody yet" and "no position" were the same fact reported twice, with only
  -- one of them on screen.
  local seen = values(screen.general({ world = { x = 43, y = 1, z = 425 } }, {}))
  expect.equal(seen.at, "43 1 425")

  local lost = values(screen.general({}, { locateWhy = "no GPS in range" }))
  expect.contains(lost.at, "no GPS")
end)

it("a service that has stopped says so, because there is no page that would", function()
  -- Taking the UI framework off turtles was the point, and it took the Services
  -- page with it - so a service that failed and backed off was invisible on the
  -- one machine somebody had walked to. "locating..." forever looked exactly
  -- like "the locate service died on its first attempt".
  local health = {
    { id = "job", state = "running" },
    { id = "locate", state = "waiting", gaveUp = true, lastError = "attempt to index a nil value" },
  }

  local fault = screen.fault({
    health = function()
      return health
    end,
  })
  expect.truthy(fault ~= nil, "the failure is reported")
  expect.equal((fault or {}).label, "locate")
  expect.contains((fault or {}).value, "nil value")

  -- And nothing is said when nothing is wrong. A row that appeared every time
  -- would be a row nobody reads.
  expect.equal(
    screen.fault({
      health = function()
        return { { id = "job", state = "running" } }
      end,
    }),
    nil
  )
  expect.equal(screen.fault(nil), nil)
end)

it("a service somebody switched off is not reported as a fault", function()
  -- Switching one off is a choice, and telling somebody their machine is broken
  -- because they turned something off is how a health report stops being read.
  expect.equal(
    screen.fault({
      health = function()
        return { { id = "sync", state = "disabled", disabled = true } }
      end,
    }),
    nil
  )
end)

it("a turtle shows the position it already has", function()
  -- `os/kernel/services/gps.lua` refreshes `.location` from the constellation
  -- every ten seconds, so a turtle that reported "no position" had its own
  -- coordinates written on its own disk.
  local seen = values(screen.miner({ world = { x = 52, y = 1, z = 425 } }, {}))
  expect.equal(seen.at, "52 1 425")
end)

it("the heading gets its own row, because it is a different missing thing", function()
  -- This was a `(fix)` after the coordinates, and somebody had to ask what it
  -- meant. It was jargon for "a GPS reading with no heading" - a sentence about
  -- the heading, wearing a position's clothes.
  --
  -- GPS gives three numbers and withholds the fourth, a turtle needs all four to
  -- dead reckon, and "why will this turtle not deploy" has its answer here and
  -- nowhere else.
  local known = values(screen.miner({ world = { x = 52, y = 1, z = 425 }, heading = 1 }, {}))
  expect.equal(known.facing, "east")

  local hunting = values(screen.miner({ world = { x = 52, y = 1, z = 425 } }, {}))
  expect.equal(hunting.facing, "working it out", "and it says it is looking")

  local stuck = values(screen.miner({ world = { x = 52, y = 1, z = 425 } }, {
    locateWhy = "blocked: Movement obstructed",
  }))
  expect.contains(stuck.facing, "Movement obstructed", "or why it cannot")
end)

---------------------------------------------------------------------------
-- Asking, when it cannot work it out
---------------------------------------------------------------------------

--- A turtle with a saved fix and a navigator that has no origin yet.
local function unheaded(options)
  options = options or {}
  local given = nil
  return {
    given = function()
      return given
    end,
    context = {
      screen = recorder().port,
      node = { label = "miner-6" },
      locator = {
        saved = function()
          return options.position ~= false and { x = 52, y = 1, z = 425 } or nil
        end,
        gps = function()
          return nil
        end,
      },
      nav = {
        hasOrigin = function()
          return options.located == true or given ~= nil
        end,
        setOrigin = function(x, y, z, heading)
          given = { x = x, y = y, z = z, heading = heading }
        end,
      },
    },
  }
end

it("a turtle that has already worked it out is never asked", function()
  -- The automatic path is the one that scales, because nobody walks to a
  -- turtle. Asking a machine that already knows would be asking somebody to
  -- confirm a measurement.
  local turtle = unheaded({ located = true })
  expect.falsy(screen.askFacing(turtle.context))
end)

it("a turtle with no position is not asked, because there is nowhere to put it", function()
  -- The position comes first and comes free. Without one there is nothing to
  -- anchor a heading to, and asking would collect an answer that cannot be
  -- written down.
  local turtle = unheaded({ position = false })
  expect.falsy(screen.askFacing(turtle.context))
  expect.equal(turtle.given(), nil)
end)

it("a machine with no screen is not asked either", function()
  local turtle = unheaded()
  turtle.context.screen = nil
  expect.falsy(screen.askFacing(turtle.context))
end)

it("the prompt only appears once the automatic attempt has given up", function()
  -- `locateFailed` rather than the absence of an origin, because those look
  -- identical for the first few seconds of every boot - and a prompt that
  -- appeared in that window would be one somebody answers before the machine has
  -- had a chance to answer it better.
  local asked = 0
  local turtle = unheaded()
  local context = turtle.context
  context.clock = {
    now = function()
      return 0
    end,
    sleep = function()
      error("parked", 0)
    end,
  }

  local real = screen.askFacing
  screen.askFacing = function()
    asked = asked + 1
    return false
  end

  pcall(screen.run, context)
  expect.equal(asked, 0, "still trying, so not yet")

  context.locateFailed = true
  pcall(screen.run, context)
  expect.equal(asked, 1, "tried and could not, so now")

  screen.askFacing = real
end)

---------------------------------------------------------------------------
-- The two controls along the bottom
---------------------------------------------------------------------------

it("the footer and the hit test agree about where each word is", function()
  -- Every hand-placed control gets this wrong once: the word is drawn in one
  -- place and the click is tested in another, and it looks like the button
  -- simply does not work. One function returns both, so they cannot disagree.
  local text, spans = screen.footer()
  expect.contains(text, "[L] locate")
  expect.contains(text, "[F] facing")

  for _, span in ipairs(spans) do
    local word = text:sub(span.from, span.to)
    expect.contains(word, span.action.label, "the span covers its own label")
  end
end)

it("a click on the bottom row picks the action under it", function()
  local height = 13
  expect.equal(screen.hit(2, height, height), "l", "on the word locate")
  expect.equal(screen.hit(14, height, height), "f", "on the word facing")
  expect.equal(screen.hit(2, height - 1, height), nil, "one row up is the status page")
  expect.equal(screen.hit(200, height, height), nil, "and past the end is nothing")
end)

it("asking for a facing is refused unless somebody asked on purpose", function()
  -- Re-asking a question the machine has already answered is how a measured
  -- heading gets replaced by a typed one. The exception is the button, where
  -- the person pressing it can see something the turtle cannot.
  local located = {
    screen = { size = function() return 39, 13 end },
    nav = { hasOrigin = function() return true end },
    locator = { saved = function() return nil end },
  }

  expect.falsy(screen.askFacing(located), "it already knows")

  -- With `force` it gets past the origin check and stops at the next one - no
  -- saved fix to anchor a heading to - rather than at the first.
  expect.falsy(screen.askFacing(located, { force = true }), "and still needs a position")
end)
