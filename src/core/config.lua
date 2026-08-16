--- Table persistence with defaults.
---
--- Loading always layers the saved file over a defaults table, so adding a new
--- option in code never breaks a machine that already has a config file.

local config = {}

--- Read `path`, layered over `defaults`. Always returns a usable table.
function config.load(path, defaults)
  local result = {}
  for key, value in pairs(defaults) do
    result[key] = value
  end

  local handle = fs.exists(path) and fs.open(path, "r")
  if handle then
    local ok, saved = pcall(textutils.unserialise, handle.readAll())
    handle.close()
    if ok and type(saved) == "table" then
      for key, value in pairs(saved) do
        result[key] = value
      end
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

  local handle = fs.open(path, "w")
  if not handle then
    error("could not write " .. path, 0)
  end
  handle.write(textutils.serialise(tbl))
  handle.close()
end

return config
