--- Every app this system has, named without loading any of them.
---
--- ## Why this file exists
---
--- `shell.apps()` used to be a list of `require` calls, and filtering it by role
--- meant loading all twelve apps to read twelve manifests. Measured cold, that
--- is **41 ms and 30 modules** on a desktop CPU running PUC Lua; in game it runs
--- on Cobalt, inside a scheduler that hands each computer about ten milliseconds
--- a tick. A turtle paid it at boot for eleven pages it will never draw, and
--- every one of those modules stayed resident for the life of the machine.
---
--- So identity lives here as data and the code stays on disk until somebody
--- opens it. Filtering is a table walk; opening an app is one `require`.
---
--- ## It is the only place an app is described
---
--- There was an `app.manifest` in each module saying the same thing. Two
--- descriptions of one app is the failure this codebase keeps writing comments
--- about: they agree until they do not, and the one that decides is whichever
--- the caller happened to read. The modules now export `mount` and their own
--- helpers, and nothing else.
---
--- It is also what an installer needs. "Which files does a server need" is
--- answerable from `roles` plus a require walk, which is what lets a client ship
--- without the mine, the fleet registry, or eleven pages it would never show.
---
--- ## A client is not a small server
---
--- The role lists are a product decision, not a capability one. A base station
--- is the technical machine - the fleet, the mine, the disks, the console, the
--- bank's books. A client is the machine somebody who does not run the fleet
--- sits at: their own balance, and something to do. Putting Automation on it
--- would be putting a control that reconfigures a mining fleet in front of
--- somebody who wanted to check their money.

local registry = {}

--- A glyph per app, chosen for what it suggests at one character.
---
--- CC's font is code page 437, so these are shapes that actually exist rather
--- than the ones a modern terminal would offer. A missing codepoint renders as a
--- question-mark box, which is worse than a plain letter.
---
--- These replaced 8x6 sprites on the desktop. The sprites are still here - see
--- `ui/icons.lua`, which draws ores and blocks - but a wall of them costs 1.6x a
--- wall of glyphs to build and, more to the point, reads worse: four cells of
--- two-colour pixels is not enough to draw an object, so every one of them came
--- out as a blue smudge that had to be labelled anyway.
registry.APPS = {
  ---------------------------------------------------------------------------
  -- The base station
  ---------------------------------------------------------------------------

  {
    id = "fleet",
    name = "Fleet",
    glyph = "\4", -- diamond: the fleet as a whole
    module = "apps.fleet.app",
    roles = { "server", "mobile" },
    surfaces = { "desktop", "monitor", "handheld" },
  },
  {
    id = "operations",
    name = "Mine",
    glyph = "\30", -- triangle: a shaft head
    module = "apps.operations.app",
    roles = { "server" },
    surfaces = { "desktop", "monitor" },
  },
  {
    id = "automation",
    name = "Automation",
    glyph = "\24", -- up arrow: something acting on its own
    module = "apps.automation.app",
    roles = { "server" },
    surfaces = { "desktop", "monitor" },
  },
  {
    id = "gps",
    name = "GPS",
    glyph = "\10", -- ring: a beacon putting out circles
    module = "apps.gps.app",
    roles = { "server", "mobile" },
    surfaces = { "desktop", "monitor", "handheld" },
  },
  {
    id = "disks",
    name = "Disks",
    glyph = "\254", -- filled square: something plugged in
    module = "apps.disks.app",
    roles = { "server" },
    surfaces = { "desktop", "monitor" },
  },
  {
    id = "console",
    name = "Console",
    glyph = "\16", -- caret: a prompt
    module = "apps.console.app",
    roles = { "server" },
    surfaces = { "desktop" },
  },

  ---------------------------------------------------------------------------
  -- Anywhere
  ---------------------------------------------------------------------------

  {
    id = "bank",
    name = "Bank",
    glyph = "\9", -- ring: a vault door
    module = "apps.bank.app",
    roles = { "server", "client", "mobile" },
    surfaces = { "desktop", "monitor", "handheld" },
  },
  {
    id = "services",
    name = "Services",
    glyph = "\15", -- sun: what is running
    module = "apps.services.app",
    roles = { "server", "client", "mobile" },
    surfaces = { "desktop", "monitor", "handheld" },
  },
  {
    id = "logs",
    name = "Logs",
    glyph = "\29", -- lines: a record
    module = "apps.logs.app",
    roles = { "server" },
    surfaces = { "desktop", "monitor" },
  },
  {
    id = "hardware",
    name = "Hardware",
    glyph = "\247", -- plug: what is attached
    module = "apps.hardware.app",
    roles = { "server" },
    surfaces = { "desktop", "monitor" },
  },

  ---------------------------------------------------------------------------
  -- The turtle's own page
  ---------------------------------------------------------------------------

  {
    id = "job",
    name = "Job",
    glyph = "\18", -- up-down arrow: a shaft being worked
    module = "apps.job.app",
    roles = { "server" },
    surfaces = { "desktop" },
  },
}

--- Find one app by id, without loading it.
function registry.find(id)
  for _, entry in ipairs(registry.APPS) do
    if entry.id == id then
      return entry
    end
  end
  return nil
end

local function lists(entry, key, wanted)
  for _, value in ipairs(entry[key] or {}) do
    if value == wanted then
      return true
    end
  end
  return false
end

--- The apps a machine of this role, drawing on this surface, should offer.
---
--- Both have to match. A page can be right for a server and wrong for the wall
--- it is on - D020: a monitor has no keyboard, so a page whose whole point is
--- typing does not belong there however capable the machine is.
---
--- Returns the registry entries, not the modules. Nothing is loaded.
function registry.available(role, surface)
  local out = {}
  for _, entry in ipairs(registry.APPS) do
    if lists(entry, "roles", role) and lists(entry, "surfaces", surface) then
      out[#out + 1] = entry
    end
  end
  return out
end

--- Load one app's module.
---
--- Called when somebody opens it, not when the machine boots. `require` caches,
--- so opening the same app twice costs one lookup - and a page nobody opens
--- costs nothing at all, which on a turtle is most of this list.
function registry.load(entry)
  if type(entry) ~= "table" or type(entry.module) ~= "string" then
    return nil
  end
  local ok, app = pcall(require, entry.module)
  if not ok then
    return nil, tostring(app)
  end
  return app
end

--- Every module every app lives in.
---
--- Not used at runtime - `tools/make-manifest.ps1` reads it to work out which
--- files a role needs, so that a client does not ship the fleet registry and a
--- turtle does not ship the console.
function registry.modules()
  local out = {}
  for _, entry in ipairs(registry.APPS) do
    out[#out + 1] = entry.module
  end
  return out
end

return registry
