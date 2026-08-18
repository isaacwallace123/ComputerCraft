--- The 2x3 canvas, from individual pixels through the retained component.

local expect = require("support.expect")
local it = require("support.spec").it

local buffer = require("ui.render.buffer")
local canvas = require("ui.render.canvas")
local recorder = require("adapters.sim.screen")
local sprite = require("ui.render.sprite")
local ui = require("ui.init")

it("encodes all six subpixels and swaps colours through the sixth", function()
  local char, fg, bg = canvas.encodeCell({ 1, 0, 1, 0, 1, 0 })
  expect.equal(string.byte(char), 149, "bits 1, 3 and 5 are set")
  expect.equal(fg, "1", "the marked pixels are foreground")
  expect.equal(bg, "0", "the sixth pixel is background")

  char, fg, bg = canvas.encodeCell({ 0, 1, 0, 1, 0, 1 })
  expect.equal(string.byte(char), 149, "the complementary pattern uses the same glyph")
  expect.equal(fg, "0", "with foreground swapped")
  expect.equal(bg, "1", "and the sixth pixel still represented exactly")

  char, fg, bg = canvas.encodeCell({ 7, 7, 7, 7, 7, 7 })
  expect.equal(char, " ", "a solid block needs no semigraphic glyph")
  expect.equal(fg .. bg, "77", "both colours carry the solid slot")
end)

it("reduces a crowded cell to its two dominant colours deterministically", function()
  local char, fg, bg = canvas.encodeCell({ 1, 2, 3, 1, 2, 3 })
  expect.equal(string.byte(char), 146, "the tied third colour collapses to the first seen")
  expect.equal(fg, "2", "the second survivor remains foreground")
  expect.equal(bg, "1", "the dominant survivor is the background")

  local palette = {
    [1] = 0x000000,
    [2] = 0xFFFFFF,
    [3] = 0xEEEEEE,
  }
  char, fg, bg = canvas.encodeCell({ 1, 2, 3, 1, 2, 3 }, palette)
  expect.equal(string.byte(char), 137, "palette distance sends the third colour to white")
  expect.equal(fg .. bg, "12", "without changing the chosen pair")
end)

it("draws clipped lines, rectangles and circles in pixel coordinates", function()
  local pixels = canvas.new(9, 9, 15)
  pixels:line(-2, -2, 4, 4, 1)
  expect.equal(pixels:getPixel(1, 1), 1, "an off-canvas line enters cleanly")
  expect.equal(pixels:getPixel(4, 4), 1, "and includes its endpoint")
  expect.equal(pixels:getPixel(5, 5), 15, "without running past it")

  pixels:rect(2, 2, 5, 4, 2)
  expect.equal(pixels:getPixel(2, 2), 2, "rectangle top-left")
  expect.equal(pixels:getPixel(6, 5), 2, "rectangle bottom-right")
  expect.equal(pixels:getPixel(4, 3), 15, "an outline leaves its middle alone")

  pixels:circle(5, 5, 3, 3)
  expect.equal(pixels:getPixel(5, 2), 3, "circle top")
  expect.equal(pixels:getPixel(8, 5), 3, "circle right")
  expect.equal(pixels:getPixel(5, 8), 3, "circle bottom")
  expect.equal(pixels:getPixel(2, 5), 3, "circle left")
end)

it("sprites are reviewable indexed rows with transparency and remapping", function()
  local mark = sprite.new({
    ".1.",
    "121",
    ".1.",
  })
  expect.equal(mark.width, 3, "sprite width")
  expect.equal(mark.height, 3, "sprite height")
  expect.equal(sprite.get(mark, 1, 1), nil, "dot is transparent")
  expect.equal(sprite.get(mark, 2, 2), 2, "hex digits are palette indices")

  local pixels = canvas.new(5, 5, 9)
  pixels:sprite(mark, 2, 2, { [1] = 4, [2] = 5 })
  expect.equal(pixels:getPixel(2, 2), 9, "transparent pixels preserve the destination")
  expect.equal(pixels:getPixel(3, 2), 4, "a colour is remapped")
  expect.equal(pixels:getPixel(3, 3), 5, "independently of the next colour")

  local ok, err = pcall(function()
    sprite.new({ "11", "1" })
  end)
  expect.falsy(ok, "crooked source art is rejected")
  expect.contains(err, "row 2", "and identifies the row")
end)

it("encodes one batched buffer write per canvas row", function()
  local screen = recorder.new(4, 2)
  local frame = buffer.new(screen.port)
  local pixels = canvas.new(8, 6, 15)
  pixels:rect(1, 1, 8, 6, 1)
  pixels:paint(frame, 1, 1, 4, 2)
  local blits = frame:present()

  expect.equal(blits, 2, "the buffer emits one run per changed terminal row")
  expect.equal(#screen.calls, 2, "and the canvas did not write pixel by pixel")
  expect.equal(#screen.calls[1].text, 4, "the first row is one full-width run")

  screen.forget()
  pixels:paint(frame, 1, 1, 4, 2)
  expect.equal(frame:present(), 0, "an identical canvas is free after the diff")
end)

it("Canvas and Sprite participate in layout and targeted reactive repaint", function()
  local first = sprite.new({ "10", "01", "10" })
  local second = sprite.new({ "01", "10", "01" })
  local screen = recorder.new(4, 2)
  local scope = ui.scoped()
  local picture
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      picture = s:Value(first)
      return s:Column({
        Children = {
          s:Sprite({ Sprite = picture, Width = 1 }),
          s:Canvas({
            Width = 1,
            Height = 1,
            Draw = function(pixels)
              pixels:line(1, 1, 2, 3, 2)
            end,
          }),
        },
      })
    end,
  })

  root:render()
  expect.equal(string.byte(screen.charAt(1, 1)), 153, "the Sprite component paints its asset")
  expect.truthy(string.byte(screen.charAt(1, 2)) >= 128, "the Canvas callback paints subpixels")
  local retainedPixels = root.tree.Children[1]._canvas

  screen.forget()
  picture:set(second)
  local blits = root:render()
  expect.equal(blits, 1, "same-sized sprite replacement repaints only its cell")
  expect.equal(screen.calls[1].y, 1, "the unrelated Canvas row stays untouched")
  expect.equal(root.tree.Children[1]._canvas, retainedPixels, "pixel rows survive the repaint")
  root:destroy()
end)
