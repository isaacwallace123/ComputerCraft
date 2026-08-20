--- The general: a turtle whose entire job is to stand still and be loaded.
---
--- ## Why a turtle does this at all
---
--- §1's first failure was that control is an event and a turtle out of render
--- distance never hears it. Desired state fixed the *delivery* of orders and
--- cannot fix the other half: a turtle in an unloaded chunk is not disobeying,
--- it is **not executing**. An unattended fleet therefore has to carry its own
--- loaded region with it, and a chunk-loading turtle parked in a chunk is how.
---
--- Advanced Peripherals' Chunky Turtle holds the chunk it is standing in and
--- exposes no methods whatsoever - it is a passive upgrade. So this job has
--- nothing to call: holding a chunk *is* standing in it, and the whole of the
--- work is getting to the right chunk and then not leaving.
---
--- ## It is a job, not a role
---
--- D038: the four roles are form factors, and a chunk loader is a turtle. Making
--- it a role would have meant a fifth operating system differing from the turtle
--- by one `require`. So this is a catalogue entry like quarry or rare, it is
--- assigned the same way, it is recalled the same way, and the same runner drives
--- it.
---
--- ## Holding is a run that does not return
---
--- Every other job returns after a pass and lets `Runner` decide what happens
--- next. This one must not, and the reason is specific: `Runner:start` declares
--- home at the moment of departure, so a general that cycled would re-anchor its
--- own origin every few seconds and lose the return route its fuel reserve is
--- priced against. Holding is therefore a loop inside `run`, and the only thing
--- that ends it is a recall.
---
--- That costs nothing. The heartbeat is a separate service (a separate coroutine
--- under ICOS 1's `parallel`, a separate supervised service under ICOS 2), so a
--- job that sleeps forever is a job that yields forever - which is exactly what a
--- machine standing still should do.
---
--- ## What the base learns, and how
---
--- Nothing here reports its chunk. The server derives it from the world position
--- already in every heartbeat, and that is deliberate: a turtle saying which
--- chunk it holds is a claim, whereas a turtle saying where it is standing is an
--- observation. `domain/fleet/coverage.lua` trusts the second and would have to
--- audit the first.

local config = require("adapters.cc.config")
local fuel = require("os.turtle.device.fuel")
local grid = require("domain.chunk.grid")
local nav = require("os.turtle.device.nav")
local settings = require("domain.turtle.settings")

local general = {
  name = "general",
  label = "Chunk loader",
  PATH = ".general",

  -- Every field is a world coordinate, because a post is a place in the world
  -- rather than an offset from wherever this turtle happened to start. The base
  -- picks it from the chunk grid and sends all three.
  settingFields = {
    { label = "Post X", key = "postX", step = 16, min = -30000000, max = 30000000 },
    { label = "Post Z", key = "postZ", step = 16, min = -30000000, max = 30000000 },
    { label = "Post Y", key = "postY", step = 1, min = -63, max = 319 },
  },
}

--- How long a holding general sleeps between checks.
---
--- One second. It is doing nothing, and the only thing it is waiting for is a
--- recall - which arrives on the heartbeat service, not here. Anything shorter
--- would be a busy turtle pretending to be a stationary one.
general.HOLD = 1

--- Blocks of clearance to fly with over terrain on the way to a post.
---
--- Generals travel above ground the whole way, which is what
--- `nav.CLIMB_LIMIT` terrain-following is for. A general that tunnelled to its
--- post would leave a bore through the landscape and, worse, a vertical hole
--- where it climbed out - the exact surface damage D023 exists to prevent.
general.CRUISE = 6

local DEFAULTS = {
  postX = 0,
  postZ = 0,
  postY = 64,
  -- Where it was when it last checked, so `status` can show progress rather than
  -- a bare "travelling" for the length of a long trip.
  startDistance = 0,
  holding = false,
  delivered = 0,
  configured = false,
  active = false,
  startedAt = 0,
}

function general.load()
  return config.load(general.PATH, DEFAULTS)
end

function general.save(job)
  config.save(general.PATH, job)
end

--- The chunk this post is in.
---
--- Derived rather than stored. Two numbers that must agree - a post and a chunk -
--- are two numbers that can disagree, and the one that matters is the post,
--- because that is where the turtle actually goes.
function general.chunk(job)
  return grid.of(job.postX, job.postZ)
end

--- Where the post is, in this turtle's own coordinate frame.
---
--- Returns nil and a reason without an origin, which is the honest answer: a
--- turtle that has never been told where it is cannot be told where to go. Every
--- shared-mine job already refuses to deploy for the same reason, so this is
--- consistent rather than new.
local function target(job)
  local relative, why = nav.worldToRelative(job.postX, job.postY, job.postZ)
  if relative == nil then
    return nil, why or "this turtle does not know where it is - run `commands/locate` first"
  end
  return relative
end

--- Is the turtle standing on its post?
---
--- Compared in world space rather than relative space, because the answer has to
--- mean the same thing to the turtle and to the base - and the base only ever
--- sees world coordinates.
function general.arrived(job)
  local here = nav.worldPosition()
  if here == nil then
    return false
  end
  return here.x == job.postX and here.z == job.postZ
end

--- Fuel to reach the post, plus the trip back.
---
--- The return leg is priced in even though a general is not expected to make it.
--- A recall must be obeyable: a general that flew out on exactly enough fuel to
--- arrive would be a turtle nobody can call home, holding a chunk forever, and
--- the operator's only remedy would be walking out to it.
function general.minimumFuel(job)
  local relative = target(job)
  if relative == nil then
    return nil
  end
  local x, y, z = nav.position()
  local out = math.abs(relative.x - x) + math.abs(relative.y - y) + math.abs(relative.z - z)
  return out * 2 + general.CRUISE * 2 + 8
end

--- Can this general set off?
function general.ready(job)
  if not nav.hasOrigin() then
    return false, "run `commands/locate` on this turtle before posting it", "setup"
  end
  if not job.configured then
    return false, "waiting for a chunk from the base", "idle"
  end

  local required = general.minimumFuel(job)
  if required and fuel.available() < required then
    return false, ("needs %d fuel to reach its post and return"):format(required), "fuel"
  end
  return true
end

function general.restart(job)
  job.holding = false
  job.active = true
  job.startedAt = os.epoch("utc")
  local relative = target(job)
  if relative then
    local x, y, z = nav.position()
    job.startDistance = math.abs(relative.x - x)
      + math.abs(relative.y - y)
      + math.abs(relative.z - z)
  end
  general.save(job)
  return job
end

function general.status(job)
  local cx, cz = general.chunk(job)
  local progress = job.holding and 1 or 0

  if not job.holding and job.startDistance and job.startDistance > 0 then
    local relative = target(job)
    if relative then
      local x, y, z = nav.position()
      local left = math.abs(relative.x - x) + math.abs(relative.y - y) + math.abs(relative.z - z)
      progress = math.max(0, math.min(1, 1 - left / job.startDistance))
    end
  end

  return {
    progress = progress,
    delivered = job.delivered,
    -- A holding general is not part-way through anything, so `standing` is what
    -- a parked one reports rather than the route progress that would otherwise
    -- freeze at whatever it was. `legacy/miner/context.lua` reads this.
    standing = job.holding and 1 or 0,
    settings = {
      postX = job.postX,
      postZ = job.postZ,
      postY = job.postY,
    },
    -- Shown on the Devices page beside the turtle, so "which chunk is this one
    -- holding" is answerable without opening anything.
    chunk = grid.key(cx, cz),
  }
end

function general.configure(job, values)
  local updates, why = settings.apply(general.settingFields, values)
  if updates == nil then
    return false, why
  end

  -- A general given a different chunk is no longer holding the one it was.
  -- Saying so before it moves is what stops the base counting a chunk as covered
  -- by a turtle that is in transit somewhere else.
  if settings.merge(job, updates) then
    job.holding = false
  end

  job.configured = true
  general.save(job)
  return true
end

function general.setup(ui)
  local job = general.load()
  ui.clear()
  print("Chunk loader\n")
  print("This turtle travels to a chunk and holds it loaded")
  print("so the miners working there keep running while")
  print("nobody is nearby.\n")
  print("The base normally assigns the chunk. These are")
  print("for posting one by hand.\n")

  job.postX = ui.askNumber("Post X", job.postX)
  job.postZ = ui.askNumber("Post Z", job.postZ)
  job.postY = ui.askNumber("Post Y", job.postY)
  job.configured = true
  nav.setHome()
  general.restart(job)
  return job
end

--- Travel to the post, then hold it.
---
--- Returns only when recalled. See the header: a general that returned would be
--- re-anchored by `Runner:start` on every cycle and would lose the route home its
--- fuel reserve is priced against.
function general.run(job, ctx)
  local relative, why = target(job)
  if relative == nil then
    return false, why, "setup"
  end

  if not general.arrived(job) then
    ctx.report("travelling", ("to chunk %s"):format(general.status(job).chunk))

    -- Over the ground, not through it. `climb` is what makes the route follow
    -- terrain instead of boring a tunnel through the first hill it meets.
    local reached, reachError = nav.goTo(relative.x, relative.y, relative.z, function()
      local abort = ctx.aborted()
      if abort then
        return false, abort, "recalled"
      end
      return true
    end, { climb = nav.CLIMB_LIMIT })

    if not reached then
      if reachError == nil or ctx.aborted() then
        return true, "recalled by base", "recalled"
      end
      return false, reachError, "error"
    end
  end

  job.holding = true
  general.save(job)

  local cx, cz = general.chunk(job)
  ctx.report("holding", ("chunk %d, %d"):format(cx, cz))

  -- The job, in its entirety. Standing in the chunk is what keeps it loaded, so
  -- there is nothing to call and nothing to do - only a reason to still be here
  -- next tick.
  while true do
    local abort = ctx.aborted()
    if abort then
      job.holding = false
      general.save(job)
      return true, abort, "recalled"
    end
    sleep(general.HOLD)
  end
end

return general
