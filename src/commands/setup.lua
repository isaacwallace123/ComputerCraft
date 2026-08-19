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
--- thing that has to work when everything else is broken.
---
--- That is why it cannot use `ui/`. It is *not* why it used to look like a
--- different program: it printed lines and read strings, and the first thing
--- anybody ever sees of this system was the plainest screen in it.
---
--- `os/kernel/prompt.lua` fixes that without crossing the line. It is the
--- buffer - the one part of the renderer with no dependencies of its own - plus
--- a highlighted row and an event loop. Arrows, numbers, a mouse, and a
--- selection you can see. No components, no reactive graph, nothing that can
--- fail on a machine whose files were replaced ten seconds ago.
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
local console = require("os.kernel.console")
local machine = require("adapters.cc.machine")
local prompt = require("os.kernel.prompt")
local node = require("os.kernel.node")

local ports = { locator = locator.new() }
local caps = machine.capabilities(ports)
local saved = config.load(node.PATH, node.empty())

local screen = console.new(require("adapters.cc.screen").new(term))
local T = console.TOKENS

--- How many questions there are, so each screen can say where it is.
---
--- A person part-way through setup wants to know whether this is nearly over,
--- and "step 2 of 5" answers that in four characters. Counted rather than
--- hard-coded per screen, so adding a question does not leave five screens
--- claiming there are four.
local STEPS = 5
local step = 0

local function stepped()
  step = step + 1
  return ("step %d of %d"):format(step, STEPS)
end

local function choose(title, entries, options)
  options = options or {}
  options.title = title
  options.step = options.step or stepped()
  return prompt.choose(screen, entries, options)
end

---------------------------------------------------------------------------
-- What this machine is
---------------------------------------------------------------------------

screen:clear()
screen:header("ICOS setup", "new machine")

-- What it found, before what it is for. Somebody setting up a machine that has
-- no modem needs to see that here rather than discover it two screens later
-- when the role they wanted is not offered.
local row = 3
for _, line in ipairs(machine.describe(caps)) do
  screen:line(row, line, T.mutedFg)
  row = row + 1
end

local _, screenHeight = screen:size()
screen:line(row + 1, "Press any key to choose what this machine is for.", T.foreground)
screen:line(screenHeight, " Q at any point cancels and changes nothing", T.mutedFg)
screen:present()
os.pullEvent("key")

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
  prompt.tell(screen, "Cancelled", { "Nothing was changed." }, T.mutedFg)
  return
end

local role = choices[picked]

-- The caveat comes *after* the choice, deliberately. `roles.OFFERED` splits
-- `detail` from `warn` for this reason: a menu of caveats is a menu nobody
-- reads, and the thing somebody needs to know about the role they picked is
-- worth a line to itself.
local label = prompt.text(screen, "Name this machine", {
  title = role.label,
  step = stepped(),
  note = role.warn and ("Note: " .. role.warn) or role.detail,
  default = saved.label or node.suggestLabel(role.key, caps.id),
})

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
else
  -- No job to ask about, but the count still has to add up or the next screen
  -- claims to be step 3 of 5 with two left.
  stepped()
end

---------------------------------------------------------------------------
-- Where it is
---------------------------------------------------------------------------

-- Not optional for a server, and not optional for a turtle that will join the
-- shared mine either. Rather than duplicate the prompts, setup says so and hands
-- over - `commands/locate` is the one place that writes `.location`, and two
-- places that wrote it would be two formats waiting to disagree.
if caps.located then
  local existing = ports.locator.saved()
  prompt.tell(screen, "Position", {
    ("This machine is at %d, %d, %d."):format(existing.x, existing.y, existing.z),
    "",
    "Run `locate` again if you move it.",
  }, T.good, stepped())
else
  prompt.tell(screen, "Position", {
    "This machine does not know where it is yet.",
    "",
    role.key == "server" and "A server hosts GPS and must know its own"
      or "Shared-mine jobs need a world position before",
    role.key == "server" and "position before it can start." or "they will deploy.",
    "",
    "Run `locate` after this finishes.",
  }, T.warn, stepped())
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
  prompt.tell(screen, "Setup failed", { tostring(why) }, T.destructive)
  return
end

config.save(node.PATH, record)
os.setComputerLabel(record.label)

local lines = {
  ("%s is set up as a %s."):format(record.label, record.role),
}
if record.job then
  lines[#lines + 1] = ("It will run the %s job."):format(record.job)
end
lines[#lines + 1] = ""
if not caps.located then
  lines[#lines + 1] = "Next:  locate"
end
lines[#lines + 1] = "Then:  reboot"

prompt.tell(screen, "Ready", lines, T.good, "done")

-- Leave the terminal usable. The buffer owns the screen while setup is running
-- and a shell prompt drawn on top of the last frame is unreadable.
term.clear()
term.setCursorPos(1, 1)
print(record.label .. " is ready. Reboot to start it.")
