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
--- ## The log *is* the history
---
--- There used to be two pages. Console kept its own list of the last forty
--- lines in memory and threw it away when the page closed; Logs read the
--- machine's log and had no prompt. So the answer to "what did I run, and what
--- did the base say about it" lived in two places, neither of which had both
--- halves, and closing the console destroyed the half you had just made.
---
--- Now a command writes to the log like anything else does, and this page is
--- the log with a prompt on the bottom of it. Three things fall out of that and
--- all three were asked for: console history survives a reboot, a command sits
--- in sequence with the service output it caused, and there is one page rather
--- than two.
---
--- It also means the console is readable on a monitor, where there is no
--- keyboard: `readOnly` drops the prompt, and what is left is exactly the Logs
--- page that used to be a separate file.
---
--- ## Everything it says is best-effort, and it says so
---
--- D004: a send that reports false is an ordinary outcome. The console reports
--- what it *asked for*, never what happened, because it cannot know - the
--- answer arrives later as a device converging on the Devices page. Saying
--- "recalled" would be the "sent" status §5 exists to abolish, so it says
--- "asked the base to recall 7".

local commands = require("apps.console.commands")
local logPort = require("ports.log")
local plan = require("domain.mine.plan")
local registry = require("domain.fleet.registry")
local request = require("os.kernel.request")
local view = require("apps.console.view")

local app = {}

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

--- What a typed line is prefixed with in the log.
---
--- So an echo is findable among service output, and so `history` can colour it
--- differently without the log port needing a fourth level for something only
--- one page produces.
app.ECHO = "> "

--- Write one of `execute`'s lines into the machine log.
---
--- `echo` is not a log level - the port has three and they mean severity. A
--- command somebody typed is information, so it goes in as `info` and is
--- recognised again on the way out by its prefix.
function app.record(port, level, text)
  if port == nil then
    return false
  end
  local write = port[level] or port.info
  if type(write) ~= "function" then
    return false
  end
  write(tostring(text))
  return true
end

--- The scrollback: the machine log, tagged so echoes can be drawn differently.
---
--- `filter` keeps only warnings and errors, which is what somebody opening this
--- after something went wrong wants, and is one keypress rather than a search
--- box nobody can type into.
function app.history(port, count, filter)
  local out = {}
  if port == nil then
    return out
  end

  for _, entry in ipairs(port.recent(count) or {}) do
    local level = logPort.level(entry.level)
    local text = tostring(entry.text or "")

    -- Recovered from the prefix rather than stored, because the log is also
    -- written by services that know nothing about this page.
    if level == "info" and text:sub(1, #app.ECHO) == app.ECHO then
      level = "echo"
    end

    if not filter or (level == "warn" or level == "error") then
      out[#out + 1] = { level = level, text = text, at = entry.at }
    end
  end

  return out
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
---
--- `readOnly` is what a monitor gets: the scrollback with no prompt, because
--- D020 says a surface nobody can type on must not be handed a control. That
--- one flag is the whole difference between this and the page that used to be
--- called Logs.
function app.mount(scope, context, options)
  options = options or {}
  local port = context.log
  local tick = options.tick or scope:Value(0)
  local input = scope:Value("")
  local filter = options.filter or scope:Value(false)
  local capacity = options.capacity or 10

  --- Everything in the log, newest last.
  ---
  --- Asked for more than fits so that filtering to warnings still fills the
  --- screen rather than showing two lines out of ten.
  local lines = scope:Computed(function(use)
    use(tick)
    return app.history(port, capacity * 4, use(filter))
  end)

  local status = scope:Computed(function(use)
    if port == nil then
      return "no log on this machine"
    end
    local count = #use(lines)
    if use(filter) then
      return ("%d warning%s and errors"):format(count, count == 1 and "" or "s")
    end
    return ("%d lines"):format(count)
  end)

  --- The rest of the word being typed, or nil.
  local suggestion = scope:Computed(function(use)
    return commands.complete(use(input))
  end)

  local function push(level, text)
    app.record(port, level == "echo" and "info" or level, text)
    -- Advanced by hand rather than waiting for the ticker, so the answer to a
    -- command appears when Enter is pressed instead of up to a second later.
    -- A console that lags behind the keyboard reads as a console that missed
    -- the command.
    tick:set(tick:get() + 1)
  end

  local function submit(text)
    input:set("")

    local intent, why = commands.parse(text)
    if intent == nil then
      -- An empty line is neither an intent nor an error. Telling somebody off
      -- for pressing enter is how a console becomes annoying to use.
      if why then
        push("echo", app.ECHO .. text)
        push("error", why)
      end
      return
    end

    push("echo", app.ECHO .. text)

    if intent.kind == "clear" then
      -- The log is the history now, and a page cannot truncate the machine's
      -- log without also deleting what the services wrote. Filtering is the
      -- honest version of what `clear` was for.
      push("info", "the console keeps the machine log now - use Warnings only to narrow it")
      return
    end

    for _, line in ipairs(app.execute(context, intent)) do
      push(line.level, line.text)
    end
  end

  local actions = nil
  if not options.readOnly then
    actions = {
      scope:Button({
        Text = "Warnings only",
        Variant = "ghost",
        OnClick = function()
          filter:set(not filter:get())
        end,
      }),
    }
  end

  return view.build(scope, {
    lines = lines,
    input = input,
    suggestion = suggestion,
    capacity = capacity,
    title = "Console",
    status = status,
    actions = actions,
    readOnly = options.readOnly,
    onChange = function(text)
      input:set(text)
    end,
    onComplete = function(text)
      input:set(text)
    end,
    onSubmit = submit,
  })
end

return app
