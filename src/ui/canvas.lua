--- A pure 2x3 subpixel canvas which paints into `ui/buffer`.
---
--- ComputerCraft's bytes 128..159 encode five bits of a six-pixel cell. The
--- sixth pixel is represented by the background colour; swapping foreground
--- and background supplies the other 32 patterns. Each terminal cell can still
--- hold only two colours, so a six-pixel block using more is reduced locally to
--- its two most frequent colours before it is encoded.
---
--- Coordinates in this module are pixels, starting at 1. A Canvas component is
--- still laid out in terminal cells; its pixel surface is exactly twice as wide
--- and three times as tall as the box the solver gives it.

local sprite = require("ui.sprite")

local canvas = {}
local Canvas = {}
Canvas.__index = Canvas

local HEX = "0123456789abcdef"

local function colour(value, label, level)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 15 then
    error(("canvas: %s must be a palette index from 0 to 15"):format(label), (level or 1) + 1)
  end
  return value
end

local function dimension(value, label, level)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    error(("canvas: %s must be a non-negative integer"):format(label), (level or 1) + 1)
  end
  return value
end

local function packedDistance(a, b)
  local ar, ag, ab = math.floor(a / 65536) % 256, math.floor(a / 256) % 256, a % 256
  local br, bg, bb = math.floor(b / 65536) % 256, math.floor(b / 256) % 256, b % 256
  local dr, dg, db = ar - br, ag - bg, ab - bb
  return dr * dr + dg * dg + db * db
end

--- Reduce one 2x3 block to two colours.
---
--- Frequency wins because preserving the largest areas preserves edges. Ties
--- use first appearance in reading order, so the same image always encodes to
--- the same bytes. If a palette is available, discarded colours go to the
--- nearer survivor; without RGB information they go to the dominant one.
local function reduce(pixels, palette)
  local byColour, used = {}, {}
  for index = 1, 6 do
    local value = pixels[index]
    local entry = byColour[value]
    if entry then
      entry.count = entry.count + 1
    else
      entry = { value = value, count = 1, first = index }
      byColour[value] = entry
      used[#used + 1] = entry
    end
  end

  table.sort(used, function(a, b)
    return a.count > b.count or (a.count == b.count and a.first < b.first)
  end)

  local first = used[1].value
  local second = used[2] and used[2].value or first
  if #used <= 2 then
    return pixels, first, second
  end

  local mapped = {}
  for index = 1, 6 do
    local value = pixels[index]
    if value == first or value == second then
      mapped[index] = value
    elseif palette and palette[value] and palette[first] and palette[second] then
      local toFirst = packedDistance(palette[value], palette[first])
      local toSecond = packedDistance(palette[value], palette[second])
      mapped[index] = toSecond < toFirst and second or first
    else
      mapped[index] = first
    end
  end
  return mapped, first, second
end

local function encodeTwo(a, b, c, d, e, f, first, second)
  if not second then
    local digit = HEX:sub(first + 1, first + 1)
    return " ", digit, digit
  end

  local background = f
  local foreground = first == background and second or first
  local code = 128
  if a ~= background then
    code = code + 1
  end
  if b ~= background then
    code = code + 2
  end
  if c ~= background then
    code = code + 4
  end
  if d ~= background then
    code = code + 8
  end
  if e ~= background then
    code = code + 16
  end
  return string.char(code),
    HEX:sub(foreground + 1, foreground + 1),
    HEX:sub(background + 1, background + 1)
end

--- The hot path takes six locals instead of a table.
---
--- Most authored art obeys the hardware limit and uses no more than two
--- colours per cell. Detect that without allocating anything; only the crowded
--- case pays for frequency tables and sorting. A wall-sized canvas contains
--- 13,284 cells, so one short-lived table per ordinary cell was most of the
--- frame before this split existed.
local function encode(a, b, c, d, e, f, palette)
  local first, second = a, nil
  local crowded = false
  if b ~= first then
    second = b
  end
  if c ~= first then
    if second == nil then
      second = c
    elseif c ~= second then
      crowded = true
    end
  end
  if d ~= first then
    if second == nil then
      second = d
    elseif d ~= second then
      crowded = true
    end
  end
  if e ~= first then
    if second == nil then
      second = e
    elseif e ~= second then
      crowded = true
    end
  end
  if f ~= first then
    if second == nil then
      second = f
    elseif f ~= second then
      crowded = true
    end
  end

  if not crowded then
    return encodeTwo(a, b, c, d, e, f, first, second)
  end

  local reduced
  reduced, first, second = reduce({ a, b, c, d, e, f }, palette)
  if first == second then
    local digit = HEX:sub(first + 1, first + 1)
    return " ", digit, digit
  end
  return encodeTwo(
    reduced[1],
    reduced[2],
    reduced[3],
    reduced[4],
    reduced[5],
    reduced[6],
    first,
    second
  )
end

--- Encode six row-major pixels as one character and its blit colours.
function canvas.encodeCell(pixels, palette)
  if type(pixels) ~= "table" or #pixels ~= 6 then
    error("canvas: encodeCell needs exactly six pixels", 2)
  end
  for index = 1, 6 do
    colour(pixels[index], "pixel " .. index, 2)
  end
  return encode(pixels[1], pixels[2], pixels[3], pixels[4], pixels[5], pixels[6], palette)
end

function canvas.new(width, height, background, palette)
  width = dimension(width, "width", 2)
  height = dimension(height, "height", 2)
  background = colour(background == nil and 15 or background, "background", 2)

  local self = setmetatable({
    width = width,
    height = height,
    background = background,
    palette = palette,
    pixels = {},
  }, Canvas)
  self:clear(background)
  return self
end

function Canvas:size()
  return self.width, self.height
end

function Canvas:clear(value)
  value = colour(value == nil and self.background or value, "colour", 2)
  self.background = value
  for y = 1, self.height do
    local row = self.pixels[y] or {}
    for x = 1, self.width do
      row[x] = value
    end
    self.pixels[y] = row
  end
  return self
end

function Canvas:setPixel(x, y, value)
  value = colour(value, "colour", 2)
  x, y = math.floor(x), math.floor(y)
  if x >= 1 and x <= self.width and y >= 1 and y <= self.height then
    self.pixels[y][x] = value
  end
  return self
end

function Canvas:getPixel(x, y)
  local row = self.pixels[y]
  if not row or x < 1 or x > self.width then
    return nil
  end
  return row[x]
end

--- Bresenham line, inclusive at both ends.
function Canvas:line(x1, y1, x2, y2, value)
  value = colour(value, "colour", 2)
  x1, y1, x2, y2 = math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2)
  local dx, sx = math.abs(x2 - x1), x1 < x2 and 1 or -1
  local dy, sy = -math.abs(y2 - y1), y1 < y2 and 1 or -1
  local err = dx + dy

  while true do
    self:setPixel(x1, y1, value)
    if x1 == x2 and y1 == y2 then
      break
    end
    local twice = 2 * err
    if twice >= dy then
      err = err + dy
      x1 = x1 + sx
    end
    if twice <= dx then
      err = err + dx
      y1 = y1 + sy
    end
  end
  return self
end

--- Rectangle by origin and size. `filled` defaults to false.
function Canvas:rect(x, y, width, height, value, filled)
  width = dimension(width, "rectangle width", 2)
  height = dimension(height, "rectangle height", 2)
  value = colour(value, "colour", 2)
  x, y = math.floor(x), math.floor(y)
  if width == 0 or height == 0 then
    return self
  end

  if filled then
    for row = y, y + height - 1 do
      for column = x, x + width - 1 do
        self:setPixel(column, row, value)
      end
    end
  else
    self:line(x, y, x + width - 1, y, value)
    self:line(x, y + height - 1, x + width - 1, y + height - 1, value)
    self:line(x, y, x, y + height - 1, value)
    self:line(x + width - 1, y, x + width - 1, y + height - 1, value)
  end
  return self
end

--- Midpoint circle. A filled circle writes horizontal spans between mirrors.
function Canvas:circle(cx, cy, radius, value, filled)
  radius = dimension(radius, "radius", 2)
  value = colour(value, "colour", 2)
  cx, cy = math.floor(cx), math.floor(cy)

  local function span(x1, x2, y)
    for x = x1, x2 do
      self:setPixel(x, y, value)
    end
  end

  local x, y, decision = radius, 0, 1 - radius
  while y <= x do
    if filled then
      span(cx - x, cx + x, cy + y)
      span(cx - x, cx + x, cy - y)
      span(cx - y, cx + y, cy + x)
      span(cx - y, cx + y, cy - x)
    else
      self:setPixel(cx + x, cy + y, value)
      self:setPixel(cx + y, cy + x, value)
      self:setPixel(cx - y, cy + x, value)
      self:setPixel(cx - x, cy + y, value)
      self:setPixel(cx - x, cy - y, value)
      self:setPixel(cx - y, cy - x, value)
      self:setPixel(cx + y, cy - x, value)
      self:setPixel(cx + x, cy - y, value)
    end
    y = y + 1
    if decision <= 0 then
      decision = decision + 2 * y + 1
    else
      x = x - 1
      decision = decision + 2 * (y - x) + 1
    end
  end
  return self
end

--- Draw a sprite, optionally replacing palette indices through `remap`.
function Canvas:sprite(asset, x, y, remap)
  if not sprite.is(asset) then
    error("canvas: sprite expected an asset from ui.sprite", 2)
  end
  x, y = math.floor(x or 1), math.floor(y or 1)
  for sy = 1, asset.height do
    for sx = 1, asset.width do
      local value = sprite.get(asset, sx, sy)
      if value ~= nil then
        value = remap and remap[value] or value
        self:setPixel(x + sx - 1, y + sy - 1, value)
      end
    end
  end
  return self
end

--- Draw a numeric row image. Nil pixels are transparent.
function Canvas:image(rows, x, y)
  if sprite.is(rows) then
    return self:sprite(rows, x, y)
  end
  if type(rows) ~= "table" then
    error("canvas: image expected rows of palette indices", 2)
  end
  x, y = math.floor(x or 1), math.floor(y or 1)
  for iy, row in ipairs(rows) do
    if type(row) ~= "table" then
      error(("canvas: image row %d is not a table"):format(iy), 2)
    end
    for ix, value in pairs(row) do
      if type(ix) == "number" and value ~= nil then
        self:setPixel(x + ix - 1, y + iy - 1, value)
      end
    end
  end
  return self
end

--- Encode the canvas as `{ text, fg, bg }` rows.
function Canvas:rows(cellWidth, cellHeight, palette)
  cellWidth = dimension(cellWidth or math.ceil(self.width / 2), "cell width", 2)
  cellHeight = dimension(cellHeight or math.ceil(self.height / 3), "cell height", 2)
  palette = palette or self.palette

  local out = {}
  for cellY = 1, cellHeight do
    local text, fg, bg = {}, {}, {}
    local top = (cellY - 1) * 3 + 1
    local firstRow, secondRow, thirdRow =
      self.pixels[top], self.pixels[top + 1], self.pixels[top + 2]
    for cellX = 1, cellWidth do
      local left = (cellX - 1) * 2 + 1
      local right = left + 1
      text[cellX], fg[cellX], bg[cellX] = encode(
        (firstRow and firstRow[left]) or self.background,
        (firstRow and firstRow[right]) or self.background,
        (secondRow and secondRow[left]) or self.background,
        (secondRow and secondRow[right]) or self.background,
        (thirdRow and thirdRow[left]) or self.background,
        (thirdRow and thirdRow[right]) or self.background,
        palette
      )
    end
    out[cellY] = { text = table.concat(text), fg = table.concat(fg), bg = table.concat(bg) }
  end
  return out
end

--- Paint into a cell buffer, one batched write per terminal row.
function Canvas:paint(frame, x, y, cellWidth, cellHeight, palette)
  local rows = self:rows(cellWidth, cellHeight, palette)
  for index, row in ipairs(rows) do
    frame:blit(x, y + index - 1, row.text, row.fg, row.bg)
  end
  return self
end

return canvas
