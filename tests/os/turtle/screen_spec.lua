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
  expect.equal(seen.at, "no position")
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
