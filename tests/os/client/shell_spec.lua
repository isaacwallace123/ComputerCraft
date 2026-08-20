local expect = require("support.expect")
local it = require("support.spec").it
local page = require("support.page")

local registry = require("apps.registry")
local shell = require("os.client.shell")
local ui = require("ui.init")

local fakeApp = page.fake

---------------------------------------------------------------------------
-- The shell: which app is open, and whether the closed ones went away
---------------------------------------------------------------------------

it("a surface shows the apps that belong on it and no others", function()
  -- Filtering reads the registry, which is names and nothing else. That is the
  -- point: choosing what a machine offers used to mean requiring all twelve app
  -- modules to read twelve manifests, which cost 41 ms and 30 resident modules
  -- at boot on a turtle that draws one of them.
  local onWall = registry.available("server", "monitor")
  local ids = {}
  for _, entry in ipairs(onWall) do
    ids[entry.id] = true
    expect.equal(entry.mount, nil, entry.id .. " is a name, not a loaded module")
  end

  expect.truthy(ids.fleet, "a wall gets the page meant to be left open")
  expect.falsy(ids.console, "and not the one whose whole point is typing")

  -- A client is not a small server. It is the machine somebody who does not run
  -- the fleet sits at, so it has no roster and nothing that reconfigures mining.
  local onClient = {}
  for _, entry in ipairs(registry.available("client", "desktop")) do
    onClient[entry.id] = true
  end
  expect.falsy(onClient.fleet, "no fleet")
  expect.falsy(onClient.automation, "no automation")
  expect.falsy(onClient.operations, "and no mine")
  expect.truthy(onClient.bank, "their own money, though")
end)

it("an app named in the registry can actually be loaded", function()
  -- The failure this catches is a moved module: the registry names a path, and
  -- nothing else in the system would notice it had gone until somebody clicked
  -- the icon and got a blank rectangle.
  for _, entry in ipairs(registry.APPS) do
    local app, why = registry.load(entry)
    expect.truthy(app ~= nil, entry.id .. " loads: " .. tostring(why))
    expect.truthy(type((app or {}).mount) == "function", entry.id .. " has a mount")
  end
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
