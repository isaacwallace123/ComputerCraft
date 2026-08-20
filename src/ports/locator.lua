--- Port: where this computer is.
---
--- Two answers, and keeping them apart is the whole point of the port.
---
--- `gps` asks the constellation and can fail - four hosts have to be loaded and
--- in range, and it costs a round trip. It also cannot report which way a turtle
--- is facing, because a stationary turtle looks identical from every direction.
---
--- `saved` is what this machine was told about itself at setup and wrote down.
--- It never fails, it includes heading, and it is what dead reckoning runs on
--- between fixes. It is also the only answer available to the first three
--- servers of a new constellation, which have no GPS to ask.
---
--- Code that needs a position should prefer `saved` and use `gps` to confirm or
--- correct it, never the other way round: a missed GPS reply must not be able to
--- make a turtle forget where it is.

local contract = require("ports.contract")

local locator = {}

locator.NAME = "locator"

locator.METHODS = {
  "gps", -- (timeoutSeconds) -> x, y, z | nil
  "saved", -- () -> { x, y, z, facing, dimension } | nil
}

function locator.check(impl)
  return contract.check(locator.NAME, locator.METHODS, impl)
end

--- A computer that does not know where it is, which is the correct answer for a
--- machine that has not been through setup.
function locator.null()
  return contract.null(locator.METHODS)
end

return locator
