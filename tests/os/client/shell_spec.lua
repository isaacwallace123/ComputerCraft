local expect = require("support.expect")
local it = require("support.spec").it
local page = require("support.page")

local shell = require("os.client.shell")
local ui = require("ui.init")

local fakeApp = page.fake

---------------------------------------------------------------------------
-- The shell: which app is open, and whether the closed ones went away
---------------------------------------------------------------------------

it("a surface shows the apps that belong on it and no others", function()
  local apps = {
    fakeApp("devices", "Devices", { "client", "mobile" }, { "desktop", "monitor" }),
    fakeApp("console", "Console", { "client" }, { "desktop" }),
    fakeApp("turtle-only", "Turtle", { "turtle" }, { "launcher" }),
  }

  expect.equal(#shell.available(apps, "client", "desktop"), 2, "a desktop gets both client apps")
  expect.equal(#shell.available(apps, "client", "monitor"), 1, "a monitor gets only the one")
  expect.equal(#shell.available(apps, "mobile", "desktop"), 1, "and a handheld gets its own")
  expect.equal(#shell.available(apps, "server", "desktop"), 0, "a server draws nothing")
end)

it("the app switcher wraps rather than stopping at the end", function()
  -- A taskbar you can fall off the end of is one somebody has to look at to use.
  local scope = ui.scoped()
  local state = shell.state(scope, { fakeApp("a", "A"), fakeApp("b", "B"), fakeApp("c", "C") })

  expect.equal(shell.switch(state, 1), 2, "forward")
  expect.equal(shell.switch(state, 1), 3, "forward again")
  expect.equal(shell.switch(state, 1), 1, "and round")
  expect.equal(shell.switch(state, -1), 3, "backwards wraps too")
  scope:destroy()
end)

it("switching apps destroys the one that was open", function()
  -- The failure this guards is quiet and expensive: ten pages of Computed
  -- recalculating on every heartbeat so that nine of them can be invisible.
  local before = ui.live()

  local scope = ui.scoped()
  local state = shell.state(scope, { fakeApp("a", "A"), fakeApp("b", "B") })
  local page = scope:Computed(function(use)
    return use(state.index)
  end)
  expect.equal(page:get(), 1, "built")
  expect.truthy(ui.live() > before, "and it is alive")

  scope:destroy()
  expect.equal(ui.live(), before, "and gone once closed")
end)

it("an empty surface is not a crash", function()
  -- A monitor whose role has no apps is a real configuration, and the shell
  -- returning is better than a shell that indexes nil.
  local scope = ui.scoped()
  local state = shell.state(scope, {})
  expect.falsy(shell.switch(state, 1), "nothing to switch to")
  scope:destroy()
end)
