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

local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

app.manifest = {
  id = "services",
  name = "Services",

  -- Every role, including turtle. A turtle's launcher is the one screen a
  -- person is standing in front of when its job has stopped, and "job: gave up -
  -- bedrock" is the answer they came for.
  roles = { "client", "mobile", "turtle", "server" },
  surfaces = { "desktop", "monitor", "handheld", "launcher" },
  requiresInput = false,
}

--- How a service's state reads to a person.
---
--- `waiting` becomes "retrying", because `waiting` is what the supervisor calls
--- it and "retrying in 8s" is what somebody needs to know. The internal word is
--- accurate and the displayed word is useful, and they are allowed to differ.
function app.status(row)
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
  end
  return rows
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
  })
end

return app
