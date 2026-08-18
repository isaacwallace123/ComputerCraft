--- Turning an intent into control flags, and refusing to when it makes no sense.
---
--- `agent.receive` decides *what* a turtle has been asked to be. This decides
--- what that means for a turtle that is currently doing something else. The two
--- are separate because the first is a fact about the message and the second is
--- a fact about the machine, and mixing them is how "recall" came to mean four
--- different things depending on which branch it fell into.
---
--- ## The flags belong to ICOS 1 and that is on purpose
---
--- `miner/runtime.lua` reads `ctx.control` and it is the code that actually
--- drives a turtle down a shaft. It is proven, the fleet is running it, and
--- rewriting it in the same change that rewrites how orders arrive would mean a
--- fleet in a hole with two untested halves. So this writes the flags the
--- existing runtime already reads, and the runtime does not know anything
--- changed.
---
--- ## Every rule here is "is this turtle parked?"
---
--- Which is the same question ICOS 1 asked, kept because it is right: a running
--- turtle is somewhere in the world with an open shaft behind it, and changing
--- its job mid-descent means abandoning the hole. Recall first, then change what
--- it is for.
---
--- The difference is what happens when the answer is no. ICOS 1 replied "recall
--- this turtle first" and dropped the order, so an operator who set a job on a
--- running turtle got a message and nothing else. Under desired state the goal
--- stays on the server, the turtle keeps reporting that it has not applied it,
--- and the Devices page shows it as pending - so the order is not lost, it is
--- waiting. Nothing here needs to do anything for that to be true, which is the
--- point of §5.

local control = {}

--- Apply an intent, returning what changed and why.
---
--- Returns `{ applied = boolean, reason = string }`. `applied = false` is not a
--- failure: it is a turtle saying "not yet", and the server's job is to keep
--- asking rather than to give up. The reason is for the local screen and the
--- log, not for the server - the server already knows, because the turtle keeps
--- reporting a generation it has not caught up to.
function control.apply(node, flags, intent)
  if type(intent) ~= "table" or intent.mode == nil then
    return { applied = false, reason = "nothing to do" }
  end

  local parked = node.parked == true

  if intent.mode == "recall" then
    if parked then
      -- Already where it was asked to be. Idempotence is what lets the server
      -- re-send an order it is not sure arrived, and it only works if arriving
      -- twice is free.
      return { applied = true, reason = "already parked" }
    end
    flags.recall = true
    return { applied = true, reason = "returning home" }
  end

  if intent.mode == "update" then
    if flags.update then
      return { applied = true, reason = "update already queued" }
    end
    flags.update = { sender = intent.sender }
    if parked then
      return { applied = true, reason = "updating" }
    end
    -- An update means replacing the code that is currently driving the turtle.
    -- Doing that mid-shaft is how a turtle ends up halfway through a descent
    -- running half of one version, so it comes home first and the flag waits.
    flags.recall = true
    return { applied = true, reason = "returning home to update" }
  end

  if intent.mode == "deploy" then
    -- A job or settings change is a different order from "start working", and
    -- only the first needs the turtle parked. Checked before the plain deploy
    -- so that an order carrying both is not silently reduced to one.
    if intent.job ~= nil or intent.settings ~= nil then
      if not parked then
        return { applied = false, reason = "recall this turtle before changing its job" }
      end
      flags.assignment = {
        name = intent.job,
        settings = intent.settings,
        sender = intent.sender,
      }
      return { applied = true, reason = "job assigned" }
    end

    if not parked then
      return { applied = true, reason = "already working" }
    end
    flags.deploy = true
    return { applied = true, reason = "deploying" }
  end

  -- `park` and `recall` do the same thing to a turtle and are still two modes,
  -- because they mean different things to the fleet: recall is "come back, I
  -- want you", park is "stay where you are, do not take new work". A turtle has
  -- only one way to express either, so both raise the same flag - and a device
  -- with a dock or a charge pad would tell them apart.
  if intent.mode == "park" then
    if parked then
      return { applied = true, reason = "already parked" }
    end
    flags.recall = true
    return { applied = true, reason = "returning home" }
  end

  -- `stop` is the one mode that is not "be in this state" - it is "stop being
  -- anything". It raises no flag, because a stopped turtle is not a turtle
  -- running the turtle program with a flag set; the composition root ends the
  -- supervisor and the program exits. Reported applied, because it is: the
  -- turtle is about to stop reporting at all.
  if intent.mode == "stop" then
    return { applied = true, reason = "stopping", halt = true }
  end

  return { applied = false, reason = "unknown mode " .. tostring(intent.mode) }
end

return control
