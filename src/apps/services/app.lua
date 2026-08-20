--- Services: what this machine is running, and what has stopped.
---
--- The supervisor's own comments have referred to "the Services page" since it
--- was written, and this is it. It is the diagnostic surface for everything
--- else: when a turtle will not deploy, or a client shows nothing, or GPS is
--- down, this is the page that says which loop is failing and what it said.
---
--- ## It reads a supervisor, not a fleet
---
--- Every other app in ICOS 2 reads the mirror. This one reads
--- `context.supervisor`, which is *this machine's own*, and that difference is
--- deliberate: the moment somebody needs this page is the moment the radio might
--- be the thing that is broken. A services page that had to ask the server what
--- it was running would be useless in exactly the case it exists for.
---
--- ## Health is three states, and the middle one matters most
---
--- `running` is green and boring. `gave up` is red and obvious. **`waiting`** is
--- the interesting one: a service that is failing and backing off, which looks
--- like nothing on any other screen and is the state a machine spends its time
--- in while a person is walking over to look at it. So it gets its own tone and
--- the retry countdown is shown, because "retrying in 8s" and "retrying in 30s"
--- are different situations.
---
--- ## Critical is shown, not implied
---
--- A non-critical service that has given up leaves the machine healthy, and that
--- is correct - a client that cannot reach its server still draws. But somebody
--- reading a page with one red row and the word "healthy" underneath needs to be
--- told why those are both true, or they will conclude the page is lying.

local switches = require("os.kernel.switches")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

--- Services this page refuses to switch off.
---
--- Not the same list as `critical`. Critical means "the machine is not doing its
--- job without this" and is about health; these are services whose absence would
--- take away the means of turning them back on, which is about being able to
--- recover.
---
---   * `screen` and `desktop` draw this page. Switching one off from the page it
---     draws is a machine you have to reboot to get back, and somebody trying it
---     once would learn nothing except not to.
---   * `ticker` is what repaints. Without it the page freezes on the frame that
---     said "off", which looks exactly like a crash.
---
--- Everything else is fair game, including `discovery` - a base that has been
--- deliberately taken off the air is a thing somebody might genuinely want, and
--- the page still says so in red.
app.PROTECTED = {
  screen = true,
  desktop = true,
  ticker = true,
}

--- May this service be switched off from here?
function app.togglable(row)
  return not app.PROTECTED[row.id]
end

--- How a service's state reads to a person.
---
--- `waiting` becomes "retrying", because `waiting` is what the supervisor calls
--- it and "retrying in 8s" is what somebody needs to know. The internal word is
--- accurate and the displayed word is useful, and they are allowed to differ.
function app.status(row)
  -- Off comes before everything, because it is the only state that is somebody's
  -- decision rather than the machine's news about itself.
  if row.disabled then
    return "off"
  end
  if row.gaveUp then
    return "gave up"
  end
  if row.state == "running" then
    return "running"
  end
  if row.state == "waiting" then
    if row.retryIn then
      return ("retrying %ds"):format(math.ceil(row.retryIn))
    end
    return "retrying"
  end
  return row.state or "unknown"
end

--- The colour a row's status is drawn in.
---
--- A non-critical service that has given up is `warn`, not `bad`. The machine is
--- degraded rather than broken, and painting it the same red as a failed
--- critical service would train somebody to ignore both.
function app.tone(row)
  if row.disabled then
    -- Muted, not warn. A service that was turned off on purpose is not a
    -- problem, and colouring it like one would train somebody to ignore the
    -- colour that means there is one.
    return T.mutedFg
  end
  if row.gaveUp then
    return row.critical and T.destructive or T.warn
  end
  if row.state == "running" then
    return row.failures and row.failures > 0 and T.warn or T.good
  end
  return T.warn
end

--- The rows, worst first.
---
--- Same principle as Devices sorting by staleness: the healthy ones need no
--- attention, so they go at the bottom. A page listing seven services
--- alphabetically puts the broken one fourth, which is exactly where somebody
--- scanning from the top will not see it.
function app.rows(supervisor, now)
  local rows = supervisor:health(now)

  local function rank(row)
    -- Off sorts to the bottom with the healthy ones. It is not a fault, and a
    -- switched-off service at the top would push a real failure down the page.
    if row.disabled then
      return 5
    end
    if row.gaveUp then
      return row.critical and 0 or 1
    end
    if row.state ~= "running" then
      return 2
    end
    if (row.failures or 0) > 0 then
      return 3
    end
    return 4
  end

  table.sort(rows, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then
      return ra < rb
    end
    return tostring(a.id) < tostring(b.id)
  end)

  for _, row in ipairs(rows) do
    row.status = app.status(row)
    row.detail = row.lastError and tostring(row.lastError) or ""
    row.peak = app.peak(row.slowest)
  end
  return rows
end

--- The longest this service has held the machine in the last minute.
---
--- The number that answers "why is everything slow", and it was being recorded
--- and shown to nobody. CC gives all the computers in a world a shared budget -
--- `max_main_global_time`, ten milliseconds a tick by default, across however
--- many machines are running - so a service that takes twenty is not slightly
--- expensive, it is the whole world's tick.
---
--- The last minute rather than all time, and the difference matters. A service's
--- first resume runs it from the top - the first modem open, the first palette
--- upload - and an all-time peak showed `sync` at 147 ms forever: a true number
--- about a moment that will not happen again, sitting in the column somebody
--- reads to find out what is slow now.
---
--- Blank rather than zero when nothing has been measured. A service that has
--- never been resumed has no peak, and printing `0` would claim it is free.
function app.peak(slowest)
  local value = tonumber(slowest)
  if value == nil or value <= 0 then
    return ""
  end
  if value >= 100 then
    return ("%d"):format(value)
  end
  return ("%.1f"):format(value)
end

--- How alarming a peak is.
---
--- Twenty milliseconds is a whole server tick and five is what one computer is
--- allowed by default, so those are the two thresholds. They are properties of
--- Minecraft rather than of this fleet, which is why they are named here rather
--- than tuned.
function app.peakTone(row)
  local value = tonumber(row.slowest) or 0
  if value >= 20 then
    return T.destructive
  end
  if value >= 5 then
    return T.warn
  end
  return T.mutedFg
end

--- One line summarising the machine.
---
--- The word "healthy" alone is not enough on a page that may be showing a red
--- row, so an unhealthy machine says which service made it so, and a healthy one
--- with a degraded service says that too. A summary that only ever said
--- "healthy" would be a summary somebody stops reading.
function app.summary(supervisor, now)
  local healthy, why = supervisor:healthy()
  if not healthy then
    return "unhealthy - " .. tostring(why), T.destructive
  end

  local degraded = 0
  for _, row in ipairs(supervisor:health(now)) do
    if row.gaveUp or row.state ~= "running" then
      degraded = degraded + 1
    end
  end

  if degraded > 0 then
    return ("healthy, %d service%s degraded"):format(degraded, degraded == 1 and "" or "s"), T.warn
  end
  return "healthy", T.good
end

function app.columns()
  return {
    { Title = "Service", Grow = 1, Key = "id" },
    { Title = "State", Width = 12, Key = "status", Tone = app.tone },
    -- Restarts rather than failures. Failures resets to zero the moment a
    -- service comes back, so a service that has crashed forty times today and
    -- is up right now shows zero - which is true and useless. Restarts counts
    -- the times it actually had to be brought back.
    { Title = "Up", Width = 4, Key = "restarts", Align = "right" },

    -- The slowest single resume, in milliseconds. The supervisor has always
    -- recorded it and nothing has ever shown it, which meant "the machine feels
    -- slow" had no answer on the machine.
    { Title = "ms", Width = 5, Key = "peak", Align = "right", Tone = app.peakTone },
  }
end

--- Mount the page.
---
--- `context.supervisor` is this machine's own. `tick` is what makes the retry
--- countdowns move: without a dependency that changes, the list would recompute
--- only when a service changed state, and a countdown that only updated when
--- something happened would be a countdown that never reached zero on screen.
function app.mount(scope, context, options)
  options = options or {}
  local supervisor = context.supervisor
  local tick = options.tick or scope:Value(0)

  local rows = scope:Computed(function(use)
    use(tick)
    if supervisor == nil then
      return {}
    end
    return app.rows(supervisor, context.clock.now())
  end)

  local summary = scope:Computed(function(use)
    use(tick)
    if supervisor == nil then
      return "no supervisor on this machine"
    end
    return (app.summary(supervisor, context.clock.now()))
  end)

  local selected = options.selected or scope:Value(nil)

  --- The failing service's last error, in full.
  ---
  --- The table truncates to a column width, and the thing somebody needs is
  --- usually the end of the message - "no such file .quarry" tells you more than
  --- "no such fi". So the selected row's error gets a line of its own.
  local detail = scope:Computed(function(use)
    local id = use(selected)
    for _, row in ipairs(use(rows)) do
      if row.id == id then
        return row.detail ~= "" and row.detail or "no errors recorded"
      end
    end
    return ""
  end)

  --- The switch, and what it refuses to switch.
  ---
  --- One button rather than a toggle per row, because the table builds a fixed
  --- pool of row slots and a control inside one would have to move with the
  --- scroll. The button acts on the selection, which is the thing already on
  --- screen saying what it would act on.
  local actions = nil
  if not options.readOnly and supervisor then
    actions = {
      scope:Button({
        Text = scope:Computed(function(use)
          use(tick)
          local id = use(selected)
          return id and supervisor:disabled(id) and "Turn on" or "Turn off"
        end),
        Variant = scope:Computed(function(use)
          use(tick)
          local id = use(selected)
          return id and supervisor:disabled(id) and "primary" or "destructive"
        end),
        Disabled = scope:Computed(function(use)
          local id = use(selected)
          if id == nil then
            return true
          end
          for _, row in ipairs(use(rows)) do
            if row.id == id then
              return not app.togglable(row)
            end
          end
          return true
        end),
        OnClick = function()
          local id = selected:get()
          if id == nil then
            return
          end
          if supervisor:disabled(id) then
            supervisor:enable(id)
          else
            supervisor:disable(id)
          end

          -- Written down, or it lasts until the next reboot.
          --
          -- This page could switch a service off since it was written and
          -- nothing ever recorded it - which on a base station is a long time
          -- before anybody notices, so it looked like it worked. A machine's job
          -- is decided by which of its services run, and a choice that forgets
          -- itself on restart is not a choice.
          --
          -- Read back off the supervisor rather than tracked here, so the file
          -- can only ever describe a state the machine was actually in.
          switches.save(context, switches.current(supervisor))

          tick:set(tick:get() + 1)
        end,
      }),
    }
  end

  return scope:Page({
    Title = "Services",
    Status = summary,
    Children = {
      scope:Table({
        Columns = app.columns(),
        Rows = rows,
        Selected = selected,
        Capacity = options.capacity or 8,
        OnSelect = function(row)
          selected:set(row and row.id or nil)
        end,
      }),
      scope:Separator({}),
      scope:Muted({ Text = detail, Height = 1 }),
    },
    Actions = actions,
  })
end

return app
