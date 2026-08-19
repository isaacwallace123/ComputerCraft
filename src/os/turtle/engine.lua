--- The one place ICOS 2's turtle still reaches into ICOS 1.
---
--- `os/turtle/main.lua` has three services and two of them are empty seams:
--- `runJob` defaults to a function that does nothing and `runControls` to a
--- launcher. So an ICOS 2 turtle booted today is a turtle that heartbeats,
--- obeys recall, and never mines. This is what fills them.
---
--- ## Why not rewrite the runtime instead
---
--- `legacy/miner/runtime.lua` is 326 lines that decide when a turtle parks,
--- deploys, updates, changes job, and starts its next cycle - and every one of
--- those decisions is load-bearing on a machine that is underground with an open
--- shaft behind it. Rewriting it in the same change that gives ICOS 2 its first
--- working turtle would mean two untested halves in one hole.
---
--- The composition root already said this was the plan: *"the job service calls
--- it, `control.lua` writes the flags it already reads, and from the runtime
--- point of view nothing happened."* This is that sentence, as a file.
---
--- ## What ICOS 2 replaces already
---
--- ICOS 1's miner entrypoint ran **four** coroutines under `parallel.waitForAny`
--- - the job, a heartbeat, a command receiver, and the local controls - which is
--- the bug `os/turtle/main.lua` exists to fix, because `waitForAny` returns when
--- *any* of them finishes and a failed radio therefore stopped the mining.
---
--- Only two of the four are taken from here. The heartbeat and the command
--- receiver are ICOS 2's own, on ICOS 2's protocol, under desired state - so a
--- turtle running this engine is **not** an ICOS 1 device and is not seen as one
--- by `os/server/services/bridge.lua`. That distinction matters: `ctx:report`
--- draws to the local screen and sends nothing, which is the only reason mixing
--- the two halves does not put two heartbeats on two protocols.
---
--- ## Deleting this file
---
--- It is the turtle's whole remaining dependency on `legacy/`, deliberately in
--- one file so that "what is left to port" has an answer you can read. It goes
--- when a job runner exists that takes ports instead of globals; at that point
--- `legacy/miner/` and `legacy/apps/miner.lua` go with it.

local engine = {}

--- Build the ICOS 1 turtle context and the two loops that drive it.
---
--- Returns the options `os/turtle/main.lua` documents as its seams, so the
--- caller is a table lookup in `os/kernel/boot.lua` rather than a branch.
---
--- `require`d inside the function, not at the top of the file. Every module
--- below reads a CC global while loading - `turtle`, `peripheral`, `term` - so
--- requiring them at file scope would make this file unloadable in a spec, and
--- therefore make `os/kernel/boot.lua` unloadable, and therefore make the whole
--- boot path untestable in order to save one line.
function engine.new()
  local Context = require("legacy.miner.context")
  local runtime = require("legacy.miner.runtime")
  local catalogue = require("domain.turtle.jobs")

  -- Built from the catalogue rather than listed here, so adding a job is one
  -- entry in `domain/turtle/jobs.lua` and nothing else. ICOS 1 listed the five
  -- modules inline in its entrypoint, which is how the catalogue's paths came
  -- to be wrong for a whole restructure without anybody noticing: nothing
  -- resolved them.
  local jobs = {}
  for _, entry in ipairs(catalogue.list()) do
    jobs[entry.id] = require(entry.module)
  end

  local ctx = Context.new(jobs)

  return {
    -- The same tables `control.apply` writes and the runtime reads. Shared by
    -- reference on purpose: a copy would mean a recall that set a flag nothing
    -- was looking at.
    node = ctx.node,
    flags = ctx.control,

    snapshot = function()
      return ctx:snapshot()
    end,

    -- A `while true` loop, which is what a service is. It returns only by
    -- error, and the supervisor treats a service that returns as a fault - so
    -- the two agree about what "still working" means without either knowing
    -- about the other.
    runJob = function()
      return runtime.agent(ctx)
    end,

    -- ICOS 1's own controls, not the ICOS 2 launcher. `ctx:draw` owns this
    -- screen and repaints it from job progress; putting the client shell on top
    -- would give one terminal two things drawing to it, and the turtle's status
    -- would flicker against a page nobody asked for.
    runControls = function()
      return runtime.localControls(ctx)
    end,

    -- Exposed for the entrypoint's benefit only. Nothing in `os/` reads it.
    context = ctx,
  }
end

return engine
