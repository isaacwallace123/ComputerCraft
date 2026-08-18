--- Double-buffered cell grid, and the diff that turns it into terminal calls.
---
--- Everything above this paints without knowing what is already on screen.
--- `present` works out the difference and emits the smallest useful set of blit
--- runs that closes it. That inversion is the whole framework's premise: a
--- component that had to know what it last drew could never be composed, and a
--- repaint that redraws everything can never animate, because 164x81 cells of
--- terminal traffic will not fit in a tick.
---
--- ## Rows are three strings, not a grid of cell tables
---
--- Each row holds `text`, `fg`, and `bg` - three equal-length strings, the exact
--- three arguments `term.blit` takes. Three consequences, all of them the reason
--- for the choice:
---
---   * Comparing a row against the front buffer is three string equality tests,
---     which is a length check and a memcmp in C rather than 164 iterations of
---     interpreted Lua. An idle screen has to cost nothing, and this is what
---     makes "nothing" literal.
---   * Painting a run is three sub/concat splices - again C - instead of a Lua
---     loop storing cell by cell. A full-width row costs one splice, so a
---     full-screen repaint is 81 of them rather than 13,284 table stores.
---   * The buffer converts nothing at present time. What it hands the screen
---     port is the substring it was already holding.
---
--- The cost is `set`, which rewrites a whole row to change one cell. Cell-at-a-
--- time painting is therefore the slow path here, deliberately: it is what the
--- 2x3 canvas layer will want, and when that arrives it should build a row and
--- hand it over through `row`, not call `set` three hundred times.
---
--- ## Why a changed row is one blit, not one blit per changed run
---
--- The obvious diff finds every contiguous changed run in a row and emits one
--- call each, skipping the identical stretches between them. That is the wrong
--- trade for this hardware. A blit costs a `setCursorPos` and a call into the
--- game; the characters inside it cost a memcpy. Splitting a row into three runs
--- to avoid rewriting eight unchanged characters buys back eight bytes and pays
--- four extra calls into the game for them.
---
--- So a changed row is emitted as a single run spanning its first changed cell
--- to its last. A one-character change is a one-character run; a row where only
--- the two ends moved rewrites the middle, and is still cheaper than the
--- alternative. The useful property falls out for free: a frame emits at most
--- one call per row, whatever changed.
---
--- ## Rows are only examined if something wrote to them
---
--- A dirty flag per row. Not an optimisation of the diff - the diff still runs,
--- and a row repainted with identical content still emits nothing - but an
--- optimisation of the walk. A dashboard updating one status line must not pay
--- to compare eighty rows nobody touched.

local buffer = {}

--- Blit's colour alphabet. Index 0 is white and 15 is black, matching CC's own
--- ordering, so a hex digit here means the same thing it means inside any
--- `term.blit` string anywhere else.
buffer.HEX = "0123456789abcdef"

local HEX = buffer.HEX

local function hex(index)
  local digit = HEX:sub((index or 0) + 1, (index or 0) + 1)
  return digit ~= "" and digit or "0"
end

buffer.hex = hex

local function blankRow(width, fg, bg)
  return {
    text = string.rep(" ", width),
    fg = string.rep(hex(fg), width),
    bg = string.rep(hex(bg), width),
  }
end

--- A front-buffer row that cannot match any real row, so the next present
--- repaints it unconditionally. Empty strings rather than a flag, because the
--- comparison in `present` then needs no special case at all: an empty string
--- differs from a 164-character one on the first byte, and `byte` past the end
--- of a string is nil.
local function unknownRow()
  return { text = "", fg = "", bg = "" }
end

--- Clip a run to the row, returning where to write and which slice of the run
--- survives. Returns nil when none of it does.
---
--- Off-screen writes are ordinary rather than exceptional here: a scrolled list,
--- a label wider than its column, a component laid out against the edge. The
--- real terminal clips silently and so does this, or every caller would need
--- bounds arithmetic the buffer is better placed to do once.
local function clip(x, length, width)
  local from = 1
  if x < 1 then
    from = 2 - x
    x = 1
  end
  local take = math.min(length - from + 1, width - x + 1)
  if take <= 0 then
    return nil
  end
  return x, from, from + take - 1
end

local function splice(row, x, part)
  return row:sub(1, x - 1) .. part .. row:sub(x + #part)
end

local Buffer = {}
Buffer.__index = Buffer

--- A buffer sized to `screen`, or to an explicit width and height.
---
--- Starts with the front buffer unknown, so the first present repaints
--- everything. It has to: whatever the terminal was showing before this buffer
--- existed is not something the buffer can see, and assuming a blank screen
--- would leave the previous program's output stranded in every cell that
--- nothing happens to overwrite.
function buffer.new(screen, width, height)
  local w, h = width, height
  if not w or not h then
    w, h = screen.size()
  end

  local self = setmetatable({
    screen = screen,
    width = w,
    height = h,
    back = {},
    front = {},
    dirty = {},
  }, Buffer)

  for y = 1, h do
    self.back[y] = blankRow(w, 0, 15)
    self.front[y] = unknownRow()
    self.dirty[y] = true
  end

  return self
end

function Buffer:size()
  return self.width, self.height
end

--- Re-read the screen size and rebuild, keeping whatever content still fits.
---
--- Content is kept because a resize normally arrives as a `term_resize` event
--- mid-frame, and discarding it would flash the screen blank on every monitor
--- scale change. The front buffer is dropped entirely, because a resized CC
--- terminal is cleared by the game and nothing the buffer believed about it is
--- true any more.
function Buffer:resize(width, height)
  local w, h = width, height
  if not w or not h then
    w, h = self.screen.size()
  end
  if w == self.width and h == self.height then
    return false
  end

  local back = {}
  for y = 1, h do
    local old = self.back[y]
    if not old then
      back[y] = blankRow(w, 0, 15)
    elseif w == self.width then
      back[y] = old
    elseif w < self.width then
      back[y] = { text = old.text:sub(1, w), fg = old.fg:sub(1, w), bg = old.bg:sub(1, w) }
    else
      local pad = w - self.width
      back[y] = {
        text = old.text .. string.rep(" ", pad),
        fg = old.fg .. string.rep("0", pad),
        bg = old.bg .. string.rep("f", pad),
      }
    end
  end

  self.width, self.height, self.back = w, h, back
  self.front, self.dirty = {}, {}
  self:invalidate()
  return true
end

--- Forget what the screen is showing, forcing a full repaint next present.
---
--- Call it after anything outside the buffer has written to the same surface: a
--- `term.clear` from a legacy page, a peripheral re-wrapped, a shell program
--- that ran and exited. The front buffer is a claim about the physical screen,
--- and a stale claim makes the diff skip exactly the rows that are wrong - which
--- shows up as a dashboard with somebody else's text baked into it.
function Buffer:invalidate()
  for y = 1, self.height do
    self.front[y] = unknownRow()
    self.dirty[y] = true
  end
end

--- Fill the whole back buffer with spaces.
---
--- Note this touches the back buffer only: clearing and presenting an already
--- blank screen emits nothing, which is the correct amount of work.
function Buffer:clear(fg, bg)
  for y = 1, self.height do
    self.back[y] = blankRow(self.width, fg, bg)
    self.dirty[y] = true
  end
end

--- A run with per-character colours. `fg` and `bg` are hex digit strings as long
--- as `text`. Every other paint call comes through here.
function Buffer:blit(x, y, text, fg, bg)
  if y < 1 or y > self.height or #text == 0 then
    return
  end
  if #fg ~= #text or #bg ~= #text then
    error(("blit at %d,%d: text %d, fg %d, bg %d"):format(x, y, #text, #fg, #bg), 2)
  end

  local at, from, to = clip(x, #text, self.width)
  if not at then
    return
  end

  local row = self.back[y]
  row.text = splice(row.text, at, text:sub(from, to))
  row.fg = splice(row.fg, at, fg:sub(from, to))
  row.bg = splice(row.bg, at, bg:sub(from, to))
  self.dirty[y] = true
end

--- A run in one foreground and one background colour. The common case by a wide
--- margin, and cheaper than `blit` because the colour strings are built once
--- with `rep` here rather than per character by the caller.
function Buffer:write(x, y, text, fg, bg)
  text = tostring(text)
  if #text == 0 then
    return
  end
  self:blit(x, y, text, string.rep(hex(fg), #text), string.rep(hex(bg), #text))
end

--- One cell. The slow path: a row is three strings, so changing one character
--- rewrites all three. Fine for a cursor or a corner glyph, wrong for painting
--- an image - build the row and use `row` for that.
function Buffer:set(x, y, char, fg, bg)
  self:write(x, y, tostring(char):sub(1, 1), fg, bg)
end

--- Replace a whole row from pre-built strings. The batch primitive the 2x3
--- canvas will want: one splice instead of one per pixel column.
function Buffer:row(y, text, fg, bg)
  self:blit(1, y, text, fg, bg)
end

--- A solid rectangle of one character.
function Buffer:fill(x, y, width, height, char, fg, bg)
  local run = string.rep(tostring(char or " "):sub(1, 1), math.max(0, width))
  for row = y, y + height - 1 do
    self:write(x, row, run, fg, bg)
  end
end

--- What the back buffer holds at a cell: the character, and the two colours as
--- palette indices. Shipped rather than kept in the specs because "what does the
--- framework think is at 12,3" is the first question asked when a layout looks
--- wrong, and the answer should not require a monitor.
function Buffer:get(x, y)
  local row = self.back[y]
  if not row or x < 1 or x > self.width then
    return nil
  end
  local fg = (HEX:find(row.fg:sub(x, x), 1, true) or 1) - 1
  local bg = (HEX:find(row.bg:sub(x, x), 1, true) or 1) - 1
  return row.text:sub(x, x), fg, bg
end

--- First and last cell at which two rows differ, or nil if they do not.
---
--- Both rows are the same length except when the front row is unknown, where the
--- missing bytes read as nil and so differ from the first cell onwards - which
--- is exactly the wanted answer, with no branch to express it.
local function span(back, front, width)
  local first = 1
  while
    first <= width
    and back.text:byte(first) == front.text:byte(first)
    and back.fg:byte(first) == front.fg:byte(first)
    and back.bg:byte(first) == front.bg:byte(first)
  do
    first = first + 1
  end
  if first > width then
    return nil
  end

  local last = width
  while
    last > first
    and back.text:byte(last) == front.text:byte(last)
    and back.fg:byte(last) == front.fg:byte(last)
    and back.bg:byte(last) == front.bg:byte(last)
  do
    last = last - 1
  end
  return first, last
end

--- Push the back buffer to the screen and swap. Returns how many blit calls it
--- took - the number docs/ui-framework.md writes its budget in, and the number
--- the specs assert on.
function Buffer:present()
  local screen = self.screen
  local back, front, dirty = self.back, self.front, self.dirty
  local width = self.width
  local blits = 0

  for y = 1, self.height do
    if dirty[y] then
      dirty[y] = false
      local b, f = back[y], front[y]
      -- Three string comparisons settle an unchanged row. This is the test an
      -- idle screen runs once per dirty row and then stops.
      if b.text ~= f.text or b.fg ~= f.fg or b.bg ~= f.bg then
        local first, last = span(b, f, width)
        if first then
          screen.blit(
            first,
            y,
            b.text:sub(first, last),
            b.fg:sub(first, last),
            b.bg:sub(first, last)
          )
          blits = blits + 1
        end
        -- The front row takes the back row's strings by reference. Strings are
        -- immutable in Lua and every paint call replaces rather than mutates
        -- them, so this is a copy in every sense that matters and costs none of
        -- what a copy would.
        front[y] = { text = b.text, fg = b.fg, bg = b.bg }
      end
    end
  end

  return blits
end

return buffer
