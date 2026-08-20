--- Console, wired: a typed line becomes a message, and the answer comes back.
---
--- `commands.lua` decides what a line means and this decides what to do about
--- it. The split is the same one every app here makes, and it is the reason the
--- parsing has tests: `execute` takes a context and an intent and returns lines
--- to show, so a spec drives every command with a table and no screen.
---
--- ## It asks; it does not do
---
--- `recall 7` does not send "recall" to device 7. It asks the server to *want*
--- device 7 recalled, exactly as the Devices page's button does, and
--- `reconcile` carries it. A console that sent orders directly would be a
--- second control path with different semantics from the buttons - one that
--- retries and one that does not - which is precisely the confusion §5 removes.
---
--- Placing the mine is the same shape: a `mine` message answered by `leases`,
--- which crosses the bridge unaltered and so works against an ICOS 1 base too.
---
--- ## Everything it says is best-effort, and it says so
---
--- D004: a send that reports false is an ordinary outcome. The console reports
--- what it *asked for*, never what happened, because it cannot know - the
--- answer arrives later as a device converging on the Devices page. Saying
--- "recalled" would be the "sent" status §5 exists to abolish, so it says
--- "asked the base to recall 7".

local commands = require("apps.console.commands")
local plan = require("domain.mine.plan")
local registry = require("domain.fleet.registry")
local request = require("os.kernel.request")
local view = require("apps.console.view")

local app = {}

--- The manifest.
---
--- `requiresInput` is true, and it is the only app so far for which that is
--- structurally true rather than a preference: a console with no keyboard is a
--- log with a decoration. D020's deny-by-default filtering keeps it off a
--- monitor without anybody having to remember to.
app.manifest = {
  id = "console",
  name = "Console",
  roles = { "client", "server" },
  surfaces = { "desktop" },
  requiresInput = true,
}

--- How many lines of history to keep.
---
--- More than fits, so that a command whose answer is several lines does not
--- push its own echo off the screen before it can be read.
app.HISTORY = 40

--- Add a line, trimming the oldest.
function app.say(lines, level, text)
  lines[#lines + 1] = { level = level, text = tostring(text) }
  while #lines > app.HISTORY do
    table.remove(lines, 1)
  end
  return lines
end

--- Carry out one intent. Returns the lines to add.
---
--- Pure with respect to the screen: it reads state and sends messages, and says
--- what it did. Everything it can get wrong is therefore a spec.
function app.execute(context, intent)
  local out = {}
  local function say(level, text)
    app.say(out, level, text)
  end

  local function send(message)
    return request.of(context)(message) and true or false
  end

  if intent.kind == "help" then
    for _, line in ipairs(commands.help()) do
      say("info", line)
    end
    return out
  end

  if intent.kind == "devices" then
    local now = context.clock.now()
    local rows = registry.list(context.state.fleet, now, registry.byStaleness)
    if #rows == 0 then
      say("warn", "nothing has reported to this base yet")
      return out
    end
    for _, row in ipairs(rows) do
      say(
        row.health == "offline" and "warn" or "info",
        ("%-4s %-12s %-8s %s"):format(
          tostring(row.id),
          tostring((row.snap and row.snap.label) or "?"),
          row.health,
          tostring((row.snap and row.snap.phase) or "unknown")
        )
      )
    end
    return out
  end

  if intent.kind == "mine.show" then
    local mine = context.state.mine
    if not (mine and mine.plan and mine.plan.configured) then
      say("warn", "no mine yet - place one with `mine at <x> <z> <y>`")
      return out
    end
    say(
      "info",
      ("mine centred on %d, %d with the surface at %d"):format(
        mine.plan.centreX,
        mine.plan.centreZ,
        mine.plan.surfaceY
      )
    )
    say("info", ("%d sectors in the plan"):format(plan.capacity(mine.plan)))
    return out
  end

  if intent.kind == "mine.place" then
    if
      not send({
        kind = "mine",
        body = {
          action = "configure",
          centreX = intent.centreX,
          centreZ = intent.centreZ,
          surfaceY = intent.surfaceY,
        },
      })
    then
      say("error", "no radio - this machine cannot reach the base")
      return out
    end
    say(
      "info",
      ("asked the base to centre the mine on %d, %d at Y %d"):format(
        intent.centreX,
        intent.centreZ,
        intent.surfaceY
      )
    )
    -- Warned before it happens rather than reported after, because the answer
    -- arrives on the radio and may not arrive at all. Somebody about to throw
    -- away a day of tunnels should be told at the moment they ask.
    say("warn", "if that moves the grid, every recorded sector frontier is cleared")
    return out
  end

  if intent.kind == "want" or intent.kind == "want.all" then
    local mode = intent.kind == "want" and intent.mode or intent.mode

    local targets = {}
    if intent.kind == "want" then
      if registry.get(context.state.fleet, intent.id) == nil then
        say("warn", ("no device %d has reported to this base"):format(intent.id))
        return out
      end
      targets[1] = intent.id
    else
      for _, record in ipairs(registry.records(context.state.fleet)) do
        targets[#targets + 1] = record.id
      end
      if #targets == 0 then
        say("warn", "nothing has reported to this base yet")
        return out
      end
    end

    for _, id in ipairs(targets) do
      send({ kind = "want", id = id, mode = mode })
    end

    -- What was asked for, never what happened. The console cannot know whether
    -- a turtle heard; that answer arrives later as a device converging.
    say(
      "info",
      ("asked the base to %s %s"):format(
        mode,
        #targets == 1 and tostring(targets[1]) or (#targets .. " devices")
      )
    )
    return out
  end

  return out
end

--- Mount the page.
function app.mount(scope, context, options)
  options = options or {}
  local lines = scope:Value({})
  local input = scope:Value("")

  local function push(level, text)
    local next_ = {}
    for _, line in ipairs(lines:get()) do
      next_[#next_ + 1] = line
    end
    app.say(next_, level, text)
    lines:set(next_)
  end

  push("info", "ICOS 2 console - type help")

  local function submit(text)
    input:set("")

    local intent, why = commands.parse(text)
    if intent == nil then
      -- An empty line is neither an intent nor an error. Telling somebody off
      -- for pressing enter is how a console becomes annoying to use.
      if why then
        push("echo", "> " .. text)
        push("error", why)
      end
      return
    end

    push("echo", "> " .. text)

    if intent.kind == "clear" then
      lines:set({})
      return
    end

    for _, line in ipairs(app.execute(context, intent)) do
      push(line.level, line.text)
    end
  end

  return view.build(scope, {
    lines = lines,
    input = input,
    capacity = options.capacity or 10,
    title = "Console",
    onChange = function(text)
      input:set(text)
    end,
    onSubmit = submit,
  })
end

return app
