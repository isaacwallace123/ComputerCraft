--- What this machine is, and what is attached to it.
---
--- `os/kernel/roles.lua` has answered "can this machine be a server" since it
--- was written, and **nothing has ever produced the table it asks that of**.
--- `roles.check` and `roles.plan` both take a `capabilities`, and every caller
--- so far has been a spec passing a literal. This is the missing half.
---
--- ## One place asks the globals
---
--- Every other module asks this rather than testing for `turtle` or calling
--- `peripheral.find` itself, so "does this machine support X" is answered once.
--- That is the same reason `legacy/device.lua` exists, and this is its ICOS 2
--- replacement - narrower, because ICOS 2 asks fewer questions: the role set is
--- four form factors rather than five jobs, so most of what the old one
--- detected was in service of gating roles that no longer exist.
---
--- ## `located` needs a port, not a global
---
--- Whether a machine knows where it is decides whether it can be a server (§10:
--- a GPS host must know its own coordinates). That answer lives behind the
--- locator port, so this takes ports rather than reaching for `gps` - which is
--- also what lets a spec ask "what would setup offer a computer that has never
--- been positioned" without a constellation.

local machine = {}

--- The kinds CC can be, as a name a person recognises.
machine.KINDS = {
  turtle = "Turtle",
  pocket = "Pocket computer",
  command = "Command computer",
  computer = "Computer",
}

--- The globals CC injects are the only reliable way to tell these apart.
function machine.kind()
  if turtle then
    return "turtle"
  end
  if pocket then
    return "pocket"
  end
  if commands then
    return "command"
  end
  return "computer"
end

--- Everything attached, in the shape `roles.check` reads.
---
--- `ports` is optional. Without it every port-derived answer is the honest
--- pessimistic one - a machine that cannot be asked where it is does not know
--- where it is - which is also what a machine being set up for the first time
--- actually looks like.
function machine.capabilities(ports)
  ports = ports or {}

  local kind = machine.kind()
  local caps = {
    kind = kind,
    turtle = kind == "turtle",
    pocket = kind == "pocket",
    id = os.getComputerID(),
    label = os.getComputerLabel(),

    -- Every computer has a screen. It is in the table anyway because
    -- `roles.check` reads it and a capability that is always true is still a
    -- capability - the day a headless machine exists, this is where it is said.
    screen = true,
    advanced = term.isColour(),

    modem = false,
    wireless = false,
    monitor = peripheral.find("monitor") ~= nil,
    speaker = peripheral.find("speaker") ~= nil,

    -- A Chunky Turtle keeps its chunk loaded, which is what lets one be a GPS
    -- host without the constellation dropping to three (D022).
    chunkLoaded = peripheral.find("chunky") ~= nil,
  }

  for _, name in ipairs(peripheral.getNames()) do
    -- A peripheral can advertise several types. An Ender Pocket upgrade reports
    -- something else first while still carrying the `modem` trait, so comparing
    -- only `getType`'s first return would silently disable the radio on exactly
    -- the hardware this fleet recommends.
    if peripheral.hasType(name, "modem") then
      caps.modem = true
      local wrapped = peripheral.wrap(name)
      if wrapped and wrapped.isWireless() then
        caps.wireless = true
      end
    end
  end

  -- Saved, not live. A machine that has been told where it is stays located
  -- through a chunk unload and a GPS outage; asking the constellation here
  -- would make setup's answer depend on whether four other computers happened
  -- to be loaded at that moment.
  caps.located = ports.locator ~= nil and ports.locator.saved() ~= nil

  return caps
end

--- What to show somebody about the machine they are setting up.
---
--- Lines rather than a table, because it is read once by a person and never
--- parsed. The absent things are listed too: "no modem" is the single most
--- useful line on this screen, and a list that only mentioned what was present
--- would leave it out.
function machine.describe(caps)
  local lines = {
    ("type    %s%s"):format(
      machine.KINDS[caps.kind] or caps.kind,
      caps.advanced and " (advanced)" or ""
    ),
    ("id      %d"):format(caps.id or 0),
    ("modem   %s"):format(caps.wireless and "wireless" or (caps.modem and "wired" or "none")),
  }
  if not caps.turtle then
    lines[#lines + 1] = ("monitor %s"):format(caps.monitor and "attached" or "none")
  end
  lines[#lines + 1] = ("position %s"):format(caps.located and "saved" or "not set")
  return lines
end

return machine
