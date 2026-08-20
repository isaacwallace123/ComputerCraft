--- Port: the turtle's body.
---
--- Movement, digging, inspection, placement, and inventory - the hardware half
--- of `turtle/`. Nothing here decides anything; the port is the arm, not the
--- judgement. Which block is safe to break, when a shaft may be opened, and how
--- much fuel a route home needs are all domain questions and stay in `turtle/`
--- and `jobs/`.
---
--- Every method reports failure the way CC does, as `false, reason`, and the
--- reason string is load-bearing: `nav` distinguishes "Movement obstructed" from
--- a protected block from a peer, and D025 turns that distinction into a detour
--- rather than an abandoned trip. An adapter that flattened failures into a bare
--- `false` would quietly delete that behaviour.
---
--- Directions are named rather than numbered - "forward", "up", "down" - because
--- a turtle has exactly three faces it can work and an integer would only invite
--- somebody to do arithmetic on them.
---
--- Not used yet. Written now so `adapters/cc` and `adapters/sim` have one agreed
--- shape to implement, and so the turtle code has somewhere to land when it is
--- lifted off the `turtle` global in a later phase.

local contract = require("ports.contract")

local body = {}

body.NAME = "body"

body.METHODS = {
  "move", -- (direction) -> true | false, reason
  "turn", -- ("left"|"right") -> true | false, reason
  "dig", -- (direction) -> true | false, reason
  "detect", -- (direction) -> boolean; solid, in the game's sense
  "inspect", -- (direction) -> true, { name, state, tags } | false, reason
  "place", -- (direction) -> true | false, reason
  "drop", -- (direction, count) -> true | false, reason
  "select", -- (slot) -> boolean
  "slot", -- () -> currently selected slot
  "stack", -- (slot) -> { name, count } | nil
  "fuel", -- () -> level, limit
  "refuel", -- (count) -> boolean
}

function body.check(impl)
  return contract.check(body.NAME, body.METHODS, impl)
end

--- A body that refuses everything. This is what a computer without turtle
--- hardware honestly has, and it is safer than absent: code that asks a base
--- station to move gets a clean refusal instead of an attempt to index nil.
function body.null()
  return contract.null(body.METHODS, {
    move = function()
      return false, "no turtle hardware"
    end,
    turn = function()
      return false, "no turtle hardware"
    end,
    dig = function()
      return false, "no turtle hardware"
    end,
    detect = false,
    inspect = function()
      return false, "no turtle hardware"
    end,
    place = function()
      return false, "no turtle hardware"
    end,
    drop = function()
      return false, "no turtle hardware"
    end,
    select = false,
    slot = 1,
    stack = nil,
    fuel = function()
      return 0, 0
    end,
    refuel = false,
  })
end

return body
