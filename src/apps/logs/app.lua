--- Logs: what happened while you were asleep.
---
--- The other half of the Services page. Services says *which* loop is failing;
--- this says what it has been saying, and in what order relative to everything
--- else - which is usually the actual diagnosis. "GPS gave up" and "GPS gave up
--- four seconds after the modem was removed" are different problems.
---
--- ## Newest last, which is the opposite of what a dashboard usually does
---
--- Every other list in ICOS puts the interesting thing first: Devices sorts by
--- staleness, Services by failure. This one does not, and the exception is
--- deliberate. A log is a *sequence*, and reading a sequence backwards means
--- reading every consequence before its cause. The interesting line is still
--- easy to find, because it is the one at the bottom next to the cursor.
---
--- ## It reads the tail, not the file
---
--- `log.recent` is the in-memory ring buffer. A page that re-read four hundred
--- lines off disk on every frame would cost a disk read per keypress on a
--- machine that is also reconciling ten turtles - and a machine whose disk is
--- full would have no log on screen, which is precisely when somebody is looking
--- at one. `edit .log` is what you open for the older half, and `logrotate` is
--- what makes sure it is still there.

local logPort = require("ports.log")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

--- The colour a line is drawn in.
---
--- Only two are coloured. A log where every line is a colour is a log with no
--- colour, and `info` is the overwhelming majority - so it stays foreground and
--- the two that mean something stand out by being the only ones that do not.
function app.tone(level)
  if level == "error" then
    return T.destructive
  end
  if level == "warn" then
    return T.warn
  end
  return T.foreground
end

--- The level a line is at, from whatever the port returned.
---
--- Through `logPort.level` rather than compared here, because comparing here is
--- how this went wrong: the CC adapter returned "WARN" and this file checked for
--- "warn", so the warnings-only filter showed an empty screen while warnings
--- were arriving. One function owns the vocabulary and everything else asks it.
function app.level(entry)
  return logPort.level(entry and entry.level)
end

--- The lines to draw, oldest first.
---
--- `filter` keeps only warnings and errors, which is the one thing somebody
--- coming to this page usually wants and is a single keypress rather than a
--- search box nobody can type into on a Pocket Computer.
function app.lines(port, count, filter)
  local out = {}
  for _, entry in ipairs(port.recent(count) or {}) do
    local level = app.level(entry)
    if not filter or level ~= "info" then
      out[#out + 1] = {
        text = entry.text or "",
        level = level,
        at = entry.at,
      }
    end
  end
  return out
end

--- Mount the page.
---
--- `tick` is what makes new lines appear. A log that only recomputed when
--- somebody pressed a key would be a log that showed nothing arriving, which on
--- the one screen whose job is showing things arriving is the whole failure.
function app.mount(scope, context, options)
  options = options or {}
  local port = context.log
  local tick = options.tick or scope:Value(0)
  local filter = options.filter or scope:Value(false)
  local capacity = options.capacity or 10

  local lines = scope:Computed(function(use)
    use(tick)
    if port == nil then
      return {}
    end
    -- Asked for more than fit, so filtering to warnings and errors still fills
    -- the screen rather than showing two lines out of ten.
    return app.lines(port, capacity * 4, use(filter))
  end)

  local status = scope:Computed(function(use)
    if port == nil then
      return "no log on this machine"
    end
    local count = #use(lines)
    if use(filter) then
      return ("%d warning%s and errors"):format(count, count == 1 and "" or "s")
    end
    return ("%d recent lines"):format(count)
  end)

  --- The visible window: the last `capacity` lines, so the newest is always on
  --- screen without anybody scrolling to it.
  local visible = scope:Computed(function(use)
    local all = use(lines)
    local out = {}
    local first = math.max(1, #all - capacity + 1)
    for index = first, #all do
      out[#out + 1] = all[index]
    end
    return out
  end)

  local rows = {}
  for slot = 1, capacity do
    rows[slot] = scope:Text({
      Height = 1,
      Text = scope:Computed(function(use)
        local entry = use(visible)[slot]
        return entry and entry.text or ""
      end),
      Color = scope:Computed(function(use)
        local entry = use(visible)[slot]
        return app.tone(entry and entry.level)
      end),
    })
  end

  -- Built before the page rather than inline. `readOnly and nil or {...}` reads
  -- like a guard and is not one: `and` yields nil and `nil or {...}` is the
  -- table, so the actions were passed on every surface including a monitor
  -- nobody can press. D020 calls that boundary a safety property.
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

  return scope:Page({
    Title = "Logs",
    Status = status,
    Children = rows,
    Actions = actions,
  })
end

return app
