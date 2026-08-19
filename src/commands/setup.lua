--- Give this machine a role, a name, a position, and - if it has arms - a job.
---
--- The ICOS 2 replacement for `install.lua`, which writes ICOS 1 role names that
--- `os/kernel/roles.lua` then maps forward on every boot. §14 step 4: once
--- nothing writes the old names, that mapping keeps only its migration entries.
---
--- ## Why it is a script and not a page
---
--- Setup runs on a machine that has no role yet, which means no composition
--- root, no supervisor, and nothing to mount a page onto. It is also the one
--- thing that has to work when everything else is broken. So it is a plain
--- CraftOS program that prints and reads, exactly as `update.lua` is, and the
--- Setup *app* is an entry that runs this.
---
--- ## Every decision is somewhere else
---
--- What roles this machine may be is `roles.offered`; what a role warns about is
--- the role's own `warn`; which jobs it could run is `jobs.available`; what the
--- record should end up containing is `node.apply`. This file asks the
--- questions and writes the file, and holds no rule of its own - so the whole of
--- setup's behaviour is a spec, and what is left here is the part that needs a
--- keyboard.

package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("adapters.cc.config")
local locator = require("adapters.cc.locator")
local machine = require("adapters.cc.machine")
local node = require("os.kernel.node")

local ports = { locator = locator.new() }
local caps = machine.capabilities(ports)
local saved = config.load(node.PATH, node.empty())

local function heading(text)
  term.clear()
  term.setCursorPos(1, 1)
  print(text)
  print(("-"):rep(math.min(38, select(1, term.getSize()))))
  print("")
end

--- Ask for one of a list. Returns the index, or nil if cancelled.
local function choose(title, entries)
  while true do
    heading(title)
    for index, entry in ipairs(entries) do
      print(("%d  %s"):format(index, entry.label))
      if entry.detail then
        print("   " .. entry.detail)
      end
    end
    print("")
    write("Choice [1-" .. #entries .. ", or blank to cancel]: ")

    local answer = read()
    if answer == nil or answer:match("^%s*$") then
      return nil
    end
    local picked = tonumber(answer:match("%d+"))
    if picked and entries[picked] then
      return picked
    end
    printError("Enter a number from the list.")
    sleep(1)
  end
end

local function ask(prompt, suggestion)
  write(prompt)
  if suggestion then
    write(" [" .. tostring(suggestion) .. "]")
  end
  write(": ")
  local answer = read()
  if answer == nil or answer:match("^%s*$") then
    return suggestion
  end
  return answer
end

---------------------------------------------------------------------------
-- What this machine is
---------------------------------------------------------------------------

heading("ICOS setup")
for _, line in ipairs(machine.describe(caps)) do
  print(line)
end
print("")
print("Press enter to choose what this machine is for.")
read()

local choices = node.choices(caps)
if #choices == 0 then
  -- `roles.offered` never returns an empty list for any real machine - every
  -- form factor matches at least one entry - so this is a genuine surprise
  -- rather than an ordinary path, and saying so beats a menu with nothing in it.
  printError("No role fits this machine. Check that it is a computer, turtle or pocket.")
  return
end

local picked = choose("What is this machine for?", choices)
if picked == nil then
  print("Cancelled. Nothing was changed.")
  return
end

local role = choices[picked]

heading(role.label)
print(role.detail or "")
print("")

-- The caveat comes *after* the choice, deliberately. `roles.OFFERED` splits
-- `detail` from `warn` for this reason: a menu of caveats is a menu nobody
-- reads, and the thing somebody needs to know about the role they picked is
-- worth a line to itself.
if role.warn then
  printError("Note: " .. role.warn)
  print("")
end

local label = ask("Name this machine", saved.label or node.suggestLabel(role.key, caps.id))

---------------------------------------------------------------------------
-- What it should be doing
---------------------------------------------------------------------------

local job = nil
local available = node.jobs(role.key, caps)

if #available > 0 then
  local entries = {}
  for index, entry in ipairs(available) do
    entries[index] = { label = entry.label, detail = entry.summary }
  end

  local chosen = choose("Which job?", entries)
  job = chosen and available[chosen].id or nil
end

---------------------------------------------------------------------------
-- Where it is
---------------------------------------------------------------------------

heading("Position")

if caps.located then
  local existing = ports.locator.saved()
  print(("This machine is at %d, %d, %d."):format(existing.x, existing.y, existing.z))
  print("")
  print("Run `locate` again if you move it.")
  print("")
else
  -- Not optional for a server, and not optional for a turtle that will join the
  -- shared mine either. Rather than duplicate the prompts, setup says so and
  -- hands over - `locate` is the one place that writes `.location`, and two
  -- places that wrote it would be two formats waiting to disagree.
  print("This machine does not know where it is yet.")
  print("")
  if role.key == "server" then
    printError("A server hosts GPS and must know its own position")
    printError("before it can start.")
  else
    print("Shared-mine jobs need a world position before")
    print("they will deploy.")
  end
  print("")
  print("Run `locate` after this finishes.")
  print("")
end

---------------------------------------------------------------------------
-- Write it
---------------------------------------------------------------------------

local automatic = choose("Update automatically on every boot?", {
  { label = "Yes", detail = "Recommended - the fleet stays on one build" },
  { label = "No", detail = "Update by hand with `update`" },
})

local record, why = node.apply(saved, {
  role = role.key,
  label = label,
  job = job,
  autoUpdate = automatic ~= 2,
})

if record == nil then
  printError(tostring(why))
  return
end

config.save(node.PATH, record)
os.setComputerLabel(record.label)

heading("Ready")
print(("%s is set up as a %s."):format(record.label, record.role))
if record.job then
  print(("It will run the %s job."):format(record.job))
end
print("")
if not caps.located then
  print("Next:  locate")
end
print("Then:  reboot")
