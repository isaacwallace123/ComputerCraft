--- A general carrying its crew's heartbeats to the base.
---
--- ## Why the miners stop talking to the server
---
--- Every turtle unicast its own status to the base every two seconds. That is
--- correct and it does not scale: rednet has no routing, so each message is a
--- broadcast at the physical layer that every computer in range wakes up for,
--- and the base answers each one separately. With four turtles it is noise.
--- With twenty it is a base that spends its whole tick budget on status
--- messages, and the symptom is not a crash - it is a fleet that shows offline
--- while every machine in it is working, because the base could not keep up
--- with the answering.
---
--- So a miner reports to its general and the general reports the crew. One
--- message from the general carries what four sent, and the base answers once.
---
--- ## The miner needs no code for this
---
--- `domain/protocol/peer.lua` binds a device to whoever last sent it a
--- `desired` reply, and only the base sent one. Now a general does too - so a
--- miner binds to its general by the same rule that bound it to the base, with
--- nothing in the miner deciding anything.
---
--- That also gives the failure path for free. `peer.FORGET` is thirty seconds:
--- a general that stops answering is forgotten, the miner broadcasts, and the
--- base answers it directly again. Losing a general costs its crew half a
--- minute of latency and nothing else, which is the property that makes this
--- safe to turn on - it is an optimisation that cannot strand anybody.
---
--- ## Age travels with the report, and this is the whole correctness argument
---
--- A relayed snapshot is older than the message carrying it. If the base
--- stamped every entry in a batch with the moment the batch arrived, a miner
--- that went quiet twenty minutes ago would read as online for as long as its
--- general kept talking - which is precisely the failure the health thresholds
--- exist to catch, reintroduced one layer up.
---
--- So each entry carries how long ago the general heard it, and the base
--- subtracts. A device the general has not heard from recently is dropped from
--- the batch entirely rather than sent as very stale: at that point the general
--- knows nothing useful, and the base's own `OFFLINE_AFTER` is the honest
--- judge.
---
--- Pure, with the clock injected. Same rule as every other domain file.

local relay = {}

--- How long a general keeps repeating what it heard, in seconds.
---
--- Shorter than `registry.OFFLINE_AFTER`, deliberately. Past this the general
--- stops mentioning the device at all and the base's own staleness takes over -
--- so the two never disagree, and a device cannot be held alive on the base's
--- roster by a general that is merely repeating itself.
relay.KEEP = 20

function relay.empty()
  return { crew = {}, goals = {} }
end

--- Record what one crew member just said.
---
--- Returns false for anything that is not a usable report, which covers a
--- malformed message and a message from something that is not a device. A
--- general that accepted nonsense would forward it, and the base would show a
--- device that does not exist.
function relay.hear(state, id, report, now)
  local key = tonumber(id)
  if state == nil or key == nil or type(report) ~= "table" then
    return false
  end

  state.crew = state.crew or {}
  state.crew[key] = {
    id = key,
    snapshot = report.snapshot,
    applied = report.applied,
    at = now,
  }
  return true
end

--- The goal this general holds for one of its crew, or nil.
---
--- Cached from the base's reply so the general can answer a crew heartbeat
--- immediately rather than asking upstream and making the miner wait two round
--- trips for an order it could have had in one.
function relay.goalFor(state, id)
  local key = tonumber(id)
  if state == nil or key == nil then
    return nil
  end
  return (state.goals or {})[key]
end

--- Take the goals the base sent down for the crew.
---
--- Replaces rather than merges. The base's copy is authoritative and a goal it
--- has stopped sending is a goal that no longer exists; merging would leave a
--- general handing out an order the base has forgotten, which is the one thing
--- a cache must never do.
function relay.remember(state, goals)
  if state == nil then
    return false
  end
  state.goals = {}
  if type(goals) ~= "table" then
    return false
  end
  for id, goal in pairs(goals) do
    local key = tonumber(id)
    if key ~= nil and type(goal) == "table" then
      state.goals[key] = goal
    end
  end
  return true
end

--- What to send the base: everything heard recently, with its age.
---
--- Returns a list, oldest report first so the base applies them in the order
--- they happened. Empty for a general with no crew, and the caller sends no
--- `roster` field at all in that case rather than an empty list - a general
--- that reported an empty crew on every heartbeat would be saying "I have
--- nobody" twice a second, which is a thing it already says by not being a
--- general.
function relay.batch(state, now, keep)
  local out = {}
  if state == nil then
    return out
  end

  local limit = (keep or relay.KEEP) * 1000
  for _, entry in pairs(state.crew or {}) do
    local age = now - (entry.at or 0)
    if age >= 0 and age <= limit then
      out[#out + 1] = {
        id = entry.id,
        snapshot = entry.snapshot,
        applied = entry.applied,

        -- Seconds, rounded. Milliseconds would be false precision on a number
        -- that already travelled over a radio, and the base compares it against
        -- thresholds measured in tens of seconds.
        age = math.floor(age / 1000),
      }
    end
  end

  table.sort(out, function(a, b)
    if a.age ~= b.age then
      return a.age > b.age
    end
    return a.id < b.id
  end)
  return out
end

--- Forget crew this general no longer has.
---
--- Called when the base sends down a new crew list. Without it a general that
--- lost a miner to another general would keep relaying it, and two generals
--- would report the same device with different ages - so which one the base
--- believed would depend on which message arrived last.
function relay.only(state, crew)
  if state == nil then
    return false
  end

  local keep = {}
  for _, id in ipairs(crew or {}) do
    local key = tonumber(id)
    if key ~= nil then
      keep[key] = true
    end
  end

  for id in pairs(state.crew or {}) do
    if not keep[id] then
      state.crew[id] = nil
    end
  end
  return true
end

--- When the base heard a relayed device, in its own clock.
---
--- The subtraction that keeps a relayed roster honest. Clamped at `now` so a
--- general with a clock running fast cannot place a report in the future, which
--- would make the device permanently the freshest thing on the roster.
function relay.heardAt(now, age)
  local seconds = tonumber(age) or 0
  if seconds < 0 then
    seconds = 0
  end
  return math.min(now, now - seconds * 1000)
end

return relay
