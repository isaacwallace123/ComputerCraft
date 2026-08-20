--- What this turtle is doing. Nothing you can change from here.
---
--- ## Why there are no controls
---
--- There were: a deploy button, a recall button, a settings editor and a job
--- picker, all writing the same control flags an order from the base writes. It
--- worked, and it was the wrong idea.
---
--- **A fleet has one place decisions are made, and it is the server.** A turtle
--- that could be given a different target depth by somebody standing in front of
--- it is a turtle whose settings no longer match the fleet's - and the base has
--- no way to know, because a local edit is not a message. Two sources of truth
--- for the same number, and the one that loses is the one nobody is looking at.
---
--- It also could not fit. The settings editor put a stepper on a 39x13 screen
--- under four status rows and two progress bars, and what came out was a row
--- half off the bottom edge with buttons that could not be reached. That is the
--- symptom; the cause is that this page was trying to be two pages.
---
--- ## So it is a display
---
--- Everything on it answers "what is this machine doing right now", which is the
--- only question worth asking of a screen you have walked to. Orders come from
--- the Devices page; settings come from the Devices page; the job comes from
--- setup. If the base is unreachable, `icos status` and the commands are still
--- there - a person at a keyboard is not the same as a control surface.
---
--- ## It fits, deliberately
---
--- A turtle terminal is 39 wide and 13 tall, and that is the *only* size this
--- page is ever drawn at. So it is laid out for it: nine rows of content, a
--- label column of eight, and no bar that needs a legend. Anything that has to
--- be truncated to fit was not worth a row.

local format = require("ui.format")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

--- The label column, wide enough for the longest word and no wider.
app.LABEL = 8

--- Everything the page shows, derived from one heartbeat snapshot.
---
--- Takes the snapshot rather than the context, so the page and the base read the
--- same fields through the same function - and so every rule below is testable
--- with a table literal and no turtle.
---
--- Every field is optional. A turtle that has just started, and one on an older
--- build, both report less than a working one, and a page that indexed a missing
--- field would fail on the two machines somebody is most likely to be looking at.
function app.status(snapshot)
  snapshot = type(snapshot) == "table" and snapshot or {}

  local parked = snapshot.parked == true
  local fuel = tonumber(snapshot.fuel) or 0
  local unlimited = fuel < 0

  -- A parked turtle reports **why**, not what it was doing.
  --
  -- The same rule the Devices page follows. "mining" on a machine standing at
  -- its chest is a claim the screen cannot support, and it is exactly the claim
  -- that makes somebody walk away from a turtle that needed them.
  local phase = snapshot.phase or "idle"
  if parked then
    phase = snapshot.parkKind and ("parked: " .. snapshot.parkKind) or "parked"
  end

  -- Fuel is measured against a different number depending on what the turtle is
  -- doing, because it is a different question.
  --
  -- Parked: "can it finish the job it is about to start", so the denominator is
  -- what the job needs. Working: "can it get back", so the denominator is the
  -- distance home. A single measure against tank capacity would answer neither -
  -- a turtle with 40k fuel and a 90k round trip is not two-thirds full, it is
  -- short, and a capacity bar would show it comfortable.
  -- An empty tank is never full, whatever the denominator says.
  --
  -- This defaulted the fraction to 1 and only lowered it when a denominator was
  -- available - so a `general` turtle, whose job declares no fuel requirement,
  -- drew a full green bar on zero fuel. The default was "assume fine", which is
  -- the wrong direction for the one indicator somebody checks before sending a
  -- machine away from home.
  --
  -- `nil` now means "cannot tell", and the page draws that as an empty track
  -- rather than a reassuring one. Unknown and fine are different answers.
  local fraction = nil
  if unlimited then
    fraction = 1
  elseif fuel <= 0 then
    fraction = 0
  else
    local needed = parked and tonumber(snapshot.fuelRequired) or tonumber(snapshot.distanceHome)
    if needed and needed > 0 then
      fraction = math.max(0, math.min(1, fuel / needed))
    end
  end

  return {
    label = snapshot.label or "turtle",
    job = snapshot.job or "none",
    parked = parked,
    phase = phase,
    detail = snapshot.parkReason or snapshot.detail or "",
    x = snapshot.x or 0,
    y = snapshot.y or 0,
    z = snapshot.z or 0,
    world = snapshot.world,
    distanceHome = tonumber(snapshot.distanceHome) or 0,
    fuel = fuel,
    unlimited = unlimited,
    fuelFraction = fraction,
    progress = math.max(0, math.min(1, tonumber(snapshot.progress) or 0)),
    located = snapshot.located == true,
    sector = snapshot.sector,
  }
end

--- Is this turtle short of fuel in a way somebody can still act on?
---
--- Only while parked. A working turtle that is low is past the point of acting -
--- it is somewhere in the world and the reserve it kept is what brings it home,
--- so flagging it would be raising an alarm about a decision already taken. The
--- moment to notice is before it leaves.
function app.short(status)
  if status.unlimited or not status.parked then
    return false
  end
  -- Unknown counts as short. A turtle whose job cannot say what it needs, with
  -- an empty tank, is not a turtle to reassure somebody about.
  return status.fuelFraction == nil or status.fuelFraction < 1
end

--- The colour the phase is drawn in.
function app.tone(status)
  if not status.parked then
    return T.good
  end
  local reason = tostring(status.detail):lower()
  if reason:find("fuel") or reason:find("depot") or reason:find("cannot") then
    return T.warn
  end
  return T.accent
end

local function field(scope, label, value, tone)
  return scope:Row({
    Height = 1,
    Children = {
      scope:Muted({ Text = label, Width = app.LABEL }),
      scope:Text({ Text = value, Grow = 1, Color = tone }),
    },
  })
end

function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)

  local status = scope:Computed(function(use)
    use(tick)
    return app.status(context.snapshot and context.snapshot() or {})
  end)

  local children = {
    field(
      scope,
      "job",
      scope:Computed(function(use)
        return use(status).job
      end)
    ),

    field(
      scope,
      "phase",
      scope:Computed(function(use)
        return use(status).phase
      end),
      scope:Computed(function(use)
        return app.tone(use(status))
      end)
    ),

    scope:Muted({
      Height = 1,
      Text = scope:Computed(function(use)
        return format.ellipsis(use(status).detail, 37)
      end),
    }),

    scope:Spacer({ Height = 1 }),

    field(
      scope,
      "at",
      scope:Computed(function(use)
        local current = use(status)
        if current.world then
          return ("%d, %d, %d"):format(current.world.x, current.world.y, current.world.z)
        end
        return ("%d, %d, %d  (local)"):format(current.x, current.y, current.z)
      end)
    ),

    field(
      scope,
      "home",
      scope:Computed(function(use)
        return ("%d blocks"):format(use(status).distanceHome)
      end)
    ),

    field(
      scope,
      "sector",
      scope:Computed(function(use)
        local sector = use(status).sector
        return sector and tostring(sector) or "none"
      end)
    ),

    scope:Spacer({ Height = 1 }),

    -- Two bars, each with its number beside it. A bar with no number is a
    -- shape, and "is that enough fuel" is a question about a quantity.
    scope:Row({
      Height = 1,
      Children = {
        scope:Muted({ Text = "fuel", Width = app.LABEL }),
        scope:Meter({
          Grow = 1,
          Value = scope:Computed(function(use)
            return use(status).fuelFraction or 0
          end),
          Tint = scope:Computed(function(use)
            return app.short(use(status)) and T.warn or T.good
          end),
        }),
        scope:Text({
          Width = 7,
          TextAlign = "right",
          Text = scope:Computed(function(use)
            local current = use(status)
            return current.unlimited and "unlim" or format.count(current.fuel)
          end),
        }),
      },
    }),

    scope:Row({
      Height = 1,
      Children = {
        scope:Muted({ Text = "done", Width = app.LABEL }),
        scope:Meter({
          Grow = 1,
          Value = scope:Computed(function(use)
            return use(status).progress
          end),
          Tint = T.accent,
        }),
        scope:Text({
          Width = 7,
          TextAlign = "right",
          Text = scope:Computed(function(use)
            return ("%d%%"):format(math.floor(use(status).progress * 100 + 0.5))
          end),
        }),
      },
    }),
  }

  return scope:Page({
    Title = scope:Computed(function(use)
      return use(status).label
    end),
    Status = scope:Computed(function(use)
      local current = use(status)
      if not current.located then
        -- The one thing on this page somebody has to act on, so it takes the
        -- status line rather than a row that could scroll away.
        return "no position - run locate"
      end
      return current.job
    end),
    Children = children,
  })
end

return app
