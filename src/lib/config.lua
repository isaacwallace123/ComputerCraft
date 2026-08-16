--- Dead-simple table persistence.
--- Saves a Lua table to a file as text, loads it back, and fills in defaults
--- for any key the saved file is missing (so adding a new option later never
--- breaks an existing install).
local config = {}

--- Read `path`, layering it over `defaults`. Always returns a usable table.
function config.load(path, defaults)
  local result = {}
  for k, v in pairs(defaults) do
    result[k] = v
  end

  local handle = fs.exists(path) and fs.open(path, "r")
  if handle then
    local ok, saved = pcall(textutils.unserialise, handle.readAll())
    handle.close()
    if ok and type(saved) == "table" then
      for k, v in pairs(saved) do
        result[k] = v
      end
    end
  end

  return result
end

--- Write `tbl` to `path`.
function config.save(path, tbl)
  local handle = fs.open(path, "w")
  if not handle then
    error("could not write " .. path, 0)
  end
  handle.write(textutils.serialise(tbl))
  handle.close()
end

return config
