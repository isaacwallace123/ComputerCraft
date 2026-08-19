--- Applying a job's settings, once, instead of three times.
---
--- Every job already declares `settingFields` - label, key, step, min, max - and
--- that declaration is a complete description of a form. It was being used three
--- ways and written out four times:
---
---   * `configure` walked it to validate a remote settings change, in three
---     near-identical fifteen-line loops that differed only in what they reset
---     afterwards
---   * `setup(ui)` **ignored it** and hand-wrote the same fields in the same
---     order as a sequence of prompts
---   * the Devices page rendered it as rows
---
--- The third one was right. This is the first two, collapsed into the thing they
--- were both re-deriving.
---
--- ## Why that matters beyond the line count
---
--- `setup(ui)` is the reason the mining jobs take a UI object at all, and it is
--- therefore the reason `os/turtle/engine.lua` still reaches into ICOS 1 for a
--- shell. A form driven by the declaration needs no prompts, so the jobs stop
--- depending on a screen entirely - which is what §14 step 1 was blocked on.
---
--- It also removes a whole class of drift. A prompt list and a validator that
--- describe the same fields separately can disagree, and did: `quarry` validated
--- `workerIndex` and `workerCount` that no prompt ever asked for, and `hollow`
--- prompted for `distance` before `targetY` while its field list said the
--- reverse. Neither was a bug yet. Both were a bug waiting for somebody to add a
--- field to one list.
---
--- ## What stays in the job
---
--- Only the rules that are genuinely about *that* job: quarry's corners must not
--- cross and its worker index must fit inside its worker count; prospecting
--- forgets a pending vein when the target depth moves; hollow restarts its cell
--- walk. Those are cross-field or after-effects, they are all different, and
--- pretending they were the same would be the wrong kind of sharing.
---
--- Pure, like everything else in `domain/`. No file, no screen, no clock.

local settings = {}

--- Read one field's value out of a table of proposed values.
---
--- Returns the integer, or nil and a sentence naming the field. Every value here
--- is an integer: these are block coordinates and counts, and a fractional
--- `minX` is a typo rather than a request.
function settings.value(field, given)
  local value = tonumber(given)
  if value == nil then
    return nil, tostring(field.key) .. " must be a number"
  end
  value = math.floor(value)
  if field.min and value < field.min then
    return nil, ("%s must be %d..%d"):format(field.key, field.min, field.max)
  end
  if field.max and value > field.max then
    return nil, ("%s must be %d..%d"):format(field.key, field.min, field.max)
  end
  return value
end

--- Validate a whole settings change against a field list.
---
--- Returns a table of the updates that passed, or nil and the first refusal.
--- **First**, singular, and not a list: a page that reported four problems at
--- once is a page somebody skims, and the second one is checked again as soon as
--- the first is fixed.
---
--- A key nobody declared is ignored rather than refused. Settings arrive over a
--- radio from a base that may be running a different build (§13's rolling
--- update), and refusing an unknown field would make a newer base unable to
--- configure an older turtle at all.
function settings.apply(fields, given)
  if type(given) ~= "table" then
    return nil, "settings must be a table"
  end

  local updates = {}
  for _, field in ipairs(fields or {}) do
    if given[field.key] ~= nil then
      local value, why = settings.value(field, given[field.key])
      if value == nil then
        return nil, why
      end
      updates[field.key] = value
    end
  end
  return updates
end

--- Write updates onto a job, reporting whether anything actually moved.
---
--- The `changed` answer is what every caller does something with - resetting a
--- cell walk, forgetting a pending vein - and computing it inside the write is
--- what stops a job resetting its progress because somebody re-sent the settings
--- it already had.
function settings.merge(job, updates)
  local changed = false
  for key, value in pairs(updates or {}) do
    if job[key] ~= value then
      changed = true
    end
    job[key] = value
  end
  return changed
end

--- Did this particular field move?
---
--- For the after-effects that care about one field rather than any field.
--- Prospecting forgets a pending vein when the target depth changes and must not
--- forget it when the vein budget changes, because that vein is a real hole with
--- real ore in it that the turtle has promised to come back to.
function settings.moved(job, updates, key)
  return updates[key] ~= nil and job[key] ~= updates[key]
end

--- The rows a form draws.
---
--- The declaration turned into something renderable, so a page never walks
--- `settingFields` itself and cannot disagree with the validator about what a
--- field is called or what it may be.
function settings.rows(fields, job)
  local rows = {}
  for index, field in ipairs(fields or {}) do
    rows[index] = {
      key = field.key,
      label = field.label or field.key,
      value = tonumber((job or {})[field.key]) or field.min or 0,
      min = field.min,
      max = field.max,
      step = field.step or 1,
    }
  end
  return rows
end

--- One press of a `+` or `-`, clamped.
---
--- `step` is the field's own, because the useful increment differs by an order of
--- magnitude between them: a quarry corner moves in eights and a target Y moves
--- in ones. Clamping here rather than at the call site means a page cannot
--- produce a value its own validator would refuse - the button simply stops.
function settings.nudge(field, current, direction)
  local step = field.step or 1
  local value = math.floor(tonumber(current) or field.min or 0)
  value = value + step * (direction or 0)
  if field.min and value < field.min then
    value = field.min
  end
  if field.max and value > field.max then
    value = field.max
  end
  return value
end

--- Every field in a list, by key.
---
--- So a page holding a key can find the field that describes it without carrying
--- the list around beside it.
function settings.field(fields, key)
  for _, field in ipairs(fields or {}) do
    if field.key == key then
      return field
    end
  end
  return nil
end

return settings
