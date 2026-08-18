--- What a service is, and the test for whether something is one.
---
--- §4 of docs/icos-2.md draws three categories with one test each, and the
--- reason it bothers is `where.lua` sitting in `apps/` next to Fleet:
---
---   * **App** — has a page you look at and leave open. `apps/<id>/`.
---   * **Command** — runs once, prints, exits. No page, no taskbar. `commands/`.
---   * **Service** — never has a page, runs for the life of the machine.
---     `os/<name>/services/`.
---
--- ## The rule that matters
---
--- **Services own state, apps read it.** No app performs coordination and no
--- service draws. This is D018 generalised: closing the Fleet app used to
--- disable sector leasing, because coordination was living inside a page. An app
--- that is closed, crashed, or was never opened must change nothing about what
--- the machine is doing.
---
--- The manifest is what makes that checkable rather than aspirational. A service
--- declares the ports it needs, and the supervisor refuses to start one whose
--- ports are absent instead of letting it fail somewhere inside its own loop on
--- a machine with no screen.

local service = {}

--- Validate a service definition, returning it unchanged.
---
--- Called at registration rather than at first use, for the same reason
--- `ports/contract.lua` checks an adapter at construction: a service that is
--- missing its `run` should fail where somebody wrote it, not four minutes into
--- a fleet's morning.
function service.check(definition)
  if type(definition) ~= "table" then
    error("service: expected a table, got " .. type(definition), 2)
  end
  if type(definition.id) ~= "string" or definition.id == "" then
    error("service: needs a string id", 2)
  end
  if type(definition.run) ~= "function" then
    error("service " .. definition.id .. ": needs a run function", 2)
  end
  if definition.requires ~= nil and type(definition.requires) ~= "table" then
    error("service " .. definition.id .. ": requires must be a list of port names", 2)
  end
  return definition
end

--- Declare a service.
---
---     return service.define({
---       id = "reconcile",
---       requires = { "transport", "storage", "clock" },
---       critical = true,
---       run = function(ctx) ... end,
---     })
---
--- `critical` means the machine is not doing its job without this. It is not a
--- synonym for important: GPS is critical on a server because an outage there
--- breaks navigation for the whole fleet, while the auto-recovery policy is not,
--- because a fleet with no policy still mines. The distinction decides whether a
--- service giving up makes the whole machine report unhealthy.
function service.define(definition)
  return service.check(definition)
end

return service
