--- The console: what a typed line means, and what it does.
---
--- `legacy/console.lua` parses and performs in one function, which is why none
--- of its parsing has ever been tested. The failure that matters at a console
--- is not a crash - it is a command that looks like it worked, so most of what
--- is checked here is refusals.

local expect = require("support.expect")
local it = require("support.spec").it

local commands = require("apps.console.commands")
local console = require("apps.console.app")
local registry = require("domain.fleet.registry")

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

it("an empty line is not an error", function()
  -- Pressing enter on an empty prompt is not a mistake, and telling somebody
  -- off for it is how a console becomes annoying to use.
  local intent, why = commands.parse("")
  expect.equal(intent, nil, "nothing to do")
  expect.equal(why, nil, "and nothing to complain about")
end)

it("an unknown command names itself and points at help", function()
  local _, why = commands.parse("frobnicate the turtles")
  expect.contains(why, "frobnicate", "says what it did not understand")
  expect.contains(why, "help", "and what to type instead")
end)

it("a mine is placed as x z y, and negatives survive", function()
  -- The scar: ICOS v1.2.5's coordinate input used a greedy separator that could
  -- swallow the minus sign off a negative Y or Z, and the affected values could
  -- never be corrected automatically because the intended sign was unknowable.
  local intent = assert(commands.parse("mine at -120 64 -59"), "parsed")
  expect.equal(intent.kind, "mine.place", "places a mine")
  expect.equal(intent.centreX, -120, "x kept its sign")
  expect.equal(intent.centreZ, 64, "z")
  expect.equal(intent.surfaceY, -59, "and y kept its sign")
end)

it("a mine with too few numbers is refused rather than defaulted", function()
  -- A mine placed at a default centre is a mine in the wrong place, and it
  -- looks exactly like a mine in the right place until turtles start walking.
  local intent, why = commands.parse("mine at 50 50")
  expect.equal(intent, nil, "refused")
  expect.contains(why, "three numbers", "and says what was missing")
end)

it("a surface outside the world is refused", function()
  local _, why = commands.parse("mine at 0 0 900")
  expect.contains(why, "-63", "names the range")
end)

it("`mine` on its own asks where the mine is", function()
  expect.equal(commands.parse("mine").kind, "mine.show", "shows rather than places")
end)

it("recall and deploy take an id or everything", function()
  expect.equal(commands.parse("recall 7").id, 7, "one device")
  expect.equal(commands.parse("recall").kind, "want.all", "or all of them")
  expect.equal(commands.parse("recall all").kind, "want.all", "said either way")
  expect.equal(commands.parse("deploy 3").mode, "deploy", "deploy too")
end)

it("park refuses to apply to everything", function()
  -- Parking a whole fleet is something somebody would mean once and regret,
  -- and there is already a word for it.
  local _, why = commands.parse("park")
  expect.contains(why, "recall", "points at the command that does mean that")
  expect.equal(commands.parse("park 4").id, 4, "but one device is fine")
end)

it("a device id that is not a number is refused", function()
  local _, why = commands.parse("recall miner-7")
  expect.contains(why, "id", "asks for a number")
end)

it("help lists every usage exactly once", function()
  local lines = commands.help()
  expect.truthy(#lines >= 6, "several commands")
  for _, entry in ipairs(commands.HELP) do
    local found = false
    for _, line in ipairs(lines) do
      if line:find(entry.usage, 1, true) then
        found = true
      end
    end
    expect.truthy(found, entry.usage .. " appears in help")
  end
end)

---------------------------------------------------------------------------
-- Executing
---------------------------------------------------------------------------

local function context(options)
  options = options or {}
  local sent = {}
  local now = 1000 * 1000

  -- An explicit `if`, twice over. `noRadio and nil or {...}` yields the table
  -- because `nil or x` is x, and `noRadio and false or {...}` yields it too for
  -- the same reason - which is exactly the bug this suite found in three apps,
  -- and which I then wrote again while fixing it.
  local transport = nil
  if not options.noRadio then
    transport = {
      broadcast = function(message)
        sent[#sent + 1] = message
      end,
      send = function() end,
      receive = function() end,
      id = function()
        return 1
      end,
    }
  end

  return {
    transport = transport,
    clock = {
      now = function()
        return now
      end,
      sleep = function() end,
    },
    state = {
      fleet = options.fleet or registry.empty(),
      mine = options.mine or { plan = { configured = false }, sectors = {} },
    },
    _sent = sent,
  }
end

local function withDevice(id, label)
  local fleet = registry.empty()
  registry.observe(fleet, id, { label = label or ("miner-" .. id), phase = "mining" }, 1000 * 1000)
  return fleet
end

it("placing a mine asks the base rather than writing the file", function()
  -- A console that wrote `.mine` itself would be a second authority, and on a
  -- client it would be writing a file the server never reads.
  local ctx = context()
  console.execute(ctx, { kind = "mine.place", centreX = 10, centreZ = -20, surfaceY = 64 })

  expect.equal(#ctx._sent, 1, "one message")
  expect.equal(ctx._sent[1].kind, "mine", "a mine message")
  expect.equal(ctx._sent[1].body.action, "configure", "configuring it")
  expect.equal(ctx._sent[1].body.centreZ, -20, "with the coordinates given")
end)

it("placing a mine warns before it happens, not after", function()
  -- The answer arrives on the radio and may not arrive at all. Somebody about
  -- to throw away a day of tunnels should be told at the moment they ask.
  local out = console.execute(context(), {
    kind = "mine.place",
    centreX = 0,
    centreZ = 0,
    surfaceY = 64,
  })
  local warned = false
  for _, line in ipairs(out) do
    if line.level == "warn" and line.text:find("frontier") then
      warned = true
    end
  end
  expect.truthy(warned, "warned about clearing the frontiers")
end)

it("a console with no radio says so instead of pretending", function()
  local out = console.execute(context({ noRadio = true }), {
    kind = "mine.place",
    centreX = 0,
    centreZ = 0,
    surfaceY = 64,
  })
  expect.equal(out[1].level, "error", "an error")
  expect.contains(out[1].text, "radio", "naming the reason")
end)

it("recall asks the server to want it, and reports the ask, not the outcome", function()
  -- Saying "recalled" would be the "sent" status section 5 exists to abolish:
  -- the console cannot know whether a turtle heard.
  local ctx = context({ fleet = withDevice(7) })
  local out = console.execute(ctx, { kind = "want", mode = "recall", id = 7 })

  expect.equal(ctx._sent[1].kind, "want", "asks for a goal")
  expect.equal(ctx._sent[1].mode, "recall", "of the right kind")
  expect.contains(out[1].text, "asked", "and says it asked")
end)

it("a device the base has never heard of is refused, not invented", function()
  -- The one thing a fleet dashboard must never do is show a device that does
  -- not exist, and a console that sent to any number would be doing it by hand.
  local ctx = context({ fleet = withDevice(7) })
  local out = console.execute(ctx, { kind = "want", mode = "recall", id = 99 })

  expect.equal(#ctx._sent, 0, "nothing sent")
  expect.equal(out[1].level, "warn", "warned")
  expect.contains(out[1].text, "99", "naming the device")
end)

it("recall all sends one message per device, not one broadcast", function()
  -- The server holds goals per device. A "want this of everybody" message would
  -- be a second way to set them, one a device joining a second later would miss
  -- and nothing would retry.
  local fleet = withDevice(2)
  registry.observe(fleet, 3, { label = "miner-3" }, 1000 * 1000)
  local ctx = context({ fleet = fleet })

  console.execute(ctx, { kind = "want.all", mode = "recall" })
  expect.equal(#ctx._sent, 2, "one each")
end)

it("asking about a mine that does not exist says how to make one", function()
  local out = console.execute(context(), { kind = "mine.show" })
  expect.equal(out[1].level, "warn", "warned")
  expect.contains(out[1].text, "mine at", "and told how to fix it")
end)

it("an empty fleet is reported as empty rather than as a blank screen", function()
  local out = console.execute(context(), { kind = "devices" })
  expect.equal(out[1].level, "warn", "said something")
  expect.contains(out[1].text, "nothing", "and what")
end)
