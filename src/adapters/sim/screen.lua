--- Screen port that records instead of drawing.
---
--- This is the thing that makes a renderer testable. It keeps a real cell grid,
--- so a spec can ask what is at column 12 of row 3 and get the character that
--- would be on the monitor; and it keeps a log of every call it received, so a
--- spec can assert that presenting an unchanged frame cost nothing at all.
---
--- Both halves matter and they check different things. The grid proves the
--- picture is right. The call log proves it was arrived at cheaply - and
--- "cheaply" is the entire premise of docs/ui-framework.md, so it needs to be a
--- number a test can fail on rather than a claim in a document.
---
--- Deliberately strict about the two things the real terminal is silently
--- forgiving of. A blit whose colour strings are not the same length as its text
--- raises here, exactly as CC does. A blit that runs off the right-hand edge is
--- clipped here and does NOT raise, exactly as CC does - which means a renderer
--- bug that writes past the edge shows up as missing cells in the grid rather
--- than as an error, which is what it would look like in game.

local screen = require("ports.screen")

local adapter = {}

--- Blit's colour alphabet, index 0..15. `colors.toBlit` produces these; the
--- recorder needs its own copy because it must run with no CC globals at all.
adapter.HEX = "0123456789abcdef"

local function hex(colour)
  return adapter.HEX:sub((colour or 0) + 1, (colour or 0) + 1)
end

--- A recording screen `width` by `height`.
---
--- Starts filled with spaces on black, which is what a CC terminal shows after
--- `term.clear()` - not empty. A grid initialised to nil would let a renderer
--- that never painted a region look identical to one that painted it correctly.
function adapter.new(width, height)
  width = width or 51
  height = height or 19

  local self = {
    width = width,
    height = height,
    calls = {}, -- every port call, in order
    blits = 0, -- how many blit calls, the number the budget is written in
    cells = {}, -- [y][x] = { char, fg, bg }
    palette = {},
    colour = true,
    cursor = { visible = false, x = 1, y = 1 },
  }

  local function reset(bg)
    local background = hex(bg or 15)
    for y = 1, height do
      local row = {}
      for x = 1, width do
        row[x] = { char = " ", fg = "0", bg = background }
      end
      self.cells[y] = row
    end
  end

  reset(15)

  local impl = {}

  function impl.size()
    return self.width, self.height
  end

  function impl.blit(x, y, text, fg, bg)
    if #fg ~= #text or #bg ~= #text then
      error(("blit at %d,%d: text is %d long, fg %d, bg %d"):format(x, y, #text, #fg, #bg), 2)
    end
    self.calls[#self.calls + 1] = { kind = "blit", x = x, y = y, text = text, fg = fg, bg = bg }
    self.blits = self.blits + 1

    local row = self.cells[y]
    if not row then
      return -- off-screen vertically; CC drops it silently and so do we
    end
    for index = 1, #text do
      local column = x + index - 1
      if column >= 1 and column <= self.width then
        row[column] = {
          char = text:sub(index, index),
          fg = fg:sub(index, index),
          bg = bg:sub(index, index),
        }
      end
    end
  end

  function impl.clear(bg)
    self.calls[#self.calls + 1] = { kind = "clear", bg = bg }
    reset(bg)
  end

  function impl.isColour()
    return self.colour
  end

  function impl.setPalette(index, r, g, b)
    self.calls[#self.calls + 1] = { kind = "palette", index = index }
    self.palette[index] = { r, g, b }
  end

  function impl.setCursor(visible, x, y, colour)
    self.calls[#self.calls + 1] = { kind = "cursor", visible = visible }
    self.cursor = { visible = visible and true or false, x = x, y = y, colour = colour }
  end

  self.port = screen.check(impl)

  --- Character at a cell, for asserting the picture.
  function self.charAt(x, y)
    local cell = self.cells[y] and self.cells[y][x]
    return cell and cell.char
  end

  --- Colours at a cell, as blit hex digits.
  function self.colourAt(x, y)
    local cell = self.cells[y] and self.cells[y][x]
    if not cell then
      return nil
    end
    return cell.fg, cell.bg
  end

  --- A whole row as a plain string, for asserting a line of text in one go.
  function self.rowText(y)
    local row = self.cells[y]
    if not row then
      return nil
    end
    local out = {}
    for x = 1, self.width do
      out[x] = row[x].char
    end
    return table.concat(out)
  end

  --- Forget the call log without touching the picture.
  ---
  --- The distinction is the whole point: a spec paints a first frame, resets the
  --- log, paints an identical second frame, and asserts zero calls. Clearing the
  --- grid as well would make that test pass for the wrong reason.
  function self.forget()
    self.calls = {}
    self.blits = 0
  end

  return self
end

return adapter
