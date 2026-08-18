--- Serialise port over `textutils`.
---
--- Thin, because CC's implementation is the one every other tool in the world
--- reads: `edit .fleet2` shows a table a person can understand and fix, and
--- `textutils.unserialise` is what `core/config.lua` has always used. A cleverer
--- encoding would be smaller and would make the one recovery path that has ever
--- actually mattered - somebody opening the file and deleting the bad line -
--- impossible.

local serialise = require("ports.serialise")

local adapter = {}

function adapter.new()
  local impl = {}

  --- Raises on a value CC cannot represent.
  ---
  --- `allow_repetitions` is on, because state tables legitimately share
  --- subtables - a device record referenced from two indexes is the same record,
  --- not two - and without it `serialise` refuses the whole table over a
  --- duplication that is correct.
  ---
  --- It does not make cycles work. A genuinely recursive table still raises, and
  --- should: a cycle in something being written to disk is a bug in the caller,
  --- and it should be loud where it was written rather than becoming a file that
  --- quietly stops updating.
  function impl.encode(value)
    return textutils.serialise(value, { allow_repetitions = true })
  end

  --- Nil for anything unreadable, including a partial write.
  ---
  --- `unserialise` already answers nil rather than raising for malformed input,
  --- but not for every input: a file truncated mid-table can produce a Lua
  --- fragment that parses into something that is not a table at all. The pcall
  --- and the type check together mean a caller gets nil for every kind of
  --- damage, which is the only answer any of them act on.
  function impl.decode(text)
    if type(text) ~= "string" or text == "" then
      return nil
    end
    local ok, value = pcall(textutils.unserialise, text)
    if not ok then
      return nil
    end
    return value
  end

  return serialise.check(impl)
end

return adapter
