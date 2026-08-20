--- Table persistence with defaults.
---
--- Loading always layers the saved file over a defaults table, so adding a new
--- option in code never breaks a machine that already has a config file.

local config = {}

local function readTable(path)
  if not fs.exists(path) then
    return nil
  end
  local handle = fs.open(path, "r")
  if not handle then
    return nil
  end
  local ok, saved = pcall(textutils.unserialise, handle.readAll())
  handle.close()
  return ok and type(saved) == "table" and saved or nil
end

--- Read `path`, layered over `defaults`. Always returns a usable table.
function config.load(path, defaults)
  local result = {}
  for key, value in pairs(defaults) do
    result[key] = value
  end

  -- A completed `.tmp` is left behind only when power was lost after the old
  -- file was removed but before the rename. Recover it rather than silently
  -- returning defaults - especially important for `.nav`, where defaults would
  -- make a displaced turtle believe it was already home.
  local saved = readTable(path) or readTable(path .. ".tmp")
  if saved then
    for key, value in pairs(saved) do
      result[key] = value
    end
  end

  return result
end

--- Write `tbl` to `path`.
function config.save(path, tbl)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end

  -- Write and close the replacement completely before touching the live file.
  -- CC has no replace primitive, so a reboot may occur in the tiny delete/move
  -- window; config.load's `.tmp` fallback makes that window recoverable.
  local temporary = path .. ".tmp"
  if fs.exists(temporary) then
    fs.delete(temporary)
  end
  local handle = fs.open(temporary, "w")
  if not handle then
    error("could not write " .. temporary, 0)
  end

  -- Raising is deliberate and stays: unlike a log line, a config that did not
  -- save is something the caller has to know about - `.nav` silently failing to
  -- write is a turtle that believes it is somewhere it is not.
  --
  -- What is guarded is the *handle*. A full disk throws out of `handle.write`,
  -- and letting that escape before `close` leaked one of a small pool on every
  -- attempt, so a disk-full machine ran out of file handles as well. Close
  -- first, then raise with a sentence that names the real problem rather than
  -- the bare `Out of space` the filesystem gives.
  local wrote, reason = pcall(handle.write, textutils.serialise(tbl))
  pcall(handle.close)
  if not wrote then
    error("could not write " .. temporary .. ": " .. tostring(reason), 0)
  end

  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(temporary, path)
end

return config
