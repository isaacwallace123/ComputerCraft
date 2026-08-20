--- Immutable, indexed-colour sprite data for the 2x3 canvas.
---
--- A sprite is deliberately just rows of hexadecimal palette indices. `.` is
--- transparent:
---
---   sprite.new({
---     ".11.",
---     "1221",
---     ".11.",
---   })
---
--- Keeping the source representation this small matters in ComputerCraft. Art
--- can be reviewed in Git, loaded with `require`, and drawn without a decoder,
--- a filesystem read, or a dependency on one of CC's image formats. Validation
--- happens once at construction, where a crooked row is still easy to find.

local sprite = {}

local function fail(message, level)
  error("sprite: " .. message, (level or 1) + 1)
end

--- Build a sprite from equal-width strings of `0`..`f` and `.`.
---
--- The returned rows are normalised to lowercase. Callers should treat the
--- result as immutable; replacing it rather than mutating it is also what lets
--- a reactive `Sprite` property know the picture changed.
function sprite.new(rows)
  if type(rows) ~= "table" or #rows == 0 then
    fail("expected at least one row", 2)
  end

  local width
  local clean = {}
  for y, row in ipairs(rows) do
    if type(row) ~= "string" then
      fail(("row %d is not a string"):format(y), 2)
    end
    row = row:lower()
    width = width or #row
    if width == 0 then
      fail("rows may not be empty", 2)
    end
    if #row ~= width then
      fail(("row %d is %d pixels wide; expected %d"):format(y, #row, width), 2)
    end
    local bad = row:find("[^0-9a-f.]", 1)
    if bad then
      fail(("row %d has invalid pixel %q at column %d"):format(y, row:sub(bad, bad), bad), 2)
    end
    clean[y] = row
  end

  return {
    _sprite = true,
    width = width,
    height = #clean,
    rows = clean,
  }
end

function sprite.is(value)
  return type(value) == "table" and value._sprite == true
end

--- Read a palette index, or nil for transparency/outside the sprite.
function sprite.get(value, x, y)
  if not sprite.is(value) then
    fail("expected a sprite", 2)
  end
  local row = value.rows[y]
  if not row or x < 1 or x > value.width then
    return nil
  end
  local pixel = row:sub(x, x)
  if pixel == "." then
    return nil
  end
  return tonumber(pixel, 16)
end

return sprite
