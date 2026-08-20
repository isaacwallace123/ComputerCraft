--- Port: what is plugged into this machine.
---
--- Every other port names one capability - a clock, a screen, a radio - because
--- the machine either has it or does not. This one is a *discovery* port: the
--- answer is a list, it changes while the machine is running, and most of what
--- comes back is something no part of ICOS was written for.
---
--- That is the point. A fleet in a modpack is surrounded by blocks somebody
--- else's mod put there, and the difference between an OS that can see them and
--- one that cannot is whether the base can ever do more than mine.
---
--- ## It returns descriptions, not wrapped tables
---
--- `list` gives names and types; `call` invokes one method by name. A port that
--- handed back `peripheral.wrap` results would be handing back live CC objects,
--- and every caller holding one would be a caller that cannot be tested and a
--- layer boundary that exists on paper.
---
--- ## Types are plural
---
--- CC:Tweaked gives a peripheral more than one type - a Create mod block might
--- be both `inventory` and something of its own - so `types` is a set rather
--- than a string. Code that asked "is this a drive" against a single type would
--- work for vanilla and quietly miss half of a modpack.

local contract = require("ports.contract")

local peripherals = {}

peripherals.NAME = "peripherals"

peripherals.METHODS = {
  "list", -- () -> array of { name, types = { [type] = true } }
  "call", -- (name, method, ...) -> ok, result... ; never raises
  "methods", -- (name) -> array of method names, or nil
}

function peripherals.check(impl)
  return contract.check(peripherals.NAME, peripherals.METHODS, impl)
end

--- A machine with nothing attached.
---
--- The honest state of a turtle in a hole, and the one every spec wants by
--- default. `call` answering `false` rather than raising matters more here than
--- for most ports: a page that lists hardware will call methods on things it has
--- never heard of, and the whole design assumes that failing is ordinary.
function peripherals.null()
  return contract.null(peripherals.METHODS, {
    list = function()
      return {}
    end,
    call = false,
    methods = nil,
  })
end

return peripherals
