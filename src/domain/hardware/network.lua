--- Everything a machine can reach, not just what is bolted to its sides.
---
--- ## The gap this closes
---
--- `peripherals.list()` answers what CC calls attached. On a machine with a
--- wired modem that is *supposed* to include everything on the cable, and the
--- day it does not there is nothing on any screen to say why. A base with four
--- disk drives on a network showed one drive - the one touching the computer -
--- and reported "2 attached" with complete confidence.
---
--- The cause is almost never the code. A wired modem publishes a block to the
--- network only once somebody has right-clicked the modem *on that block*, and
--- an un-clicked modem is indistinguishable from an absent one at a glance: the
--- cable is connected, the block is there, and nothing is listed.
---
--- So this asks each modem directly - `getNamesRemote` - and merges what comes
--- back. Two things fall out of that:
---
---   * anything the network knows about is listed even if the side scan missed
---     it, and
---   * a modem that reaches **nothing** is a fact this machine now holds, which
---     is the sentence somebody actually needs.
---
--- ## Reached-through is recorded, because it is the question being asked
---
--- "What does this cable connect me to" has no answer in CC's flat name list:
--- `drive_0` looks exactly like a drive on the left-hand side. Every entry here
--- carries the modem it was found through, so a page can say where a thing is
--- rather than only that it exists.
---
--- ## Nothing here raises
---
--- Every call goes through the port's `call`, which answers `false, reason`
--- instead of throwing. `getNamesRemote` does not exist on a wireless modem and
--- a peripheral can be pulled off the wall between two calls; both are ordinary,
--- and neither may take out the page that would have shown you which one it was.

local network = {}

--- Peripherals on the cable behind a modem.
---
--- Empty for a wireless modem, which has no cable, and for a wired one with
--- nothing published to it - the two are told apart by `wireless` rather than
--- by the length of this list, because "no network" and "empty network" call
--- for opposite advice.
function network.remotes(peripherals, modem)
  local results = { peripherals.call(modem, "getNamesRemote") }
  if not results[1] or type(results[2]) ~= "table" then
    return {}
  end

  local names = {}
  for _, name in ipairs(results[2]) do
    if type(name) == "string" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

--- Is this modem wireless? Nil when it will not say.
---
--- Three-valued on purpose. A modem that errors on `isWireless` is a modem
--- whose kind is unknown, and guessing "wired" would produce advice about
--- right-clicking cables for something with no cable.
function network.wireless(peripherals, modem)
  local results = { peripherals.call(modem, "isWireless") }
  if not results[1] or type(results[2]) ~= "boolean" then
    return nil
  end
  return results[2]
end

--- The types of a peripheral reachable only through a modem.
---
--- `getTypeRemote` is plural for the same reason `getType` is: a block can be
--- an inventory *and* a furnace, and collapsing that to the first would make
--- every capability check wrong for exactly the modded blocks worth finding.
function network.typesOf(peripherals, modem, name)
  local results = { peripherals.call(modem, "getTypeRemote", name) }
  local types, primary = {}, nil

  if results[1] then
    for index = 2, #results do
      local kind = results[index]
      if type(kind) == "string" then
        types[kind] = true
        primary = primary or kind
      end
    end
  end

  return types, primary
end

--- Everything within reach, sides and cable alike.
---
--- Returns the same shape `peripherals.list()` does - `{ name, types, primary }`
--- - with two fields added: `via`, the modem it was found through, and `remote`,
--- true for anything that is only reachable that way. Callers that do not care
--- about either can ignore both and treat this as a longer list.
function network.survey(peripherals)
  if peripherals == nil then
    return {}
  end

  local found = peripherals.list()
  if type(found) ~= "table" then
    return {}
  end

  local out, seen = {}, {}
  for _, entry in ipairs(found) do
    out[#out + 1] = entry
    seen[entry.name] = entry
  end

  -- Second pass rather than one, because a modem can publish a peripheral that
  -- is also on a side, and the side entry is the better one: it has the types
  -- CC reported directly rather than the ones a modem was asked for.
  for _, entry in ipairs(found) do
    if entry.types and entry.types.modem then
      for _, name in ipairs(network.remotes(peripherals, entry.name)) do
        local known = seen[name]
        if known ~= nil then
          -- Already listed, but now we know how it is reached. Worth recording
          -- even for something on a side: "also on the network" is how a person
          -- discovers the cable is doing what they wired it to do.
          known.via = known.via or entry.name
        else
          local types, primary = network.typesOf(peripherals, entry.name, name)
          local remote = {
            name = name,
            types = types,
            primary = primary,
            via = entry.name,
            remote = true,
          }
          out[#out + 1] = remote
          seen[name] = remote
        end
      end
    end
  end

  return out
end

--- What a modem is, and what it connects this machine to.
---
--- The sentence the Hardware page shows when somebody selects a modem, and the
--- reason this module exists. A wired modem reaching nothing is the single most
--- confusing state in a CC base - the cable is laid, the blocks are placed, and
--- the computer lists none of them - and the fix is a right-click that nothing
--- anywhere prompts you to make.
function network.explain(peripherals, name)
  local wireless = network.wireless(peripherals, name)
  if wireless == true then
    return "wireless - this is the fleet radio, not a cable"
  end

  local names = network.remotes(peripherals, name)
  if #names == 0 then
    if wireless == nil then
      return "modem - it will not say whether it is wired or wireless"
    end
    return "wired, reaching nothing - right-click the modem on each block until it lights up"
  end

  return ("wired, reaching %d: %s"):format(#names, table.concat(names, " "))
end

--- How many of a survey are only reachable over a cable.
function network.reach(list)
  local remote = 0
  for _, entry in ipairs(list or {}) do
    if entry.remote then
      remote = remote + 1
    end
  end
  return remote
end

return network
