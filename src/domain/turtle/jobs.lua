--- The job catalogue: what a turtle can be told to do, and what that needs.
---
--- ICOS 1 kept jobs as a table built at the entrypoint, keyed by name, whose
--- values were the modules themselves. That worked while every turtle mined, and
--- it has two problems the moment one does not.
---
--- **The base cannot see the list.** A console offering "which job?" had to
--- either hard-code the names or ask a turtle - and a turtle that is down a
--- shaft is a turtle that cannot answer. So the catalogue is data, it lives in
--- `domain/`, and both ends of the radio read the same file.
---
--- **Nothing declares what a job needs.** A farming turtle wants a hoe and a
--- water source; a quarry wants a pickaxe and a lot of fuel; a fuel hunt wants
--- neither. ICOS 1 discovered the mismatch when the turtle tried to dig with
--- nothing equipped, which is a failure that happens in a hole rather than at
--- setup - and D004 means it then parks and waits for a person who has to walk
--- there.
---
--- ## An entry is a description, not an implementation
---
--- `module` is a string, resolved by the turtle when it starts the job. The
--- catalogue never requires it, which is what lets a server - a computer with no
--- `turtle` global at all - list, validate and assign jobs it could not itself
--- run. A base that had to load `os/turtle/jobs/mining/quarry.lua` to know a quarry exists would
--- be a base that crashes on `turtle.dig` being nil.
---
--- ## Adding a job
---
--- One entry here and one module. Nothing else in the tree needs to know: setup
--- offers whatever this lists, the base assigns from the same list, and the
--- turtle resolves `module` at the moment it starts working.

local jobs = {}

--- What a job can require of the machine running it.
---
--- Deliberately a small closed set of *capabilities* rather than item names. "It
--- needs a pickaxe" is a Minecraft fact that changes with modpacks; "it needs to
--- be able to break blocks" is a fact about the job.
---
--- Two of these can be observed and two cannot, which is worth knowing before
--- reading `runnable` and expecting more of it than it gives.
---
--- `fuel` and `modem` a turtle can check: one is a number, the other either
--- answers or does not. `dig` and `place` it cannot - `turtle.dig` with no tool
--- and `turtle.dig` with nothing in front both return false, so telling them
--- apart means breaking a block to ask a question, and a capability check that
--- damages the world to run is worse than the problem it detects.
---
--- So those two are a declaration for the *person*: setup says "this job needs a
--- tool that breaks blocks" before they choose it, and the runtime finds out the
--- truth the first time it digs, parks, and reports why. The catalogue makes the
--- requirement visible ten seconds earlier, where it is cheap.
jobs.NEEDS = {
  dig = true, -- can break blocks; declared, not observable
  place = true, -- can place blocks; declared, not observable
  fuel = true, -- consumes fuel meaningfully, so an unfuelled start is a fault
  modem = true, -- coordinates with the base, rather than merely benefiting
}

--- The catalogue.
---
--- `default` marks what a turtle gets when its node names a job that no longer
--- exists - which happens on every downgrade and on the one rename that has
--- already occurred (`expedition` became `rare`). Exactly one entry may carry it.
jobs.CATALOGUE = {
  {
    id = "quarry",
    label = "Coordinated area quarry",
    module = "jobs.quarry",
    summary = "Clears an absolute area in disjoint cells assigned by the base.",
    needs = { "dig", "fuel", "modem" },
    default = true,
  },
  {
    id = "rare",
    label = "Rare ore prospecting",
    module = "jobs.rare",
    summary = "Seeks deep valuable veins and returns when the hold is full.",
    needs = { "dig", "fuel", "modem" },
  },
  {
    id = "fuel",
    label = "Coal and fuel hunting",
    module = "jobs.fuel_hunt",
    summary = "Targets coal veins and keeps the fuel aboard for future cycles.",
    -- No modem. A fuel hunt is the job a turtle does *because* something has
    -- gone wrong, and requiring the base for it would mean a fleet that cannot
    -- refuel itself once the base is unreachable.
    needs = { "dig", "fuel" },
  },
  {
    id = "hollow",
    label = "Hollow out a volume",
    module = "jobs.hollow",
    summary = "Empties a bounded space without prospecting.",
    needs = { "dig", "fuel" },
  },
  {
    id = "resources",
    label = "Bulk resource gathering",
    module = "jobs.resources",
    summary = "Collects a named block until the hold is full.",
    needs = { "dig", "fuel", "modem" },
  },
}

--- One job by id, or nil.
function jobs.get(id)
  for _, entry in ipairs(jobs.CATALOGUE) do
    if entry.id == id then
      return entry
    end
  end
  return nil
end

--- The job a turtle falls back to.
---
--- A function rather than a constant, so the catalogue stays the single source
--- and a mis-edit that removes every default is a nil somebody notices rather
--- than a stale string that still resolves.
function jobs.default()
  for _, entry in ipairs(jobs.CATALOGUE) do
    if entry.default then
      return entry
    end
  end
  return jobs.CATALOGUE[1]
end

--- Every job, in catalogue order.
---
--- Catalogue order rather than alphabetical, because the order in the file is a
--- deliberate statement about which job somebody setting up a new turtle most
--- likely wants, and sorting it would throw that away to gain nothing.
function jobs.list()
  local out = {}
  for index, entry in ipairs(jobs.CATALOGUE) do
    out[index] = entry
  end
  return out
end

--- Names ICOS 1 used that no longer exist.
---
--- Kept as data rather than as an `if` in the turtle's context, because the base
--- has to do the same translation when it reads an old device's snapshot - and
--- two copies of a rename table is how one of them gets forgotten.
jobs.RENAMED = {
  expedition = "rare",
}

--- Resolve whatever a node records into a job that exists.
---
--- Returns the entry and whether anything had to change, so a caller can persist
--- the correction once instead of re-deriving it on every boot. Never returns
--- nil: a turtle whose job cannot be resolved gets the default, because the
--- alternative is a turtle that will not start, and a turtle that will not start
--- is one somebody has to walk to.
function jobs.resolve(id)
  local entry = jobs.get(id)
  if entry then
    return entry, false
  end

  local renamed = jobs.RENAMED[id]
  if renamed then
    local target = jobs.get(renamed)
    if target then
      return target, true
    end
  end

  return jobs.default(), true
end

--- Can this machine run this job?
---
--- `capabilities` is a plain table of booleans - `{ dig = true, fuel = true }` -
--- built by the caller from whatever it actually has, so this stays testable and
--- stays out of `turtle`.
---
--- Returns false and the first thing missing, singular. A list of four
--- deficiencies is a list somebody skims; one sentence naming the first is one
--- they act on, and the second is checked again once the first is fixed.
function jobs.runnable(entry, capabilities)
  if type(entry) ~= "table" then
    return false, "no such job"
  end
  capabilities = capabilities or {}
  for _, need in ipairs(entry.needs or {}) do
    if not capabilities[need] then
      return false, jobs.explain(need)
    end
  end
  return true
end

--- What a missing capability means to somebody standing in front of a turtle.
---
--- Phrased as the thing to do rather than the thing that is absent. "needs a
--- tool that can break blocks" is actionable; "dig = false" is a debug print.
function jobs.explain(need)
  if need == "dig" then
    return "needs a tool equipped that can break blocks"
  elseif need == "place" then
    return "needs a free slot and a tool that can place blocks"
  elseif need == "fuel" then
    return "needs fuel before it can start"
  elseif need == "modem" then
    return "needs a wireless modem to coordinate with the base"
  end
  return "needs " .. tostring(need)
end

--- Every job this machine could run, given what it has.
---
--- What a setup menu offers. Showing the unrunnable ones greyed out was the
--- other option and is worse: somebody who cannot select a thing does not need
--- to know it exists, and a menu of five with three refusals reads as a broken
--- turtle rather than as a turtle with no pickaxe.
function jobs.available(capabilities)
  local out = {}
  for _, entry in ipairs(jobs.CATALOGUE) do
    if jobs.runnable(entry, capabilities) then
      out[#out + 1] = entry
    end
  end
  return out
end

return jobs
