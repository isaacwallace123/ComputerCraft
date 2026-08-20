--- Switching a service off, and it staying off.
---
--- `supervisor:disable` has existed since the Services page was written and
--- nothing wrote it down, so a choice lasted until the next reboot - which on a
--- base station is a long time and on a turtle is an afternoon. It looked like
--- it worked.
---
--- That matters more than tidiness: a machine's job is decided by which of its
--- services run. A GPS host is a client with the fleet mirror and the desktop
--- switched off, which is a configuration rather than a role - and a
--- configuration that forgets itself on restart is not one.

local expect = require("support.expect")
local it = require("support.spec").it

local service = require("os.kernel.service")
local supervisor = require("os.kernel.supervisor")
local switches = require("os.kernel.switches")

--- A context with a filesystem made of one table.
local function machine()
  local files = {}
  return {
    _files = files,
    storage = {
      read = function(path)
        return files[path]
      end,
      write = function(path, text)
        files[path] = text
        return true
      end,
    },
    serialise = {
      encode = function(value)
        local parts = {}
        for id, off in pairs(value.disabled or {}) do
          if off then
            parts[#parts + 1] = id
          end
        end
        table.sort(parts)
        return table.concat(parts, ",")
      end,
      decode = function(text)
        local disabled = {}
        for id in tostring(text):gmatch("[^,]+") do
          disabled[id] = true
        end
        return { disabled = disabled }
      end,
    },
  }
end

local function built(clock)
  local sup = supervisor.new({ clock = clock })
  local function idle(id, critical)
    return service.define({
      id = id,
      critical = critical,
      run = function()
        while true do
          coroutine.yield()
        end
      end,
    })
  end
  sup:add(idle("radio", true))
  sup:add(idle("sync"))
  sup:add(idle("screen"))
  return sup
end

local CLOCK = {
  now = function()
    return 0
  end,
  sleep = function() end,
}

it("what is switched off is written down", function()
  local context = machine()
  local sup = built(CLOCK)
  sup:start(context)

  sup:disable("sync")
  expect.truthy(switches.save(context, switches.current(sup)))

  -- Read back off the supervisor rather than tracked alongside it, so the file
  -- can only ever describe a state the machine was actually in.
  local saved = switches.load(context)
  expect.truthy(saved.sync)
  expect.falsy(saved.screen)
end)

it("and is still off after a reboot", function()
  local context = machine()
  local first = built(CLOCK)
  first:start(context)
  first:disable("sync")
  switches.save(context, switches.current(first))

  -- The machine comes back: a new supervisor, the same disk.
  local second = built(CLOCK)
  local applied = switches.apply(second, switches.load(context))
  second:start(context)

  expect.equal(applied, 1)
  expect.truthy(second:disabled("sync"), "still off")
  expect.falsy(second:disabled("screen"), "and the others came up")
end)

it("a critical service is never switched off by a file", function()
  local context = machine()
  local sup = built(CLOCK)

  -- Letting a saved file disable one would turn a mis-click a month ago into a
  -- base station that boots healthy and answers nobody, with the reason in a
  -- file nobody thinks to read.
  local applied, refused = switches.apply(sup, { radio = true, sync = true })

  expect.equal(applied, 1, "only the one that was allowed")
  expect.equal(#refused, 1)
  expect.equal(refused[1], "radio")
  expect.falsy(sup:disabled("radio"), "the radio came up anyway")
end)

it("a service that no longer exists is ignored, not an error", function()
  local sup = built(CLOCK)

  -- The file is written by a person on one build and read by whatever build is
  -- running later. Refusing to boot over a renamed service would make an update
  -- a thing that can strand a machine.
  local applied, refused = switches.apply(sup, { legacy = true })
  expect.equal(applied, 0)
  expect.equal(#refused, 0, "not refused - simply not there")
end)

it("an unreadable file is an empty set, not a reason to stop", function()
  -- A machine that would not boot because its service file was corrupt is a
  -- machine that cannot be used to fix its service file.
  local context = machine()
  context._files[switches.PATH] = "\1\2 not serialised"
  context.serialise.decode = function()
    error("bad")
  end

  local loaded = switches.load(context)
  expect.equal(next(loaded), nil, "nothing switched off")

  -- And a machine with no storage at all - every spec, and a headless one.
  expect.equal(next(switches.load({})), nil)
  expect.equal(next(switches.load(nil)), nil)
end)
