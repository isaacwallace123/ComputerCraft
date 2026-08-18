--- Port: the character grid.
---
--- This is the only thing in the framework that is allowed to touch `term`, and
--- the reason the renderer can be unit tested at all: swap in a recording
--- implementation and a layout bug becomes an assertion about cell contents
--- rather than a thing somebody has to fly out and look at.
---
--- ## Why `blit` carries its own position
---
--- CC's terminal has a cursor, and `term.blit` writes wherever that cursor
--- happens to be. Hidden ordering state like that is poison for a port: a
--- recorder cannot verify a call in isolation, two callers interleaving produce
--- a result neither asked for, and "one blit per changed run" stops being a
--- property you can count. So the port's unit of work is one positioned run,
--- `blit(x, y, text, fg, bg)`, and moving the cursor is the cc adapter's private
--- business. One port call is one visible operation, which is exactly what the
--- performance budget in docs/ui-framework.md counts.
---
--- ## Colours are palette indices, 0 to 15
---
--- Not `colors.white`, `colors.blue` and friends. Those are single-bit masks -
--- 1, 2, 4, up to 32768 - which is a shape that suits `redstone` and suits
--- nothing here: the palette is sixteen numbered slots, `term.blit` names them
--- with a hex digit, and every step between the two would otherwise be spent
--- converting a bitmask back into the index it was always standing in for.
---
--- So the framework's colour type is the index. `blit` takes its `fg` and `bg`
--- as strings of hex digits, one per character of `text`, which is exactly the
--- format `term.blit` consumes - the cc adapter converts nothing at all on the
--- hot path, and `ui/buffer` can compare a whole row's colours with one string
--- equality. `clear` and `setPalette` take a plain index. Converting an index to
--- the `colors.*` value CC's own palette call wants happens once, inside the cc
--- adapter, where it is the adapter's problem and nobody else's.
---
--- ## What is deliberately absent
---
--- No `write`, no cursor movement, no scrolling, no `setTextColor`. Everything
--- above this port paints into `ui/buffer` and presents; a second way to put
--- characters on the screen would immediately desynchronise the front buffer
--- from what is actually displayed, and the diff would then skip the very rows
--- that are wrong.

local contract = require("ports.contract")

local screen = {}

screen.NAME = "screen"

screen.METHODS = {
  "size", -- () -> width, height in cells
  "blit", -- (x, y, text, fg, bg) -> nil; fg/bg are hex strings as long as text
  "clear", -- (bg) -> nil; fills the whole surface with one palette index
  "isColour", -- () -> boolean; false means the palette renders as greyscale
  "setPalette", -- (index 0..15, r, g, b) -> nil; r/g/b are 0..1
  "setCursor", -- (visible, x, y, index) -> nil; the text caret, not a pointer
}

function screen.check(impl)
  return contract.check(screen.NAME, screen.METHODS, impl)
end

--- A screen that accepts everything and shows nothing, sized like a computer
--- terminal so layout code has plausible numbers to work with. A headless
--- machine - a server, a GPS host - runs against this rather than branching on
--- whether it has a display.
function screen.null(width, height)
  local impl = contract.null(screen.METHODS, { isColour = false })
  impl.size = function()
    return width or 51, height or 19
  end
  return impl
end

return screen
