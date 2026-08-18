--- Port: persistent files.
---
--- Four methods, and `write` is the interesting one: it must REPLACE, not
--- append and not truncate-then-fill. CC has no atomic replace, so the cc
--- adapter writes a `.tmp` alongside, closes it, and only then moves it over the
--- live file - the same technique `adapters/cc/config.lua` uses and for the same
--- reason. A turtle that loses power mid-save must find either the old file or
--- the new one, never half of either. `.nav` is the file that makes this a
--- safety property rather than a tidiness one.
---
--- Content is an opaque string. Serialisation belongs to the caller, because the
--- domain knows what shape its records are and a storage port does not.

local contract = require("ports.contract")

local storage = {}

storage.NAME = "storage"

storage.METHODS = {
  "read", -- (path) -> string | nil
  "write", -- (path, text) -> true | false, reason;  replaces atomically
  "list", -- (path) -> array of names directly under path
  "delete", -- (path) -> true | false, reason
}

function storage.check(impl)
  return contract.check(storage.NAME, storage.METHODS, impl)
end

--- Storage that forgets everything. Reads find nothing, writes succeed and go
--- nowhere. Use `adapters.sim.storage` when the test needs the write back.
function storage.null()
  return contract.null(storage.METHODS, {
    read = nil,
    write = true,
    list = function()
      return {}
    end,
    delete = true,
  })
end

return storage
