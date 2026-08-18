--- Pixel content. Canvas is for imagery, never for application chrome.

local canvas = require("ui.draw.canvas")
local runtime = require("ui.core.runtime")
local sprite = require("ui.draw.sprite")

local function measurePixels(width, height)
  return math.ceil((width or 0) / 2), math.ceil((height or 0) / 3)
end

--- Keep the pixel storage between repaints. Rebuilding 80,000 table entries on
--- a wall monitor bought nothing: Canvas painting starts from a clear surface,
--- so overwriting the existing rows has exactly the same semantics and avoids
--- making garbage collection part of an animation's frame time.
local function surfaceFor(node, background, palette)
  local width, height = node._w * 2, node._h * 3
  local pixels = node._canvas
  if not pixels or pixels.width ~= width or pixels.height ~= height then
    pixels = canvas.new(width, height, background, palette)
    node._canvas = pixels
  else
    pixels.palette = palette
    pixels:clear(background)
  end
  return pixels
end

local function paintCanvas(node, frame, surface)
  if node._w <= 0 or node._h <= 0 then
    return
  end

  local background = node.Background or surface
  local palette = node.Palette or (node._root and node._root.palette)
  local pixels = surfaceFor(node, background, palette)
  if node.Image then
    pixels:image(node.Image, node.PixelX or 1, node.PixelY or 1)
  end
  if node.Draw then
    node.Draw(pixels, node)
  end
  pixels:paint(frame, node._x, node._y, node._w, node._h, palette)
end

--- A layout region exposed to a pure drawing callback.
---
--- `Draw` is called only when this node repaints, not once per host event. Put
--- changing inputs in reactive properties on the node and replace them through
--- bindings; the callback then reads the current property values.
runtime.define({
  kind = "Canvas",
  layout = { PixelWidth = true, PixelHeight = true, Image = true },
  measure = function(node)
    if sprite.is(node.Image) then
      return measurePixels(node.Image.width, node.Image.height)
    end
    return measurePixels(node.PixelWidth, node.PixelHeight)
  end,
  paint = paintCanvas,
})

--- The common case: an immutable sprite laid out at its intrinsic cell size.
runtime.define({
  kind = "Sprite",
  layout = { Sprite = true },
  measure = function(node)
    if not sprite.is(node.Sprite) then
      return 0, 0
    end
    return measurePixels(node.Sprite.width, node.Sprite.height)
  end,
  paint = function(node, frame, surface)
    if node._w <= 0 or node._h <= 0 or not sprite.is(node.Sprite) then
      return
    end
    local palette = node.Palette or (node._root and node._root.palette)
    local pixels = surfaceFor(node, node.Background or surface, palette)
    pixels:sprite(node.Sprite, node.PixelX or 1, node.PixelY or 1, node.Remap)
    pixels:paint(frame, node._x, node._y, node._w, node._h, palette)
  end,
})
