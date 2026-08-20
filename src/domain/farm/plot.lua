--- The order a farm is walked in, and where the turtle is up to.
---
--- A mine is worked once and finished. A farm is never finished - it is walked,
--- and then walked again, forever - so the two interesting facts are the *order*
--- and the *resume point*, and both are arithmetic. Keeping them here means a
--- farm's movement can be checked without a turtle, and means the row order is
--- stated once rather than re-derived in every job that walks a rectangle.
---
--- ## Serpentine, not raster
---
--- Row 0 runs one way and row 1 runs back, so the turtle never traverses a whole
--- row without working. A raster walk - always left to right, return to the
--- start - costs an extra `width` of movement per row, which on a 16x16 plot
--- walked every few minutes is most of the fuel the farm uses and all of the
--- time it spends not farming.
---
--- ## The index wraps, and that is the whole loop
---
--- There is no "done". `next` returns to 0 after the last cell, so a farm's run
--- loop is the same shape as a mine's - walk to the cell for the current index,
--- work it, advance - and the only difference is that the index comes back
--- round. A job that special-cased "finished" would need a second state and a
--- decision about what to do in it; wrapping needs neither.

local plot = {}

--- How many cells a plot has.
function plot.cells(width, length)
  return math.max(0, math.floor(width or 0)) * math.max(0, math.floor(length or 0))
end

--- Where cell `index` is, as an offset from the plot's near-left corner.
---
--- Zero-based, returning `x` across and `z` along. Nil for an index outside the
--- plot, which is what a corrupt saved index looks like and is worth answering
--- rather than returning a plausible corner.
function plot.at(index, width, length)
  width = math.floor(width or 0)
  length = math.floor(length or 0)
  if index == nil or index < 0 or index >= plot.cells(width, length) then
    return nil
  end

  local row = math.floor(index / width)
  local column = index % width

  -- The serpentine. Odd rows run backwards, so the end of one row is the start
  -- of the next and the turtle never walks a row it has already worked.
  if row % 2 == 1 then
    column = width - column - 1
  end

  return column, row
end

--- The next cell, wrapping at the end.
---
--- A farm has no last cell. Wrapping here rather than in the job is what lets
--- the run loop have one branch instead of two.
function plot.next(index, width, length)
  local total = plot.cells(width, length)
  if total == 0 then
    return 0
  end
  local moved = (index or 0) + 1
  if moved >= total then
    return 0
  end
  return moved
end

--- Is this index the start of a fresh sweep?
---
--- What a job checks to decide whether a pass has completed - which is when it
--- is worth reporting a count, and when it is worth waiting for things to grow
--- rather than immediately walking a field that was just harvested.
function plot.wrapped(previous, current)
  return current == 0 and (previous or 0) ~= 0
end

--- A saved index made safe.
---
--- A plot that was resized while a turtle was away leaves an index past the end,
--- and a farm that trusted it would walk to a cell outside its own field and
--- start harvesting somebody's build. Clamping to zero costs one wasted sweep.
function plot.resume(index, width, length)
  local total = plot.cells(width, length)
  index = math.floor(tonumber(index) or 0)
  if index < 0 or index >= total then
    return 0
  end
  return index
end

return plot
