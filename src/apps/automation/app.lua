--- Automation: what the fleet is allowed to fix while nobody is watching.
---
--- `legacy/apps/automation.lua` was a seven-item menu that redrew itself after
--- every keypress. This is five toggles bound to the server's own policy, and
--- the difference is not cosmetic: the old one read the policy from a file *on
--- the base*, which meant it only worked on the base, and a Pocket controller
--- editing it was editing a copy that a subscription had to push back.
---
--- ## The page owns nothing
---
--- §4 again. The policy lives on the server, arrives on the mirror, and is
--- changed by asking. Closing this page changes nothing about what the fleet
--- does, which is the property D018 exists to protect and the reason a settings
--- editor is not allowed to be the thing that holds the setting.
---
--- ## One field per message
---
--- A toggle sends the switch it changed, not the whole policy. Sending all five
--- would mean two people on two screens overwriting each other's unrelated
--- changes - and neither would attribute it to the page they were looking at.
---
--- ## The dangerous one is last and looks it
---
--- Rolling updates are the only switch here that can turn a working fleet into a
--- broken one while nobody is watching, so it is the only one that is off by
--- default and the only one drawn in `warn`. Everything else is a re-attempt of
--- something that already failed for a reason that may have gone away by itself.

local policyRules = require("domain.fleet.policy")
local request = require("os.kernel.request")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

--- The switches, in the order they are shown.
---
--- Ordered by how much damage each can do, least first. Somebody scanning the
--- page top to bottom meets the safe recoveries before the one that installs
--- code, which is the order that makes the last row read as a warning rather
--- than as another checkbox.
app.SWITCHES = {
  {
    key = "enabled",
    label = "Auto-recovery",
    detail = "The master switch. Off means nothing below runs.",
  },
  {
    key = "resumeRefueled",
    label = "Resume when refuelled",
    detail = "A turtle that stopped for fuel and has some again.",
  },
  {
    key = "retryDepot",
    label = "Retry a full depot",
    detail = "Somebody may have emptied the chest since.",
  },
  {
    key = "retrySetup",
    label = "Recheck setup",
    detail = "A prerequisite that may since have been satisfied.",
  },
  {
    key = "updateParked",
    label = "Rolling update",
    detail = "Installs code unattended. One turtle at a time.",
    dangerous = true,
  },
}

--- Build the message that changes one switch.
---
--- Returned rather than sent, for the reason every service separates its
--- decision from its loop: a spec drives this with a table, and the one line
--- that touches a radio is in `mount`.
function app.intent(key, value)
  if policyRules.DEFAULTS[key] == nil then
    return nil
  end
  return { kind = "policy", set = { [key] = value == true } }
end

--- What the page says about the fleet as a whole.
function app.summary(policy)
  if policy == nil then
    return "waiting for the server", T.mutedFg
  end
  if not policy.enabled then
    return "off - nothing recovers itself", T.warn
  end

  local count = 0
  for _, switch in ipairs(app.SWITCHES) do
    if switch.key ~= "enabled" and policy[switch.key] then
      count = count + 1
    end
  end
  return ("%d recovery rule%s active"):format(count, count == 1 and "" or "s"), T.good
end

function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)

  local policy = scope:Computed(function(use)
    use(tick)
    return context.state and context.state.policy or nil
  end)

  local ask = request.of(context, options.protocol)

  local function send(key, value)
    local message = app.intent(key, value)
    if message then
      ask(message)
    end
    return message
  end

  local rows = {}
  for _, switch in ipairs(app.SWITCHES) do
    local on = scope:Computed(function(use)
      local current = use(policy)
      return current ~= nil and current[switch.key] == true
    end)

    rows[#rows + 1] = scope:Toggle({
      Label = switch.label,
      Value = on,
      -- Every switch below the master is meaningless while the master is off,
      -- and a page that let somebody flip a switch that does nothing is a page
      -- that has to be explained. Derived rather than stored, so there is no
      -- state that can disagree with the policy it is describing.
      Disabled = scope:Computed(function(use)
        local current = use(policy)
        if current == nil then
          return true
        end
        return switch.key ~= "enabled" and not current.enabled
      end),
      OnChange = options.readOnly and nil or function(value)
        send(switch.key, value)
      end,
    })

    rows[#rows + 1] = scope:Muted({
      Height = 1,
      Text = "  " .. switch.detail,
      Color = switch.dangerous and T.warn or nil,
    })
  end

  local status = scope:Computed(function(use)
    return (app.summary(use(policy)))
  end)

  return scope:Page({
    Title = "Automation",
    Status = status,
    Children = rows,
  })
end

return app
