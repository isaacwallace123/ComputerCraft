--- Whether a machine may tell the world where it is.
---
--- Every machine in the fleet carries coordinates and every machine that can be
--- trusted with them serves the constellation. That is a change from the first
--- design, which made GPS a server-only service and refused to serve a position
--- obtained *from* GPS, and the reasoning behind that refusal was wrong:
---
--- > "Serving a GPS fix would let a constellation bootstrap itself off its own
--- > error, and the error would drift with every host that joined."
---
--- That is true of real GPS, where a fix carries measurement noise. It is not
--- true here. CC trilaterates from exact integer block coordinates and exact
--- modem distances, so a fix computed from four correct hosts is not
--- approximately right, it is *the same number*. There is nothing to drift.
---
--- ## What is actually dangerous
---
--- Not derivation. **Movement it cannot detect.** A machine that answers with a
--- position it has since left is worse than one that stays silent, because
--- silence makes `gps.locate` return nil and every caller in this codebase
--- treats nil as "I do not know" and falls back to dead reckoning - whereas a
--- confident wrong number makes a turtle drive into a wall and keep going.
---
--- So the question is not "does this machine move", it is **"would this machine
--- know?"** Three answers:
---
---   * A **computer** is a block. It cannot move without being broken, and
---     breaking it ends the program. Anchored, always.
---   * A **turtle** moves constantly and counts every confirmed move, so it
---     knows exactly when it is under way. Anchored while parked, and not
---     otherwise.
---   * A **pocket computer** travels in somebody's inventory at ten blocks a
---     second and has no way to observe any of it. There is no state it can
---     check, no event it receives, and nothing it could report. **Never
---     anchored**, on any reading.
---
--- That last one is why the rule is phrased this way rather than as a list of
--- roles. A pocket computer is not excluded because of what it is called; it is
--- excluded because it is the one machine that cannot answer the question. A
--- rule written as "not mobile" would be a rule somebody relaxes later for a
--- pocket computer sitting in an item frame - which is exactly the case where it
--- is still wrong, because nothing stops somebody picking it up.
---
--- It still *stores* a position, and should. Knowing where you are is useful on
--- the machine you carry around; telling other machines where **they** are is a
--- different job with a different requirement.
---
--- ## The bootstrap needs four
---
--- Trilateration needs four hosts, so the first four positions in a world have
--- to be entered by a person. After that every machine that boots can locate
--- itself and immediately becomes a fifth, a sixth, a tenth - which is the whole
--- point: a fleet that grows its own constellation instead of one that needs
--- four dedicated computers built by hand first.

local host = {}

--- How many hosts a fix needs. CC's own requirement, not ours.
host.QUORUM = 4

--- Where a position came from.
---
--- Kept because it is worth being able to see, not because it changes what is
--- served: a fix and a typed number are equally exact and equally capable of
--- being wrong, and the second is the more likely of the two.
host.SOURCES = { manual = true, fix = true }

--- May this machine answer the constellation?
---
--- `state` is `{ position, anchored, modem, why }`. Returns false and the reason,
--- because every refusal here has an action attached and a beacon that went
--- quiet without saying why is the hardest kind of outage to find - the symptom
--- appears on a different machine.
function host.mayServe(state)
  state = state or {}

  if not state.modem then
    return false, "no wireless modem"
  end

  local position = state.position
  if type(position) ~= "table" then
    return false, "this machine has no position - run `commands/locate`"
  end
  if tonumber(position.x) == nil or tonumber(position.y) == nil or tonumber(position.z) == nil then
    return false, "the saved position is incomplete - run `commands/locate`"
  end

  -- The whole rule.
  --
  -- `anchored` is the caller saying "I would know if I had moved, and I have
  -- not". A turtle under way knows where it is well enough to get home and not
  -- well enough to be believed by somebody else - dead reckoning is exact only
  -- while every move is confirmed, and a machine answering between two of them
  -- is answering about a block it has already left.
  if not state.anchored then
    return false, state.why or "not anchored - cannot vouch for this position"
  end

  return true
end

--- Is this fix worth writing down?
---
--- A position that agrees with the one on disk is not worth a disk write, and a
--- boot that rewrote `.location` every time would be a boot that costs a write
--- on every machine in the fleet for no change. Returns false with a reason so a
--- caller can say "confirmed" rather than "saved", which is the more useful
--- thing to print.
function host.changed(current, fresh)
  if type(fresh) ~= "table" then
    return false, "no fix"
  end
  if type(current) ~= "table" then
    return true, "first fix"
  end
  if
    tonumber(current.x) == tonumber(fresh.x)
    and tonumber(current.y) == tonumber(fresh.y)
    and tonumber(current.z) == tonumber(fresh.z)
  then
    return false, "unchanged"
  end
  return true, "moved"
end

--- Merge a fresh fix into a saved record without losing what GPS cannot know.
---
--- Heading is the one thing four hosts cannot tell a turtle - a stationary
--- turtle looks identical from every direction - so a fix updates three fields
--- and leaves the fourth alone. Overwriting it would make every boot with a
--- working constellation forget which way home is, which is a turtle mining
--- confidently in the wrong direction.
function host.merge(saved, fix)
  local out = {}
  for key, value in pairs(type(saved) == "table" and saved or {}) do
    out[key] = value
  end
  out.x = math.floor(tonumber(fix.x) or 0)
  out.y = math.floor(tonumber(fix.y) or 0)
  out.z = math.floor(tonumber(fix.z) or 0)
  out.source = "fix"
  return out
end

return host
