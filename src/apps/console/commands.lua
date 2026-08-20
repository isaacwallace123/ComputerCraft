--- What a typed line means. No screen, no radio, no state.
---
--- `legacy/console.lua` parses and performs in the same function, which is why
--- none of its parsing has ever been tested and why every command grew its own
--- idea of what a bad argument looks like. Here a line becomes an intent or an
--- error, and something else decides what to do about it.
---
--- ## Refusals are the product
---
--- A console is mostly used by somebody who has just been surprised by
--- something, and the failure mode that matters is not a crash - it is a
--- command that looks like it worked. So every refusal says what was wrong with
--- what they typed, and `parse` never guesses: a command with the wrong number
--- of arguments is refused rather than run with defaults, because a mine placed
--- at a default centre is a mine in the wrong place.
---
--- ## Coordinates go through `util.coordinates`
---
--- Not a `%d+` scan, and this is a scar. ICOS v1.2.5's GPS setup used a greedy
--- separator that could swallow the minus sign off a negative Y or Z, and the
--- affected values could never be corrected automatically because the intended
--- sign was unknowable. Every coordinate input in this repository goes through
--- the one parser that handles signs, and this is one of them.

local util = require("lib.util")

local commands = {}

--- The order they are listed in `help`, which is roughly how often they are
--- wanted rather than alphabetical: somebody at a console is usually placing a
--- mine or moving turtles, not reading about it.
commands.HELP = {
  { name = "mine", usage = "mine at <x> <z> <y>", about = "place the shared mine" },
  { name = "mine", usage = "mine", about = "show where the mine is" },
  { name = "recall", usage = "recall [id]", about = "bring one turtle home, or all of them" },
  { name = "deploy", usage = "deploy [id]", about = "send one turtle to work, or all of them" },
  { name = "park", usage = "park <id>", about = "stop a turtle taking new work" },
  { name = "devices", usage = "devices", about = "what the base knows about each machine" },
  { name = "clear", usage = "clear", about = "empty this log" },
  { name = "help", usage = "help", about = "this list" },
}

--- Every word that can start a line, in the order `help` lists them.
---
--- Separate from `HELP` because two entries there share the name `mine` - the
--- usage list wants both forms and a completer wants the word once.
commands.NAMES = {
  "mine",
  "recall",
  "deploy",
  "park",
  "devices",
  "clear",
  "help",
}

--- What can follow each command, for completing the second word.
---
--- Only where there is a fixed word to offer. `park` takes a device id and
--- nothing else, so it is absent rather than listed with an empty table - a
--- completer that offered nothing would still eat the Tab key.
commands.FOLLOWS = {
  mine = { "at" },
  recall = { "all" },
  deploy = { "all" },
}

--- The rest of the word somebody is part-way through typing.
---
--- Returns the characters to append, or nil when there is nothing to add. Nil
--- rather than an empty string so a caller can tell "nothing to complete" from
--- "already complete" without measuring a string.
---
--- ## It completes only when the answer is certain
---
--- `d` matches both `deploy` and `devices`, and guessing between them would put
--- a word somebody did not type in front of a fleet command. So an ambiguous
--- prefix completes to the part they share - `de` - which is what a shell does
--- and is the behaviour that never surprises anybody.
---
--- ## Empty completes to nothing
---
--- A blank prompt offering `mine` would mean Tab on an empty line places a mine
--- at whatever it parsed. The prompt is where the fleet is controlled from and
--- an accident there moves turtles.
function commands.complete(line)
  local text = tostring(line or "")
  if text == "" then
    return nil
  end

  local head, rest = text:match("^(%S+)(.*)$")
  if head == nil then
    return nil
  end

  -- Still on the first word: no space has been typed yet.
  if rest == "" then
    return commands.shared(commands.NAMES, head:lower())
  end

  -- Past the first word, and only the second is completable. Beyond that the
  -- arguments are coordinates and device ids, which are numbers nobody has a
  -- list of.
  local options = commands.FOLLOWS[head:lower()]
  if options == nil then
    return nil
  end

  local second = rest:match("^%s+(%S*)$")
  if second == nil then
    return nil
  end
  return commands.shared(options, second:lower())
end

--- The longest ending shared by every option starting with `prefix`.
---
--- The shell rule, and the reason it is worth having: completing an ambiguous
--- prefix to one arbitrary match is how somebody ends up running `devices` when
--- they meant `deploy`.
function commands.shared(options, prefix)
  local matched = {}
  for _, name in ipairs(options) do
    if name:sub(1, #prefix) == prefix then
      matched[#matched + 1] = name
    end
  end

  if #matched == 0 then
    return nil
  end

  local answer = matched[1]
  for index = 2, #matched do
    local other = matched[index]
    local keep = 0
    while keep < #answer and answer:sub(keep + 1, keep + 1) == other:sub(keep + 1, keep + 1) do
      keep = keep + 1
    end
    answer = answer:sub(1, keep)
  end

  local addition = answer:sub(#prefix + 1)
  if addition == "" then
    return nil
  end
  return addition
end

--- Split a line into lowercase words, preserving the original for arguments
--- that are case-sensitive. Nothing here is, today; the split is separate
--- anyway so that adding one does not mean rewriting the parser.
local function words(line)
  local out = {}
  for word in tostring(line or ""):gmatch("%S+") do
    out[#out + 1] = word
  end
  return out
end

--- Turn a line into an intent, or an error.
---
--- Returns `{ kind = ..., ... }`, or `nil, reason`. An empty line is `nil, nil`
--- - not an error, because pressing enter on an empty prompt is not a mistake
--- and telling somebody off for it is how a console becomes annoying to use.
function commands.parse(line)
  local parts = words(line)
  local head = (parts[1] or ""):lower()

  if head == "" then
    return nil, nil
  end

  if head == "help" or head == "?" then
    return { kind = "help" }
  end

  if head == "clear" then
    return { kind = "clear" }
  end

  if head == "devices" or head == "status" or head == "list" then
    return { kind = "devices" }
  end

  if head == "mine" then
    local action = (parts[2] or ""):lower()
    if action == "" then
      return { kind = "mine.show" }
    end
    if action ~= "at" then
      return nil, "mine at <x> <z> <y>, or just `mine` to see where it is"
    end

    -- `x z y`, not `x y z`. A mine is a place on the ground and a depth, and
    -- world order invites typing the Y where the Z goes - which places the mine
    -- a hundred blocks sideways and looks entirely plausible until turtles
    -- start walking.
    local x, z, y = util.coordinates(table.concat(parts, " ", 3))
    if x == nil then
      return nil, "three numbers please: mine at <x> <z> <y>"
    end
    if y < -63 or y > 310 then
      return nil, "the surface must be between Y -63 and Y 310 so cruise lanes fit"
    end
    return { kind = "mine.place", centreX = x, centreZ = z, surfaceY = y }
  end

  if head == "recall" or head == "deploy" or head == "park" then
    local target = parts[2]

    -- `park` has no "all". Parking the whole fleet is a thing somebody would
    -- mean once and regret, and there is already a word for it: recall.
    if target == nil or target:lower() == "all" then
      if head == "park" then
        return nil, "park needs a device id - use recall to bring everything home"
      end
      return { kind = "want.all", mode = head }
    end

    local id = tonumber(target)
    if id == nil then
      return nil, ("%s <id> - a device number, or `all`"):format(head)
    end
    return { kind = "want", mode = head, id = id }
  end

  -- Named rather than "unknown command", because the thing somebody wants at
  -- that moment is the list.
  return nil, ("no command `%s` - type help"):format(head)
end

--- The help text, as lines.
---
--- Built rather than stored so the usage strings live once, next to what they
--- do, and cannot drift from the parser that reads them.
function commands.help()
  local lines = {}
  for _, entry in ipairs(commands.HELP) do
    lines[#lines + 1] = ("%-22s %s"):format(entry.usage, entry.about)
  end
  return lines
end

return commands
