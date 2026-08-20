--- Port: turning a table into text and back.
---
--- Every service that persists anything goes through this, and it is a port for
--- one specific reason: `textutils` is a CC global, and a `os/` composition layer
--- that reached for it would make the whole server untestable for the sake of
--- two functions.
---
--- ## Decode never raises
---
--- A caller reading a file it did not write - which is every caller, because the
--- file was written by a previous version, a previous build, or a crash halfway
--- through - must be able to ask "is this a table?" without wrapping the
--- question in a `pcall`. So `decode` answers nil for anything it cannot read,
--- and the services above treat nil the same way they treat a missing file: as a
--- machine that has not been configured yet rather than as a reason not to boot.
---
--- ## Encode can fail, and says so
---
--- The asymmetry is deliberate. A value that cannot be serialised is a bug in
--- the caller - a function or a recursive table in something meant to be state -
--- and it should be loud, immediately, where it was written. A silent failure
--- there is a file that quietly stops being updated, which is discovered weeks
--- later when a reboot restores a fleet from a snapshot nobody knew was frozen.

local contract = require("ports.contract")

local serialise = {}

serialise.NAME = "serialise"

serialise.METHODS = {
  "encode", -- (value) -> string;  raises if the value cannot be represented
  "decode", -- (text) -> value | nil;  never raises
}

function serialise.check(impl)
  return contract.check(serialise.NAME, serialise.METHODS, impl)
end

--- A serialiser that loses everything.
---
--- Encodes to the empty string and decodes to nil, which pairs with
--- `storage.null()` to make a machine that persists nothing and boots clean
--- every time - occasionally what a test wants, and never what a server wants.
function serialise.null()
  return contract.null(serialise.METHODS, {
    encode = "",
    decode = nil,
  })
end

return serialise
