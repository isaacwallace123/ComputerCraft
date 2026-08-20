--- What a turtle does when a job run ends, and which order it services orders in.
---
--- These are the two decisions inside `legacy/miner/runtime.lua` that are worth
--- testing, and until now neither could be: both live in the middle of a
--- `while true` that also draws a screen, writes a file, plays a sound and
--- sleeps. §14 puts the turtle runtime first in the retirement order because it
--- is the piece most likely to need a second attempt; this is the half of it
--- that can be got right before anything is rewritten.
---
--- Nothing here does anything. `after` returns what should happen and `pending`
--- returns what to service next, and the caller performs both - which is the
--- same shape every service on the server already has, and for the same reason:
--- anything worth testing that lives inside a loop is something that cannot be
--- tested.
---
--- ## The invariants these encode
---
--- **Recall outranks every other outcome.** It is a safety control. A job that
--- finished, failed, and was recalled in the same cycle parks as recalled, and
--- the flag is cleared by the caller so it cannot fire twice.
---
--- **A fuel stop is not a failure.** A turtle that came home because its return
--- reserve said so did exactly the right thing, and reporting it as an error
--- would train somebody to ignore errors - which is the same argument D025 makes
--- about the stall counter and the one the supervisor's backoff makes about
--- giving up loudly.
---
--- **A continuous job cycles; everything else parks.** That is the difference
--- between a quarry that keeps going after unloading and a job that is finished,
--- and it is a property of the job rather than of the turtle.
---
--- ## Why the park order is data
---
--- `update` before `assignment` before a job change before `deploy` is not
--- arbitrary. An update replaces the code that would carry out the other
--- orders, so it goes first or it goes stale. `deploy` is last because it is the
--- one that *ends* the parked state - servicing it before a pending job change
--- would deploy a turtle on the job it had before, which is precisely the
--- three-message race §5 collapses.

local lifecycle = {}

--- Orders that can be waiting on a parked turtle, most urgent first.
---
--- A list rather than a chain of `if`s so the order is a thing you can read, and
--- so a spec can assert it rather than re-deriving it from control flow.
lifecycle.PRIORITY = {
  "update",
  "assignment",
  "setJob",
  "settings",
  "configure",
  "changeJob",
  "deploy",
}

--- The reason a recalled turtle parks.
---
--- It mentions `where` because the common cause of a recall is that somebody is
--- about to move the turtle, and a turtle that is moved without re-declaring its
--- origin dead-reckons from the wrong place - which is a whole shift of mining
--- in the wrong sector before anybody notices.
lifecycle.RECALLED = "recalled - deploy again; run where first if moved"

--- What happens after `job.run` returns.
---
--- `result` is `{ ok, stopped, stopKind, recalled, continuous }`, which is the
--- job's three return values plus the two facts the turtle knows and the job
--- does not. Returns `{ action, reason, kind, tone }`:
---
---   action  "park" or "cycle"
---   reason  what to show and log; never nil for a park
---   kind    the park kind the dashboard groups by
---   tone    a sound to play, or nil for silence
---
--- `tone` is a name rather than a call, because a module that played a sound
--- would be a module that needs a speaker to be tested.
function lifecycle.after(result)
  result = result or {}

  -- First, and before `ok` is even looked at. A turtle recalled *while* its job
  -- was failing must park as recalled: the operator asked for it home, and
  -- reporting an error instead would leave a turtle that was told to come back
  -- looking like a turtle that broke.
  if result.recalled or result.stopKind == "recalled" then
    return { action = "park", reason = lifecycle.RECALLED, kind = "recalled" }
  end

  if not result.ok then
    return {
      action = "park",
      reason = "stopped: " .. tostring(result.stopped),
      kind = "error",
      tone = "error",
    }
  end

  if result.stopKind == "fuel" then
    return {
      action = "park",
      reason = result.stopped or "fuel reserve reached",
      kind = "fuel",
      tone = "ready",
    }
  end

  -- Only a continuous job cycles, and only on a cycle stop. A `cycle` from a
  -- one-shot job is a job that has finished a pass and has nothing more to do,
  -- so it parks like any other completion.
  if result.continuous and result.stopKind == "cycle" then
    return { action = "cycle" }
  end

  return {
    action = "park",
    reason = result.stopped or "job complete",
    kind = "complete",
    tone = "ready",
  }
end

--- Which pending order a parked turtle should service now, or nil for none.
---
--- Reads the same control flags `os/turtle/control.lua` writes and
--- `legacy/miner/runtime.lua` acts on, so the two agree about precedence
--- without either restating it.
function lifecycle.pending(flags)
  if type(flags) ~= "table" then
    return nil
  end
  for _, name in ipairs(lifecycle.PRIORITY) do
    if flags[name] then
      return name
    end
  end
  return nil
end

--- What a keypress means, given whether the turtle is parked.
---
--- Keys are **names**, not CC keycodes: `keys.d` is a number that only exists on
--- a machine with the CC globals loaded, and a rule about what `d` does is a
--- rule, not an I/O concern. The caller translates once.
---
--- The interesting half is what is *missing* from each state. A running turtle
--- has no deploy - it is already deployed, and offering one would either do
--- nothing or start a second job over the top of the first. A parked turtle has
--- no recall - it is already home. Neither is a guard bolted on afterwards;
--- they are simply not in the table, which is why they cannot be got wrong by
--- somebody adding a key later.
lifecycle.KEYS = {
  parked = {
    d = "deploy",
    enter = "deploy",
    c = "configure",
    j = "changeJob",
    q = "quit",
  },
  running = {
    r = "recall",
    q = "quit",
  },
}

--- Returns the flag a key raises, `"quit"`, or nil for a key that means nothing
--- in this state.
function lifecycle.keypress(name, parked)
  local table_ = parked and lifecycle.KEYS.parked or lifecycle.KEYS.running
  return table_[tostring(name or "")]
end

--- Can a deploy go ahead, given what the job says about itself?
---
--- `prepare` and `ready` are the job's own two checks and they are asked in that
--- order deliberately: `prepare` claims a sector and `ready` prices the route
--- home. Asking them the other way round would check the fuel for the old route
--- and then take a longer one, which is how a turtle leaves without its return
--- reserve.
---
--- Returns `true`, or `false` with the reason and the park kind to use.
function lifecycle.admit(prepare, ready)
  prepare = prepare or {}
  if not prepare.ok then
    return false, prepare.why or "not ready", prepare.kind or "fuel"
  end
  ready = ready or {}
  if not ready.ok then
    return false, ready.why or "not ready", ready.kind or "fuel"
  end
  return true
end

return lifecycle
