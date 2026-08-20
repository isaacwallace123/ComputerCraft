--- Working out a mine from where the base is, so nobody has to type six numbers.
---
--- ## What this replaces
---
--- Six steppers on the Mine page, every one of which had to be right before a
--- single turtle could deploy, while the page's own status line said only "no
--- mine placed - the fleet cannot deploy". So the first thing anybody did with a
--- new base was tinker with numbers whose consequences are invisible until
--- turtles start walking - and the default centre was 0, 0, which is a real
--- place and almost certainly not theirs.
---
--- A base knows where it is. Everything here follows from that.
---
--- ## The centre is the base, and the distance is a keep-out
---
--- The obvious reading of "put the mine a hundred blocks away" is to move the
--- centre a hundred blocks in some direction. That is worse than it sounds: it
--- needs a direction nobody has given, it leaves half the shafts closer to the
--- base than the number promised, and every haul is then measured from a corner
--- rather than a middle.
---
--- `plan.DEFAULTS` already has the right mechanism and says so: ring r sits at
--- least r * cellSize blocks out, so a keep-out radius is just a minimum ring.
--- The worksite is therefore centred on the base - which is where everything
--- gets unloaded, and so the point that should be equidistant from the shafts -
--- and the hundred blocks becomes the first ring that may be opened.
---
--- What somebody asked for is what they get: no digging within a hundred blocks
--- of where they live. What they also get, without asking, is a mine whose
--- shafts are all roughly the same distance to haul from.
---
--- ## It refuses rather than guessing a position
---
--- A base that does not know where it is gets nil and a sentence. The
--- alternative is a worksite centred on 0, 0 - which is exactly the default this
--- exists to remove, arrived at by a different route and now wearing the
--- authority of having been calculated.

local plan = require("domain.mine.plan")

local suggest = {}

--- How far from the base digging starts, in blocks.
---
--- A hundred. Far enough that a quarry does not eat the room the base is in,
--- close enough that the commute is not the job. A starting point rather than a
--- rule: the setup flow offers it, and the Mine page can still set anything.
suggest.KEEP_OUT = 100

--- How many rings of sectors to open beyond the first.
---
--- Two, giving three workable rings. Ring r holds 8r sectors, so rings 3, 4 and
--- 5 is ninety-six shafts - more than a fleet works through in a session, and
--- far less than the eight the plan permits. Every ring added is ground a turtle
--- might be sent to cross.
suggest.RINGS = 2

--- The first ring that keeps digging at least `blocks` from the centre.
---
--- Rounded up, always. Rounding down would put the innermost shafts inside the
--- radius somebody asked to keep clear, which is the one direction this must not
--- err in: the number exists to protect what is already built.
function suggest.ringFor(blocks, cellSize)
  local distance = math.max(0, tonumber(blocks) or 0)
  local size = math.max(1, tonumber(cellSize) or plan.DEFAULTS.cellSize)
  return math.max(1, math.ceil(distance / size))
end

--- How far from the centre a plan actually starts and stops digging.
---
--- The answer to "did it do what I asked", in the units the question was asked
--- in. Shown back on the setup page, because `minRing = 3` is not something
--- anybody can check against the world.
function suggest.reach(p)
  local settings = plan.normalise(p)
  return settings.minRing * settings.cellSize, settings.maxRing * settings.cellSize
end

--- Propose a worksite around a base.
---
--- Returns a plan, or nil and a sentence. `base` is a world position - the depot
--- if one has been declared, otherwise wherever the server itself is.
---
--- Everything it returns can be edited afterwards on the Mine page. This is a
--- starting point that is right, not a decision taken away.
function suggest.from(base, options)
  options = options or {}

  if type(base) ~= "table" or tonumber(base.x) == nil or tonumber(base.z) == nil then
    return nil, "the base does not know where it is - no GPS, and no depot set"
  end

  local cellSize = tonumber(options.cellSize) or plan.DEFAULTS.cellSize
  local keepOut = tonumber(options.keepOut) or suggest.KEEP_OUT
  local minRing = suggest.ringFor(keepOut, cellSize)

  return plan.normalise({
    configured = true,
    centreX = math.floor(base.x),
    centreZ = math.floor(base.z),

    -- The base's own Y. Shaft heads start at the surface, and the surface the
    -- base is standing on is the only one this machine can observe.
    surfaceY = math.floor(tonumber(base.y) or plan.DEFAULTS.surfaceY),

    cellSize = cellSize,
    minRing = minRing,
    maxRing = minRing + math.max(0, tonumber(options.rings) or suggest.RINGS),
  })
end

return suggest
