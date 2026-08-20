--- The record a machine boots from, and the rules for writing one.
---
--- `os/kernel/roles.lua` reads `.node` and translates whatever it finds into one
--- of four operating systems. This is the other direction: what setup is allowed
--- to *write* there.
---
--- ## Why writing needs rules when reading already has them
---
--- `roles.roleOf` is deliberately forgiving - it maps every ICOS 1 role forward
--- and falls back to `client` for anything it cannot place, because a machine
--- with an unreadable role should end up as the thing that holds no authority
--- and moves nothing. That forgiveness is correct on the way in and dangerous on
--- the way out: it means setup could write **any** string and the machine would
--- still boot, silently, as a client. Somebody who chose Server and got a client
--- has no error to read and no reason to suspect one.
---
--- So writing is checked against the same table reading uses, and a role nothing
--- can boot is refused at the moment it is chosen rather than discovered as a
--- base station that never answers.
---
--- ## It is pure, and the caller persists
---
--- Same discipline as `domain/`: this decides what the record should contain and
--- hands it back. `commands/setup.lua` writes it. That is what lets the whole of
--- "what happens when somebody sets up a machine" be a spec, on a development
--- box with no CC anywhere.
---
--- ## Existing fields survive
---
--- Re-running setup to change a label must not throw away the job a turtle was
--- running or the auto-update preference somebody set. Every answer is optional
--- and anything not answered is left exactly as it was, which is also what makes
--- this safe to run on a machine that is already working.

local jobs = require("domain.turtle.jobs")
local roles = require("os.kernel.roles")

local node = {}

node.PATH = ".node"

--- A machine nobody has set up.
---
--- `role` is nil rather than a default, and that is the one field worth being
--- strict about: `startup.lua` uses its absence to decide that setup has never
--- run. A default here would make every fresh computer look configured.
function node.empty()
  return {
    role = nil,
    label = nil,
    job = nil,
    parked = false,
    autoUpdate = true,
  }
end

--- Roles a `.node` may be written with.
---
--- The four operating systems and nothing else. ICOS 1's names still *read*
--- correctly through `roles.roleOf` - that is §13's migration and it stays - but
--- nothing should be writing them any more, which is what makes the mapping
--- shrink to migration entries over time rather than growing.
function node.writable()
  return { roles.SERVER, roles.CLIENT, roles.TURTLE, roles.MOBILE }
end

function node.valid(role)
  for _, name in ipairs(node.writable()) do
    if name == role then
      return true
    end
  end
  return false
end

--- A name for a machine that has none.
---
--- The role plus the computer id, except for the two roles where there is only
--- ever one and a number would be noise. Somebody renames it or does not; what
--- matters is that a fleet of ten turtles does not arrive at the base as ten
--- machines called `turtle`.
function node.suggestLabel(role, id)
  if role == roles.SERVER then
    return "base"
  end
  if role == roles.MOBILE then
    return "handheld"
  end
  return ("%s-%s"):format(tostring(role), tostring(id or 0))
end

--- Fold setup's answers into an existing record.
---
--- Returns the new record, or nil and a sentence. Every field is optional and an
--- absent one is left alone, so this is equally the "first run" path and the
--- "change the label" path - which is what stops a second run wiping a turtle's
--- job.
function node.apply(existing, answers)
  answers = answers or {}
  local record = {}
  for key, value in pairs(node.empty()) do
    record[key] = value
  end
  for key, value in pairs(existing or {}) do
    record[key] = value
  end

  if answers.role ~= nil then
    if not node.valid(answers.role) then
      -- Refused here rather than at boot. `roles.roleOf` would quietly turn this
      -- into a client, and a machine somebody set up as a server that came up as
      -- a client is a fault with no error attached to it.
      return nil, "no operating system for role " .. tostring(answers.role)
    end
    record.role = answers.role
  end

  if answers.label ~= nil then
    local label = tostring(answers.label):gsub("^%s*(.-)%s*$", "%1")
    if label == "" then
      return nil, "a machine needs a name"
    end
    record.label = label
  end

  if answers.job ~= nil then
    -- Through the catalogue, so a job that no longer exists becomes the default
    -- rather than a turtle that will not start. `resolve` never returns nil for
    -- exactly this reason.
    local entry = jobs.resolve(answers.job)
    record.job = entry.id
  end

  if answers.autoUpdate ~= nil then
    record.autoUpdate = answers.autoUpdate == true
  end

  -- A machine being set up is not mid-job. Clearing this is what stops a turtle
  -- that was parked with "depot full" coming back up still parked for a reason
  -- that no longer applies to the job it has just been given.
  if answers.role ~= nil or answers.job ~= nil then
    record.parked = false
    record.parkKind = nil
    record.parkReason = nil
  end

  return record
end

--- What setup should offer this machine, and what to warn about each choice.
---
--- A thin pass-through to `roles.offered`, which already answers it. Here so that
--- setup has one place to ask rather than reaching into two modules, and so the
--- warning is fetched at the same time as the choice rather than being forgotten
--- by whoever writes the menu.
function node.choices(capabilities)
  local out = {}
  for index, entry in ipairs(roles.offered(capabilities)) do
    out[index] = {
      key = entry.key,
      label = entry.label,
      detail = entry.detail,
      warn = entry.warn and entry.warn(capabilities) or nil,
    }
  end
  return out
end

--- The jobs this machine could be given, for a turtle.
---
--- Empty for anything that is not one. A job is what a turtle does; a server has
--- services and a client has pages, and offering either of them a mining job
--- would be offering something nothing would ever read.
function node.jobs(role, capabilities)
  if role ~= roles.TURTLE then
    return {}
  end
  return jobs.available(capabilities)
end

return node
