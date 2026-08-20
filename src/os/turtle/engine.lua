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
--- receiver are ICOS 2's own, on ICOS 2's protocol, under desired state.
---
--- ## It no longer reaches into `legacy/`
---
--- It did, and that was the whole point of the file: one place holding the
--- turtle's remaining dependency on ICOS 1, so "what is left to port" had an
--- answer somebody could read. The answer was `legacy/miner/context.lua` and
--- `legacy/miner/runtime.lua` - the state and the loop.
---
--- Both now have ICOS 2 versions. `os/turtle/runner.lua` is the loop, with its
--- decisions in `domain/turtle/lifecycle.lua`; `os/turtle/context.lua` is the
--- state, with its job selection in `domain/turtle/jobs.lua`. So this file
--- assembles ICOS 2 parts and `legacy/miner/` has nothing left pointing at it.
---
--- The jobs themselves still reach `turtle` directly through
--- `os/turtle/device/`. That is the port debt recorded in `src/README.md` and it
--- is a separate project; it is not a dependency on ICOS 1.

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
function engine.new(options)
  options = options or {}

  local config = require("adapters.cc.config")
  local context = require("os.turtle.context")
  local logfile = require("adapters.cc.logfile")
  local nav = require("os.turtle.device.nav")
  local runner = require("os.turtle.runner")
  local sound = require("adapters.cc.sound")

  local nodePath = options.nodePath or ".node"
  local node = options.node or config.load(nodePath, { parked = true })
  local flags = options.flags or {}

  local function saveNode(record)
    config.save(nodePath, record)
  end

  local ctx = context.new({
    node = node,
    flags = flags,
    saveNode = saveNode,
  })

  -- Every effect the loop needs, named rather than reached for. This is the
  -- list that used to be `ctx` methods on a god object, and writing it out is
  -- what makes the loop drivable by a spec with a table of counters.
  -- Declared before it is built, so the handlers below can close over it. They
  -- are passed the runner as an argument too, and using that instead would mean
  -- a parameter named the same as the local it always equals - which reads like
  -- two things and is one.
  local drive
  drive = runner.new({
    node = node,
    flags = flags,
    job = ctx.job,
    module = ctx.module,
    effects = {
      saveNode = saveNode,
      report = function(phase, detail)
        ctx:report(phase, detail)
      end,
      log = function(message)
        logfile.info(message)
      end,
      tone = function(name)
        sound.play(name)
      end,
      setHome = function()
        nav.setHome()
      end,
      idle = function()
        sleep(1)
      end,
    },

    -- Without these, `runner.wait` drops the order and logs that it did. That
    -- is the correct behaviour for an order nobody can service - the
    -- alternative is servicing it forever at full speed, because nothing clears
    -- it - but every order below *can* be serviced, and leaving them out would
    -- have meant a job assignment from the Devices page vanishing into a log
    -- line nobody reads.
    --
    -- Each one clears its own flag first. A handler that failed halfway with the
    -- flag still raised would be re-entered on the next step, forever, on a
    -- turtle that is parked and looks idle.
    handlers = {
      assignment = function()
        local request = flags.assignment
        flags.assignment = nil
        if type(request) ~= "table" then
          return false
        end

        ctx:selectJob(request.name)
        drive.job = ctx.job
        drive.module = ctx.module

        if type(request.settings) == "table" and ctx.module.configure then
          local ok, why = ctx.module.configure(ctx.job, request.settings)
          if not ok then
            drive:park("assignment refused: " .. tostring(why), "setup")
            return true
          end
        end

        -- An assignment is a job *and* a deployment - §5's point about the
        -- three-message set-job/configure/deploy dance being one goal. Starting
        -- here rather than raising `deploy` means it happens in this step
        -- instead of the next one, so a turtle does not sit parked for a second
        -- with a job it has already accepted.
        return drive:start("assigned " .. tostring(ctx.entry.id))
      end,

      setJob = function()
        local request = flags.setJob
        flags.setJob = nil
        if type(request) ~= "table" then
          return false
        end

        local entry = ctx:selectJob(request.name)
        drive.job = ctx.job
        drive.module = ctx.module
        return drive:park("job changed to " .. entry.id, "idle")
      end,

      settings = function()
        local request = flags.settings
        flags.settings = nil
        if type(request) ~= "table" or type(request.values) ~= "table" then
          return false
        end
        if not ctx.module.configure then
          return drive:park("this job cannot be configured remotely", "idle")
        end

        local ok, why = ctx.module.configure(ctx.job, request.values)
        return drive:park(ok and "settings saved" or tostring(why), ok and "idle" or "setup")
      end,

      update = function()
        flags.update = nil
        drive:park("installing ICOS update", "updating")

        -- `shell.run`, because the updater replaces the files this program is
        -- running from and has to survive doing so. It reboots on success, so
        -- anything after this line only runs when the update failed.
        local ran = shell and shell.run("update.lua", "--automatic", "--reboot")
        local result = config.load(".update-result", { message = "update stopped" })
        return drive:park(ran and result.message or "updater crashed", "error")
      end,
    },
  })

  return {
    -- The same tables `control.apply` writes and the runtime reads. Shared by
    -- reference on purpose: a copy would mean a recall that set a flag nothing
    -- was looking at.
    node = node,
    flags = flags,

    snapshot = function()
      return ctx:snapshot()
    end,

    -- A `while true` loop, which is what a service is. It returns only by
    -- error, and the supervisor treats a service that returns as a fault - so
    -- the two agree about what "still working" means without either knowing
    -- about the other.
    runJob = function()
      return drive:run()
    end,

    -- The ICOS 2 launcher now, because nothing else draws this screen any more.
    -- `legacy/miner/context.lua` owned the terminal and repainted it from job
    -- progress, which is why the client shell could not be put on top of it -
    -- two things drawing to one terminal made the status flicker against a page
    -- nobody asked for. `os/turtle/context.lua` stores the status and draws
    -- nothing, so the shell is free to.
    --
    -- Nil rather than a function: `os/turtle/main.lua` already defaults this to
    -- the launcher, and a wrapper that called it would be a second place the
    -- surface and capacity had to agree.
    runControls = nil,

    -- The navigator this turtle drives on, so `os/turtle/main.lua` can hand it
    -- to the locate service without requiring a module that reads `turtle` and
    -- `fs` the moment it loads.
    nav = nav,

    -- Exposed for the entrypoint's benefit only. Nothing in `os/` reads it.
    context = ctx,
  }
end

return engine
