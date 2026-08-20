--- Which services this machine has been told to leave off, across reboots.
---
--- ## The half that was missing
---
--- `supervisor:disable` has existed since the Services page was written, and
--- nothing wrote it down. Switching a service off lasted until the next
--- reboot - which on a base station is a long time and on a turtle is an
--- afternoon, so it looked like it worked and quietly did not.
---
--- That matters more than tidiness now. A machine's job is decided by which of
--- its services are running: a GPS host is a client with the fleet mirror and
--- the desktop switched off, and a chunk loader is a turtle that does almost
--- nothing. Those are configurations rather than roles, and a configuration that
--- forgets itself on restart is not one.
---
--- ## It cannot switch off something it does not know
---
--- Only ids the supervisor actually has are applied, so a file naming a service
--- that was renamed or removed is ignored rather than being an error. The file
--- is written by a person pressing a button on one build and read by whatever
--- build is running later; refusing to boot over a stale name would make an
--- update a thing that can strand a machine.
---
--- ## Nothing critical, ever
---
--- A critical service is one the machine is not doing its job without - the
--- radio on a server, the job runner on a turtle. Letting a saved file switch
--- one off would turn a mis-click a month ago into a base station that boots
--- healthy and answers nobody, with the reason in a file nobody thinks to read.
--- The Services page can still disable one for as long as the machine is up; it
--- just does not come back that way.

local switches = {}

--- Where the choice is kept.
---
--- A dotfile, like everything else this system persists - which is what keeps it
--- out of the build, out of `git status`, and out of the updater's reach when it
--- deletes files the new build does not have.
switches.PATH = ".services"

--- Read the set of ids to leave off.
---
--- Every failure is an empty set. A machine that refused to boot because its
--- service file was unreadable would be a machine that cannot be used to fix its
--- service file.
function switches.load(context)
  if context == nil or context.storage == nil or context.serialise == nil then
    return {}
  end
  local text = context.storage.read(switches.PATH)
  if text == nil then
    return {}
  end

  local ok, saved = pcall(context.serialise.decode, text)
  if not ok or type(saved) ~= "table" or type(saved.disabled) ~= "table" then
    return {}
  end

  local out = {}
  for id, off in pairs(saved.disabled) do
    if type(id) == "string" and off == true then
      out[id] = true
    end
  end
  return out
end

--- Write it.
function switches.save(context, disabled)
  if context == nil or context.storage == nil or context.serialise == nil then
    return false
  end
  local clean = {}
  for id, off in pairs(disabled or {}) do
    if type(id) == "string" and off == true then
      clean[id] = true
    end
  end
  return context.storage.write(switches.PATH, context.serialise.encode({ disabled = clean }))
      and true
    or false
end

--- What the supervisor currently has switched off.
---
--- Read back off the supervisor rather than tracked alongside it, so the file
--- can only ever describe a state the machine was actually in.
function switches.current(supervisor)
  local out = {}
  if supervisor == nil then
    return out
  end
  for _, row in ipairs(supervisor:health()) do
    if row.disabled then
      out[row.id] = true
    end
  end
  return out
end

--- Apply a saved set to a supervisor that has been built and not yet started.
---
--- Returns how many were switched off, and the ids it refused - which the caller
--- may report or ignore. Refusing quietly would be the wrong shape: "your GPS
--- host is still running the fleet mirror" is worth a line, and there is nowhere
--- else it could come from.
function switches.apply(supervisor, disabled)
  local applied, refused = 0, {}
  if supervisor == nil then
    return applied, refused
  end

  local critical = {}
  for _, row in ipairs(supervisor:health()) do
    if row.critical then
      critical[row.id] = true
    end
  end

  for id in pairs(disabled or {}) do
    if critical[id] then
      refused[#refused + 1] = id
    elseif supervisor:disable(id) then
      applied = applied + 1
    end
  end

  table.sort(refused)
  return applied, refused
end

return switches
