--- A column table over a reactive list.
---
--- This is the component the fleet dashboard is made of, and it is where the
--- framework's central claim has to survive contact with something real: ten
--- turtles reporting every two seconds, and only the cells that actually moved
--- costing anything.
---
--- ## Rows are built once, for a fixed number of slots
---
--- The obvious design rebuilds the row nodes whenever the list changes. That is
--- React's model and it is the one being avoided: rebuilding means every cell is
--- a new node, every node is dirty, and the whole table repaints on every
--- heartbeat whether or not anything changed.
---
--- Instead the table builds `Capacity` row slots once and never again. Each cell
--- is a `Computed` that reads the list and indexes into it, so slot 3 shows
--- whatever is third **now**. A device leaving the roster does not destroy a row,
--- it changes what four cells say. Slots past the end of the list render blank.
---
--- This is virtualisation, arrived at from the other direction: a fixed pool of
--- widgets over a changing list is the only shape that keeps a fine-grained
--- binding graph stable, and it happens to also be the shape that scrolls.
---
--- ## Capacity is given, not measured
---
--- The caller says how many rows there is room for. Deriving it from the box
--- would need the layout solved before the tree is built, which is backwards -
--- and a table that silently grew its node count when a monitor got taller would
--- be a memory leak with a plausible excuse. Phase 3 can offer a helper that
--- computes it from a known surface; the number stays explicit.
---
--- ## What a column is
---
---     { Title = "Fuel", Width = 7, Align = "right", Key = "fuel", Format = util.count }
---     { Title = "Status", Grow = 1, Value = function(row) return row.phase end,
---       Tone = function(row) return row.stuck and T.destructive or T.good end }
---     { Width = 10, Render = function(scope, row, surface) ... end }
---
--- `Key` reads a field; `Value` computes one; `Format` turns it into text; `Tone`
--- picks its colour from the row. All four are plain functions over a row, which
--- keeps a column definition data rather than code and means a screen can build
--- its columns from a loop.
---
--- A `Render` column produces something that is not text - the fuel meter is
--- one. It goes through the same column list as everything else rather than
--- through a separate "trailing" slot, and that is worth insisting on: the first
--- version had a separate slot, and the heading row therefore had one fewer
--- column than the data rows, so every heading sat two cells left of the values
--- underneath it. One list, one set of widths, one loop for both rows.

local runtime = require("ui.runtime")
local theme = require("ui.theme")

local T = theme.TOKENS

--- Pull one cell's text out of a row.
local function cellText(column, row)
  if row == nil then
    return ""
  end
  local value
  if column.Value then
    value = column.Value(row)
  elseif column.Key then
    value = row[column.Key]
  end
  if value == nil then
    return ""
  end
  if column.Format then
    return column.Format(value, row)
  end
  return tostring(value)
end

local function cellTone(column, row)
  if row == nil then
    return T.mutedFg
  end
  if column.Tone then
    local tone = column.Tone(row)
    if tone then
      return tone
    end
  end
  return column.Muted and T.mutedFg or T.foreground
end

runtime.compose("Table", function(scope, props)
  props = props or {}
  local columns = props.Columns or {}
  local rows = props.Rows
  local capacity = props.Capacity or 12
  local gap = props.Gap or 1

  local function rowAt(use, index)
    local list = use(rows)
    return list and list[index] or nil
  end

  --- The heading row, and the one-cell gutter every row starts with.
  ---
  --- The gutter is always there, selected or not, so that highlighting a row
  --- never changes a width. Same reasoning as the focus ring on a button: a
  --- selection that reflowed the table would be a selection that repainted it.
  local headings = { scope:Spacer({ Width = 1 }) }
  for _, column in ipairs(columns) do
    headings[#headings + 1] = scope:Muted({
      Text = (column.Title or ""):upper(),
      Width = column.Width,
      Grow = column.Grow,
      TextAlign = column.Align,
    })
  end

  local children = {
    scope:Row({ Gap = gap, Height = 1, Children = headings }),
    scope:Spacer({ Height = 1 }),
  }

  for slot = 1, capacity do
    local isSelected = scope:Computed(function(use)
      local chosen = props.Selected and use(props.Selected) or nil
      local row = rowAt(use, slot)
      if row == nil or chosen == nil then
        return false
      end
      return chosen == (props.Identity and props.Identity(row) or row)
    end)

    local surface = scope:Computed(function(use)
      return use(isSelected) and T.muted or nil
    end)

    local cells = {
      scope:Box({
        Width = 1,
        Background = scope:Computed(function(use)
          return use(isSelected) and T.accent or nil
        end),
      }),
    }

    for _, column in ipairs(columns) do
      if column.Render then
        cells[#cells + 1] = column.Render(scope, function(use)
          return rowAt(use, slot)
        end, surface, column)
      else
        cells[#cells + 1] = scope:Text({
          Width = column.Width,
          Grow = column.Grow,
          TextAlign = column.Align,
          Text = scope:Computed(function(use)
            return cellText(column, rowAt(use, slot))
          end),
          Color = scope:Computed(function(use)
            return cellTone(column, rowAt(use, slot))
          end),
        })
      end
    end

    children[#children + 1] = scope:Row({
      Gap = gap,
      Height = 1,
      Background = surface,
      Children = cells,
    })
  end

  return scope:Column({
    Grow = props.Grow,
    Children = children,
  })
end)

--- Exposed so a screen can reuse the cell rules without reaching into the
--- composite. Nothing in the framework requires it.
return {
  cellText = cellText,
  cellTone = cellTone,
}
