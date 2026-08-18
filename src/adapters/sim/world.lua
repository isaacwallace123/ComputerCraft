--# selene: allow(global_usage)
--
-- The one file in `src/` allowed to write to `_G`, and the allowance is the
-- point rather than an oversight: an adapter whose job is to impersonate the CC
-- runtime, for code that has not been lifted onto ports yet, has nowhere else to
-- put the impersonation. Every other module in this repository must keep failing
-- this lint - that is what makes the rule in docs/icos-2.md section 3 real.

--- An in-memory Minecraft world, and both a CC: Tweaked API and a set of ports
--- over it.
---
--- ICOS is almost entirely state machines whose failure modes only appear after
--- a server restart, a lava pocket, or a full inventory forty minutes into a
--- trip. None of that can be reached from a linter, so until now every claim
--- about crash safety was an argument rather than a result.
---
--- This is the missing half. Terrain is a sparse override map over a generator
--- function, so a world is cheap to make and can be infinite. The turtle API is
--- implemented against it with the same refusals the real one has: you cannot
--- place into a solid block, `dig` returns false on air, and movement costs fuel.
---
--- Two properties make the crash tests possible:
---
---   * the filesystem lives in the world, not in a module, so wiping
---     `package.loaded` and requiring everything again is exactly a reboot; and
---   * every primitive that touches the world ticks a counter which can be armed
---     to throw, so "lose power immediately after the 37th block operation" is a
---     thing a test can ask for.
---
--- ## Two faces, on purpose
---
--- `install()` writes the CC APIs onto `_G`. That is a monkey-patch and it is
--- not how the code under test is meant to reach the world any more - but every
--- module written before ports existed reads `turtle`, `fs`, and `os` as
--- globals, and rewriting all of them at once is exactly the flag day
--- docs/icos-2.md refuses to have. So `install` stays for as long as anything
--- still needs it.
---
--- `ports()` is the other face: the same world, handed out as ordinary port
--- tables that a composition root can wire without touching `_G` at all. New
--- code takes ports; old code keeps its globals; both see one world, so a spec
--- can mix them while the migration is under way.

local world = {}
world.__index = world

local WORLD = {
  [0] = { x = 0, z = -1 },
  [1] = { x = 1, z = 0 },
  [2] = { x = 0, z = 1 },
  [3] = { x = -1, z = 0 },
}

--- Direction name -> the `turtle` function that works that face. CC encodes the
--- face in the function name rather than an argument, so a port that takes a
--- direction has to translate somewhere; here is cheaper than a branch per call.
local FACED = {
  dig = { forward = "dig", up = "digUp", down = "digDown" },
  detect = { forward = "detect", up = "detectUp", down = "detectDown" },
  inspect = { forward = "inspect", up = "inspectUp", down = "inspectDown" },
  place = { forward = "place", up = "placeUp", down = "placeDown" },
  drop = { forward = "drop", up = "dropUp", down = "dropDown" },
}

--- Raised by an armed crash counter. Distinct from a real error so a test can
--- tell "the turtle lost power here" apart from "the code is broken".
world.POWER_LOSS = "SIMULATED_POWER_LOSS"

local FUEL_VALUES = {
  ["minecraft:coal"] = 80,
  ["minecraft:charcoal"] = 80,
  ["minecraft:coal_block"] = 800,
  ["minecraft:lava_bucket"] = 1000,
}

--- What a block leaves behind when it is broken.
local DROPS = {
  ["minecraft:grass_block"] = "minecraft:dirt",
  ["minecraft:stone"] = "minecraft:cobblestone",
  ["minecraft:deepslate"] = "minecraft:cobbled_deepslate",
  ["minecraft:diamond_ore"] = "minecraft:diamond",
  ["minecraft:deepslate_diamond_ore"] = "minecraft:diamond",
  ["minecraft:redstone_ore"] = "minecraft:redstone",
  ["minecraft:deepslate_redstone_ore"] = "minecraft:redstone",
}

--- Blocks a turtle can move through and cannot stand a cap on.
local LIQUID = {
  ["minecraft:water"] = true,
  ["minecraft:lava"] = true,
  ["minecraft:flowing_water"] = true,
}

--- Items that are not placeable blocks, so `place` must refuse them.
local NOT_PLACEABLE = {
  ["minecraft:diamond"] = true,
  ["minecraft:redstone"] = true,
  ["minecraft:coal"] = true,
  ["minecraft:charcoal"] = true,
  ["minecraft:clay_ball"] = true,
  ["minecraft:lava_bucket"] = true,
  ["minecraft:bucket"] = true,
  ["minecraft:raw_iron"] = true,
}

local function key(x, y, z)
  return ("%d,%d,%d"):format(x, y, z)
end

--- A new world. `terrain` maps a coordinate to a block name or nil for air;
--- the default is solid stone below `groundY` with a grass surface.
function world.new(options)
  options = options or {}
  local groundY = options.groundY or 64

  local self = setmetatable({}, world)
  self.overrides = {}
  self.files = {}
  self.groundY = groundY
  self.terrain = options.terrain
    or function(_, y, _)
      if y > groundY then
        return nil
      end
      if y == groundY then
        return "minecraft:grass_block"
      end
      if y > groundY - 4 then
        return "minecraft:dirt"
      end
      if y < 0 then
        return "minecraft:deepslate"
      end
      return "minecraft:stone"
    end

  self.x = options.x or 0
  self.y = options.y or (groundY + 1)
  self.z = options.z or 0
  self.facing = options.facing or 0

  self.inventory = {}
  self.selected = 1
  self.fuel = options.fuel or 100000
  self.fuelLimit = 100000
  self.id = options.id or 1
  self.label = options.label or "miner-test"

  self.clock = 0
  self.epoch = 1700000000000
  self.ops = 0
  self.crashAfter = nil
  self.digs = 0
  self.moves = 0
  self.placements = 0
  self.chests = {}
  self.events = {}
  self.messages = {}
  return self
end

---------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------

function world:get(x, y, z)
  local override = self.overrides[key(x, y, z)]
  if override ~= nil then
    return override or nil
  end
  return self.terrain(x, y, z)
end

function world:set(x, y, z, name)
  self.overrides[key(x, y, z)] = name or false
end

function world:fill(x1, y1, z1, x2, y2, z2, name)
  for x = math.min(x1, x2), math.max(x1, x2) do
    for y = math.min(y1, y2), math.max(y1, y2) do
      for z = math.min(z1, z2), math.max(z1, z2) do
        self:set(x, y, z, name)
      end
    end
  end
end

--- Carve an open vertical shaft, which is what a pre-cap build left behind.
function world:openShaft(x, fromY, toY, z)
  for y = math.min(fromY, toY), math.max(fromY, toY) do
    self:set(x, y, z, nil)
  end
end

function world:solid(x, y, z)
  local block = self:get(x, y, z)
  return block ~= nil and not LIQUID[block]
end

---------------------------------------------------------------------------
-- Crash injection
---------------------------------------------------------------------------

--- Count one world interaction, throwing when an armed budget runs out.
function world:tick()
  self.ops = self.ops + 1
  if self.crashAfter and self.ops > self.crashAfter then
    self.crashAfter = nil
    error(world.POWER_LOSS, 0)
  end
end

---------------------------------------------------------------------------
-- Inventory
---------------------------------------------------------------------------

function world:give(slot, name, count)
  self.inventory[slot] = { name = name, count = count or 1 }
end

local function stackInto(self, name, count)
  for slot = 1, 16 do
    local stack = self.inventory[slot]
    if stack and stack.name == name and stack.count < 64 then
      local room = math.min(64 - stack.count, count)
      stack.count = stack.count + room
      count = count - room
      if count <= 0 then
        return true
      end
    end
  end
  for slot = 1, 16 do
    if not self.inventory[slot] then
      self.inventory[slot] = { name = name, count = count }
      return true
    end
  end
  return false -- inventory full; the drop is lost, exactly as in game
end

function world:count(name)
  local total = 0
  for slot = 1, 16 do
    local stack = self.inventory[slot]
    if stack and (not name or stack.name == name) then
      total = total + stack.count
    end
  end
  return total
end

---------------------------------------------------------------------------
-- The CC: Tweaked surface
---------------------------------------------------------------------------

local function ahead(self)
  local delta = WORLD[self.facing]
  return self.x + delta.x, self.y, self.z + delta.z
end

local function behind(self)
  local delta = WORLD[self.facing]
  return self.x - delta.x, self.y, self.z - delta.z
end

local function above(self)
  return self.x, self.y + 1, self.z
end

local function below(self)
  return self.x, self.y - 1, self.z
end

--- Build the CC API surface over this world and write it onto `_G`.
---
--- The tables are also kept on `self.api`, which is what `world:ports()` builds
--- on. One implementation of digging, one of the filesystem: a port that
--- reimplemented them would be a second simulator, and the two would disagree
--- on the exact edge - a refusal, a drop, a fuel cost - that the test was
--- written to pin down.
function world:install()
  local self_ = self

  local function move(target)
    self_:tick()
    local x, y, z = target(self_)
    if self_:solid(x, y, z) then
      return false, "Movement obstructed"
    end
    if self_.fuel <= 0 then
      return false, "Out of fuel"
    end
    self_.fuel = self_.fuel - 1
    self_.moves = self_.moves + 1
    self_.x, self_.y, self_.z = x, y, z
    return true
  end

  local function dig(target)
    self_:tick()
    local x, y, z = target(self_)
    local block = self_:get(x, y, z)
    if block == nil or LIQUID[block] then
      return false, "Nothing to dig here"
    end
    if block == "minecraft:bedrock" then
      return false, "Unbreakable block detected"
    end
    self_:set(x, y, z, nil)
    self_.digs = self_.digs + 1
    stackInto(self_, DROPS[block] or block, 1)
    return true
  end

  local function detect(target)
    local x, y, z = target(self_)
    return self_:solid(x, y, z)
  end

  local function inspect(target)
    local x, y, z = target(self_)
    local block = self_:get(x, y, z)
    if not block then
      return false, "No block to inspect"
    end
    return true, { name = block, state = {}, tags = {} }
  end

  local function place(target)
    self_:tick()
    local stack = self_.inventory[self_.selected]
    if not stack or stack.count <= 0 then
      return false, "No items to place"
    end
    if NOT_PLACEABLE[stack.name] then
      return false, "Cannot place item here"
    end
    local x, y, z = target(self_)
    if self_:solid(x, y, z) then
      return false, "Cannot place block here"
    end
    self_:set(x, y, z, stack.name)
    self_.placements = self_.placements + 1
    stack.count = stack.count - 1
    if stack.count <= 0 then
      self_.inventory[self_.selected] = nil
    end
    return true
  end

  local function drop(target, count)
    local stack = self_.inventory[self_.selected]
    if not stack then
      return false, "No items to drop"
    end
    local x, y, z = target(self_)
    local block = self_:get(x, y, z)
    local moved = math.min(count or stack.count, stack.count)

    local isContainer = block
      and (
        block:find("chest")
        or block:find("barrel")
        or block:find("box")
        or block:find("crate")
        or block:find("drawer")
      )
    if isContainer then
      local chest = self_.chests[key(x, y, z)]
        or { capacity = self_.chestCapacity or 1000, stored = 0 }
      self_.chests[key(x, y, z)] = chest
      moved = math.min(moved, math.max(0, chest.capacity - chest.stored))
      if moved <= 0 then
        return false, "No space for items"
      end
      chest.stored = chest.stored + moved
    end

    stack.count = stack.count - moved
    if stack.count <= 0 then
      self_.inventory[self_.selected] = nil
    end
    return moved > 0
  end

  _G.turtle = {
    forward = function()
      return move(ahead)
    end,
    back = function()
      return move(behind)
    end,
    up = function()
      return move(above)
    end,
    down = function()
      return move(below)
    end,
    turnLeft = function()
      self_:tick()
      self_.facing = (self_.facing + 3) % 4
      return true
    end,
    turnRight = function()
      self_:tick()
      self_.facing = (self_.facing + 1) % 4
      return true
    end,
    dig = function()
      return dig(ahead)
    end,
    digUp = function()
      return dig(above)
    end,
    digDown = function()
      return dig(below)
    end,
    detect = function()
      return detect(ahead)
    end,
    detectUp = function()
      return detect(above)
    end,
    detectDown = function()
      return detect(below)
    end,
    inspect = function()
      return inspect(ahead)
    end,
    inspectUp = function()
      return inspect(above)
    end,
    inspectDown = function()
      return inspect(below)
    end,
    place = function()
      return place(ahead)
    end,
    placeUp = function()
      return place(above)
    end,
    placeDown = function()
      return place(below)
    end,
    drop = function(count)
      return drop(ahead, count)
    end,
    dropUp = function(count)
      return drop(above, count)
    end,
    dropDown = function(count)
      return drop(below, count)
    end,
    attack = function()
      return false
    end,
    attackUp = function()
      return false
    end,
    attackDown = function()
      return false
    end,
    select = function(slot)
      self_.selected = slot
      return true
    end,
    getSelectedSlot = function()
      return self_.selected
    end,
    getItemCount = function(slot)
      local stack = self_.inventory[slot or self_.selected]
      return stack and stack.count or 0
    end,
    getItemDetail = function(slot)
      local stack = self_.inventory[slot or self_.selected]
      if not stack then
        return nil
      end
      return { name = stack.name, count = stack.count, damage = 0 }
    end,
    getItemSpace = function(slot)
      local stack = self_.inventory[slot or self_.selected]
      return stack and (64 - stack.count) or 64
    end,
    transferTo = function(slot, count)
      local from = self_.inventory[self_.selected]
      if not from then
        return false
      end
      local to = self_.inventory[slot]
      local moved = math.min(count or from.count, from.count)
      if to then
        if to.name ~= from.name then
          return false
        end
        moved = math.min(moved, 64 - to.count)
        if moved <= 0 then
          return false
        end
        to.count = to.count + moved
      else
        self_.inventory[slot] = { name = from.name, count = moved }
      end
      from.count = from.count - moved
      if from.count <= 0 then
        self_.inventory[self_.selected] = nil
      end
      return true
    end,
    getFuelLevel = function()
      return self_.fuel
    end,
    getFuelLimit = function()
      return self_.fuelLimit
    end,
    refuel = function(count)
      local stack = self_.inventory[self_.selected]
      if not stack or not FUEL_VALUES[stack.name] then
        return false
      end
      if count == 0 then
        return true
      end
      local burn = math.min(count or stack.count, stack.count)
      self_.fuel = math.min(self_.fuelLimit, self_.fuel + burn * FUEL_VALUES[stack.name])
      stack.count = stack.count - burn
      if stack.count <= 0 then
        self_.inventory[self_.selected] = nil
      end
      return true
    end,
  }

  ---------------------------------------------------------------------------
  -- Filesystem, held in the world so a "reboot" keeps it
  ---------------------------------------------------------------------------

  _G.fs = {
    exists = function(path)
      return self_.files[path] ~= nil
    end,
    isDir = function()
      return false
    end,
    getDir = function(path)
      return path:match("^(.*)/[^/]*$") or ""
    end,
    makeDir = function() end,
    delete = function(path)
      self_.files[path] = nil
    end,
    move = function(from, to)
      self_.files[to] = self_.files[from]
      self_.files[from] = nil
    end,
    open = function(path, mode)
      if mode == "r" then
        local content = self_.files[path]
        if not content then
          return nil
        end
        local offset = 1
        return {
          readAll = function()
            return content
          end,
          readLine = function()
            if offset > #content then
              return nil
            end
            local stop = content:find("\n", offset, true)
            local line = stop and content:sub(offset, stop - 1) or content:sub(offset)
            offset = (stop or #content) + 1
            return line
          end,
          close = function() end,
        }
      end

      local buffer = mode == "a" and (self_.files[path] or "") or ""
      return {
        write = function(text)
          buffer = buffer .. tostring(text)
        end,
        writeLine = function(text)
          buffer = buffer .. tostring(text) .. "\n"
        end,
        close = function()
          self_.files[path] = buffer
        end,
      }
    end,
  }

  ---------------------------------------------------------------------------
  -- Everything else the modules touch
  ---------------------------------------------------------------------------

  _G.os = {
    epoch = function()
      self_.epoch = self_.epoch + 50
      return self_.epoch
    end,
    clock = function()
      return self_.clock
    end,
    time = function()
      return 12
    end,
    day = function()
      return 1
    end,
    getComputerID = function()
      return self_.id
    end,
    getComputerLabel = function()
      return self_.label
    end,
    setComputerLabel = function(label)
      self_.label = label
    end,
    queueEvent = function(...)
      self_.events[#self_.events + 1] = { ... }
    end,
    pullEvent = function()
      return "terminate"
    end,
    sleep = function() end,
  }

  _G.sleep = function(seconds)
    self_.clock = self_.clock + (seconds or 0)
  end

  _G.textutils = {
    serialise = function(value)
      local function encode(item, indent)
        local kind = type(item)
        if kind == "string" then
          return ("%q"):format(item)
        end
        if kind ~= "table" then
          return tostring(item)
        end
        local parts = {}
        local pad = indent .. "  "
        for _, entry in ipairs(item) do
          parts[#parts + 1] = pad .. encode(entry, pad) .. ","
        end
        local seen = #item
        local names = {}
        for name in pairs(item) do
          if type(name) ~= "number" or name > seen or name < 1 then
            names[#names + 1] = name
          end
        end
        table.sort(names, function(a, b)
          return tostring(a) < tostring(b)
        end)
        for _, name in ipairs(names) do
          parts[#parts + 1] = ("%s[%s] = %s,"):format(
            pad,
            encode(name, pad),
            encode(item[name], pad)
          )
        end
        if #parts == 0 then
          return "{}"
        end
        return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
      end
      return encode(value, "")
    end,
    unserialise = function(text)
      local chunk = load("return " .. tostring(text), "=serialised", "t", {})
      if not chunk then
        return nil
      end
      local ok, value = pcall(chunk)
      return ok and value or nil
    end,
    formatTime = function()
      return "12:00"
    end,
  }
  _G.textutils.serialize = _G.textutils.serialise
  _G.textutils.unserialize = _G.textutils.unserialise

  _G.peripheral = {
    getNames = function()
      return {}
    end,
    hasType = function()
      return false
    end,
    wrap = function()
      return nil
    end,
    find = function()
      return nil
    end,
    getType = function()
      return nil
    end,
  }

  _G.rednet = {
    isOpen = function()
      return false
    end,
    open = function() end,
    close = function() end,
    host = function() end,
    unhost = function() end,
    lookup = function()
      return nil
    end,
    send = function()
      return false
    end,
    broadcast = function() end,
    receive = function()
      return nil
    end,
  }

  _G.gps = {
    locate = function()
      return nil
    end,
  }

  _G.colors = setmetatable({}, {
    __index = function()
      return 1
    end,
  })
  _G.colours = _G.colors
  _G.term = setmetatable({}, {
    __index = function()
      return function()
        return 1
      end
    end,
  })
  _G.keys = setmetatable({}, {
    __index = function()
      return 0
    end,
  })
  _G.http = nil
  _G.printError = function() end
  _G.write = function() end
  _G.read = function()
    return ""
  end

  self.api = {
    turtle = _G.turtle,
    fs = _G.fs,
    os = _G.os,
    gps = _G.gps,
    sleep = _G.sleep,
  }

  return self
end

---------------------------------------------------------------------------
-- Ports
---------------------------------------------------------------------------

--- Port tables over this world, for code that takes its dependencies rather
--- than reaching for globals.
---
--- Built over `self.api`, so a spec that mixes ported and unported code sees one
--- world through both. `install` must have run first; that is what fills
--- `self.api`, and calling this before it is a programming error rather than a
--- recoverable one.
function world:ports()
  local self_ = self
  assert(self.api, "world:ports() before world:install()")
  local api = self.api

  local clock = require("ports.clock").check({
    now = function()
      return api.os.epoch("utc")
    end,
    --- Advances the world's clock without waiting. Every spec that measures a
    --- timeout depends on this: a lease that expires after fifteen minutes has
    --- to be reachable in a test that finishes in milliseconds.
    sleep = function(seconds)
      api.sleep(seconds)
    end,
  })

  local storage = require("ports.storage").check({
    read = function(path)
      return self_.files[path]
    end,
    write = function(path, text)
      -- No `.tmp` dance. The in-memory store replaces a value in one assignment,
      -- so there is no window to be interrupted in - and a simulated crash
      -- counter is not ticked here on purpose, because the interesting power
      -- losses are the ones around block operations, which do tick.
      self_.files[path] = tostring(text)
      return true
    end,
    list = function(path)
      local prefix = path == "" and "" or (path:gsub("/$", "") .. "/")
      local names, seen = {}, {}
      for name in pairs(self_.files) do
        if name:sub(1, #prefix) == prefix then
          local rest = name:sub(#prefix + 1):match("^[^/]+")
          if rest and not seen[rest] then
            seen[rest] = true
            names[#names + 1] = rest
          end
        end
      end
      table.sort(names)
      return names
    end,
    delete = function(path)
      self_.files[path] = nil
      return true
    end,
  })

  local body = require("ports.body").check({
    move = function(direction)
      local call = api.turtle[direction]
      if not call then
        return false, "no such direction: " .. tostring(direction)
      end
      return call()
    end,
    turn = function(direction)
      if direction == "left" then
        return api.turtle.turnLeft()
      end
      if direction == "right" then
        return api.turtle.turnRight()
      end
      return false, "no such turn: " .. tostring(direction)
    end,
    dig = function(direction)
      return api.turtle[FACED.dig[direction]]()
    end,
    detect = function(direction)
      return api.turtle[FACED.detect[direction]]() == true
    end,
    inspect = function(direction)
      return api.turtle[FACED.inspect[direction]]()
    end,
    place = function(direction)
      return api.turtle[FACED.place[direction]]()
    end,
    drop = function(direction, count)
      return api.turtle[FACED.drop[direction]](count)
    end,
    select = function(slot)
      return api.turtle.select(slot)
    end,
    slot = function()
      return api.turtle.getSelectedSlot()
    end,
    stack = function(slot)
      return api.turtle.getItemDetail(slot)
    end,
    fuel = function()
      return api.turtle.getFuelLevel(), api.turtle.getFuelLimit()
    end,
    refuel = function(count)
      return api.turtle.refuel(count)
    end,
  })

  local locator = require("ports.locator").check({
    --- Answers only if the test set `world.fix`. Absent by default because a
    --- turtle underground usually cannot see four hosts, and code that assumes
    --- GPS always answers is the code worth catching.
    gps = function()
      local fix = self_.fix
      if not fix then
        return nil
      end
      return fix.x, fix.y, fix.z
    end,
    saved = function()
      return self_.location
    end,
  })

  --- A loopback radio. `broadcast` and `send` both land in one queue that
  --- `receive` drains, so a single-machine spec can drive its own message
  --- handling without a second world.
  ---
  --- `world.dropMessages` throws sends away instead of queueing them, which is
  --- the only interesting thing a fake radio does: D004 says correctness may
  --- never depend on delivery, and the way to hold that claim honest is to be
  --- able to switch delivery off mid-test.
  local transport = require("ports.transport").check({
    send = function(id, message, protocol)
      if self_.dropMessages then
        return false
      end
      self_.messages[#self_.messages + 1] = {
        from = self_.id,
        to = id,
        message = message,
        protocol = protocol,
      }
      return true
    end,
    broadcast = function(message, protocol)
      if self_.dropMessages then
        return
      end
      self_.messages[#self_.messages + 1] = {
        from = self_.id,
        message = message,
        protocol = protocol,
      }
    end,
    --- Yields when it has nothing, because a real one does.
    ---
    --- `rednet.receive` blocks on `os.pullEvent`, and `sleep` blocks on a timer;
    --- either way a CC service loop hands control back between messages. This
    --- simulated one used to advance a counter and return, which is fine for a
    --- spec that calls it directly and a hang for one that runs a service under
    --- `os/supervisor.lua` - the loop spins, `coroutine.resume` never returns,
    --- and there is nothing a supervisor can do about it from the outside.
    ---
    --- Guarded by `isyieldable` so a spec calling this on the main coroutine,
    --- which is most of them, behaves exactly as before.
    receive = function(protocol, timeoutSeconds)
      for index, entry in ipairs(self_.messages) do
        if protocol == nil or entry.protocol == protocol then
          table.remove(self_.messages, index)
          return entry.from, entry.message, entry.protocol
        end
      end
      api.sleep(timeoutSeconds or 0)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
      return nil
    end,
    id = function()
      return self_.id
    end,
  })

  return {
    clock = clock,
    storage = storage,
    body = body,
    locator = locator,
    transport = transport,
  }
end

--- Modules a reboot forgets: the code that runs on the simulated machine.
---
--- ## The rule for adding to this list
---
--- A module may only be forgotten if **nothing outside the reboot set holds a
--- reference to it across the boundary**. Re-requiring a module produces a new
--- copy of every table inside it, including its metatables - so a value created
--- by the old copy fails an identity test in the new one, and does so silently.
---
--- `^ui%.` was on this list and had to come off. `ui/reactive.lua` identifies a
--- state object by its metatable; `ui/anim.lua` requires reactive lazily; and a
--- spec file holds its own reference from load time. After a world spec dropped
--- the cache, an animation built through the old runtime asked the *new*
--- reactive whether its goal was a state object, was told no, and quietly
--- animated a table. Nothing errored where the mistake was.
---
--- `adapters%.` is absent for a related reason: the world and the port tables
--- built over it are the harness holding the machine, and dropping them mid-test
--- is closer to swapping the computer than to restarting it.
---
--- What remains is the code a rebooting turtle actually runs. None of it carries
--- identity across a require - no metatables, no sentinel tables - which is what
--- makes forgetting it equivalent to a reboot rather than to a subtle fork.
local FORGOTTEN = {
  "^turtle%.",
  "^core%.",
  "^jobs%.",
  "^mine%.",
  "^domain%.",
  "^ports%.",
}

--- Wipe every loaded ICOS module. With the filesystem living in the world, this
--- is precisely what a reboot does: code fresh, state persisted.
function world.reboot()
  for name in pairs(package.loaded) do
    for _, pattern in ipairs(FORGOTTEN) do
      if name:find(pattern) then
        package.loaded[name] = nil
        break
      end
    end
  end
end

return world
