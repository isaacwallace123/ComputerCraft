--- Choosing where to unload, and what it costs to get there.
---
--- §7 of docs/icos-2.md names the two things this has to get right, and both are
--- about fuel rather than about depots.
---
--- ## The dangerous half
---
--- > *"`returnDistance` currently assumes the route home. Routing to a drop-off
--- > that is not home changes the exact return-fuel reserve, which is the single
--- > most safety-critical number in the codebase (D009). The chosen drop-off has
--- > to be picked **before** the outward fuel check, not after the inventory
--- > fills."*
---
--- That ordering is the whole risk of phase 4. A turtle that flies out on a
--- reserve computed for home, fills up, and only then decides to visit a depot
--- four hundred blocks the other way has already spent the fuel it needed to get
--- back. So `choose` is called at deployment and its answer is part of the fuel
--- check, and `cost` is the number D009's reserve is computed from.
---
--- The cost includes the leg *from the depot back to home*, not just the leg out
--- to it. A turtle is not safe when it reaches a chest; it is safe when it can
--- still get home afterwards, and the two differ by an entire return trip.
---
--- ## The harmless half
---
--- > *"The chest-below-home convention (D008) stays as the fallback, and stays
--- > the default when the list is empty. An empty list must behave exactly like
--- > today."*
---
--- `choose` returns `nil` for "unload below home", and returns it for an empty
--- list, a list with nothing enabled, a list with nothing that accepts the
--- cargo, and a list where everything is out of fuel range. Every path that is
--- not a positive answer is the old behaviour, which is what makes this safe to
--- ship to a fleet that never opens the Drop-offs screen.
---
--- ## Pure
---
--- No clock, no storage, no CC global. `now` is passed in for the full-report
--- expiry and nothing else.

local list = require("domain.depot.list")

local select = {}

--- Distance a turtle actually travels between two points.
---
--- Manhattan, because `nav.goTo` only moves on cardinals - a diagonal is walked
--- as a staircase and costs the sum of the legs, not the hypotenuse. Using
--- Euclidean here would under-estimate every route and the error would land in
--- the fuel reserve, which is the one number that must never be optimistic.
function select.distance(from, to)
  if from == nil or to == nil then
    return math.huge
  end
  return math.abs((from.x or 0) - (to.x or 0))
    + math.abs((from.y or 0) - (to.y or 0))
    + math.abs((from.z or 0) - (to.z or 0))
end

--- What using this depot costs, in fuel, from where the turtle will be.
---
--- Out to the depot and then home again. A turtle is not safe when it reaches a
--- chest - it is safe when it can still get home afterwards, and the difference
--- is a whole return leg. D009 says the reserve follows the planned route; this
--- is that route when the route ends somewhere other than home.
function select.cost(from, depot, home)
  local out = select.distance(from, depot.position)
  if out == math.huge then
    return math.huge
  end
  if home == nil then
    return out
  end
  return out + select.distance(depot.position, home)
end

--- Pick a drop-off, or nil for "unload below home".
---
--- `options`:
---   `from`    where the turtle will be when it needs to unload
---   `home`    its home block, so the return leg can be costed
---   `fuel`    fuel available for the whole errand, or nil for unlimited
---   `item`    a representative item of the cargo, for `accepts`
---   `now`     for the full-report expiry
---
--- Rules in the order §7 gives them: enabled, accepts the cargo, not known
--- full, reachable within the fuel reserve, then nearest, then list order.
---
--- Returns the depot and its cost, so the caller does not have to recompute the
--- number it must then reserve.
function select.choose(state, options)
  options = options or {}
  local usable = list.usable(state, options.now or 0, options.item, options.window)
  if #usable == 0 then
    return nil
  end

  local best, bestCost
  for _, depot in ipairs(usable) do
    local cost = select.cost(options.from, depot, options.home)
    -- Unreachable is not "expensive", it is disqualifying. A turtle that picked
    -- the nearest depot it could not actually reach would strand itself while
    -- believing it had made the safe choice.
    if cost ~= math.huge and (options.fuel == nil or cost <= options.fuel) then
      -- Strictly cheaper, so an equal cost leaves the earlier one in place -
      -- which is how list order becomes the documented tie-break rather than an
      -- accident of iteration.
      if bestCost == nil or cost < bestCost then
        best, bestCost = depot, cost
      end
    end
  end

  if best == nil then
    return nil
  end
  return best, bestCost
end

--- What it costs to unload the old way: fly home and drop down.
---
--- Named so a caller can compare like with like. The chest is below the home
--- block, so there is no separate leg to it - D008's whole point is that
--- "below" needs no orientation and no extra travel.
function select.homeCost(from, home)
  return select.distance(from, home)
end

--- The complete answer a job needs before it goes out: where to unload, and the
--- fuel that decision commits it to.
---
--- One call rather than two so the two cannot disagree. A caller that asked for
--- the depot and then computed the reserve itself would eventually compute it
--- from a different position, and the failure would be a turtle that ran out
--- one block short of a chest it could see.
function select.plan(state, options)
  options = options or {}
  local depot, cost = select.choose(state, options)
  if depot == nil then
    return {
      depot = nil,
      position = options.home,
      cost = select.homeCost(options.from, options.home),
      reason = #(state.depots or {}) == 0 and "no drop-offs configured" or "none usable",
    }
  end
  return { depot = depot, position = depot.position, cost = cost }
end

return select
