--- Turning a service off, and the difference between off and broken.

local expect = require("support.expect")
local fleet = require("support.fleet")
local it = require("support.spec").it

local app = require("apps.services.app")
local roles = require("os.kernel.roles")

it("a service that was switched off is not a service that failed", function()
  -- The whole reason `disabled` is its own state rather than a reuse of
  -- `gaveUp`. A machine where somebody switched GPS off is working exactly as
  -- intended; a machine where GPS gave up is broken. Reporting them the same
  -- way means either the health page lies about a deliberate choice, or it
  -- stops meaning anything about a real fault.
  local machine = fleet.booted(roles.CLIENT)
  machine.supervisor:step()

  expect.truthy(machine.supervisor:disable("gps"), "switched off")
  expect.truthy(machine.supervisor:disabled("gps"), "and it knows")

  local off
  for _, row in ipairs(app.rows(machine.supervisor, machine.clock.port.now())) do
    if row.id == "gps" then
      off = row
    end
  end

  expect.truthy(off, "still listed")
  expect.equal(off.status, "off", "as off, not as failed")
  expect.falsy(off.gaveUp, "and never as given up")
end)

it("switching a critical service off does not make the machine unhealthy", function()
  -- The health report exists for the person who made that choice. Telling them
  -- their machine is broken because they turned something off is how a health
  -- report stops being read.
  local machine = fleet.booted(roles.TURTLE, {
    runJob = function()
      error("bedrock", 0)
    end,
  })

  for _ = 1, 10 do
    machine.supervisor:step()
    machine.clock.advance(60)
  end
  expect.falsy(machine.supervisor:healthy(), "a failed critical service is unhealthy")

  machine.supervisor:disable("job")
  expect.truthy(machine.supervisor:healthy(), "and a switched-off one is not")
end)

it("a disabled service stays down through a restart sweep", function()
  -- Backoff must not quietly undo somebody's decision. A service that came back
  -- on its own a minute after being turned off would be worse than one that
  -- refused to turn off at all.
  local machine = fleet.booted(roles.CLIENT)
  machine.supervisor:step()
  machine.supervisor:disable("gps")

  for _ = 1, 10 do
    machine.supervisor:step()
    machine.clock.advance(60)
  end

  expect.truthy(machine.supervisor:disabled("gps"), "still off")
end)

it("turning it back on clears what broke it", function()
  -- "Off and on again" is what somebody does *after* fixing the thing that
  -- broke it, so leaving four failures on the record would mean one more
  -- mistake retires a service that has just been repaired.
  local machine = fleet.booted(roles.CLIENT, {
    draw = function()
      error("no screen", 0)
    end,
  })

  for _ = 1, 10 do
    machine.supervisor:step()
    machine.clock.advance(60)
  end

  machine.supervisor:disable("screen")
  machine.supervisor:enable("screen")

  for _, row in ipairs(machine.supervisor:health()) do
    if row.id == "screen" then
      expect.equal(row.failures, 0, "a clean slate")
      expect.falsy(row.gaveUp, "and no longer given up")
    end
  end
end)

it("the page refuses to switch off what draws it", function()
  -- Not the same list as `critical`. These are services whose absence would
  -- take away the means of turning them back on: switching off the thing
  -- drawing the page you are switching it from is a machine you have to reboot.
  expect.falsy(app.togglable({ id = "screen" }), "the screen")
  expect.falsy(app.togglable({ id = "ticker" }), "the thing that repaints it")
  expect.truthy(app.togglable({ id = "gps" }), "but gps is fair game")
  expect.truthy(app.togglable({ id = "discovery" }), "and so is discovery")
end)

it("off is drawn as muted, not as a warning", function()
  local T = require("ui.theme").TOKENS
  expect.equal(
    app.tone({ disabled = true, critical = true }),
    T.mutedFg,
    "deliberate is not a fault"
  )
  expect.equal(app.tone({ gaveUp = true, critical = true }), T.destructive, "and a fault still is")
end)
