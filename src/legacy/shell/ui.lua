--- Drawing helpers.
---
--- Everything here talks to whatever terminal is currently redirected, so the
--- same code draws on a computer screen or on a wall of advanced monitors.
--- Nothing caches the screen size - a monitor is a different shape to a
--- computer, and `monitor.setTextScale` changes it at runtime.

local ui = {}

ui.theme = {
  bg = colors.black,
  fg = colors.white,
  dim = colors.gray,
  bar = colors.lightGray,
  good = colors.lime,
  warn = colors.yellow,
  bad = colors.red,
  accent = colors.cyan,
  headerBg = colors.gray,
  headerFg = colors.white,
}

function ui.size()
  return term.getSize()
end

function ui.clear(bg)
  term.setBackgroundColor(bg or ui.theme.bg)
  term.setTextColor(ui.theme.fg)
  term.clear()
  term.setCursorPos(1, 1)
end

--- Repaint without the blank frame in between.
---
--- Every dashboard redraw clears the screen and paints it again. On a computer
--- terminal that is invisible; on a monitor the two halves can reach the client
--- separately, and a wall that refreshes once a second visibly blinks.
---
--- A `window` buffers writes and only pushes them to its parent while visible,
--- so hiding it for the duration of a repaint collapses clear-then-paint into
--- one update. Visibility is restored to what it was rather than forced on: an
--- app drawing while unfocused must not put itself back on screen, which is
--- exactly the bug this would otherwise introduce.
---
--- Falls back to drawing directly when the current terminal is not a window,
--- which is the case for the physical terminal and for a redirected monitor.
function ui.frame(render)
  local current = term.current()
  if not current or not current.setVisible or not current.isVisible then
    return render()
  end
  if not current.isVisible() then
    return render()
  end

  current.setVisible(false)
  local ok, err = pcall(render)
  current.setVisible(true)
  if not ok then
    error(err, 0)
  end
end

--- Write at a position with explicit colours. The workhorse - everything else
--- is built on it.
function ui.text(x, y, text, fg, bg)
  local width, height = ui.size()
  if y < 1 or y > height or x > width then
    return
  end
  text = tostring(text)
  if x < 1 then
    text = text:sub(2 - x)
    x = 1
  end
  text = text:sub(1, math.max(0, width - x + 1))
  term.setCursorPos(x, y)
  term.setTextColor(fg or ui.theme.fg)
  term.setBackgroundColor(bg or ui.theme.bg)
  term.write(text)
end

function ui.center(y, text, fg, bg)
  local width = ui.size()
  text = tostring(text)
  ui.text(math.max(1, math.floor((width - #text) / 2) + 1), y, text, fg, bg)
end

--- Full-width filled row. Used for header and footer bars.
function ui.row(y, bg)
  local width = ui.size()
  ui.text(1, y, string.rep(" ", width), ui.theme.fg, bg or ui.theme.bg)
end

function ui.header(title, right)
  local width = ui.size()
  ui.row(1, ui.theme.headerBg)
  title = tostring(title or "")
  if right then
    right = tostring(right)
    local rightX = math.max(2, width - #right)
    ui.text(rightX, 1, right, ui.theme.headerFg, ui.theme.headerBg)
    ui.text(2, 1, ui.pad(title, math.max(0, rightX - 3)), ui.theme.headerFg, ui.theme.headerBg)
  else
    ui.text(2, 1, ui.pad(title, width - 1), ui.theme.headerFg, ui.theme.headerBg)
  end
end

function ui.footer(text)
  local _, height = ui.size()
  ui.row(height, ui.theme.headerBg)
  local width = ui.size()
  ui.text(2, height, ui.pad(text, width - 1), ui.theme.headerFg, ui.theme.headerBg)
end

--- Horizontal meter. `fraction` is 0..1; colour is chosen by how full it is,
--- so a nearly-empty fuel bar reads as red without the caller deciding that.
function ui.bar(x, y, width, fraction, fg)
  fraction = math.max(0, math.min(1, fraction or 0))
  local filled = math.floor(fraction * width + 0.5)

  if not fg then
    fg = ui.theme.good
    if fraction < 0.15 then
      fg = ui.theme.bad
    elseif fraction < 0.4 then
      fg = ui.theme.warn
    end
  end

  -- Coloured background on spaces, rather than a block glyph - renders the same
  -- on every font and both terminal types.
  ui.text(x, y, string.rep(" ", filled), ui.theme.fg, fg)
  if filled < width then
    ui.text(x + filled, y, string.rep(" ", width - filled), ui.theme.fg, ui.theme.dim)
  end
end

--- Truncate and pad `text` to exactly `width` characters.
---
--- This exists because Lua's string.format has no '*' dynamic-width specifier -
--- "%-*s" is a C printf feature that raises at runtime and is invisible to every
--- linter. Anywhere a column width is computed rather than literal, use this.
function ui.pad(text, width, align)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if #text > width then
    return text:sub(1, width)
  end

  local slack = width - #text
  if align == "right" then
    return string.rep(" ", slack) .. text
  end
  if align == "center" then
    local left = math.floor(slack / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", slack - left)
  end
  return text .. string.rep(" ", slack)
end

--- Box with an optional title in the top edge.
function ui.panel(x, y, width, height, title)
  local horizontal = string.rep("-", math.max(0, width - 2))
  ui.text(x, y, "+" .. horizontal .. "+", ui.theme.dim)
  for row = 1, height - 2 do
    ui.text(x, y + row, "|", ui.theme.dim)
    ui.text(x + width - 1, y + row, "|", ui.theme.dim)
  end
  ui.text(x, y + height - 1, "+" .. horizontal .. "+", ui.theme.dim)

  if title then
    ui.text(x + 2, y, " " .. title .. " ", ui.theme.fg)
  end
end

--- Column table with a header.
---
--- `specs` is a list of { title, width, align }. Columns are dropped from the
--- right when they do not fit, so the same table degrades gracefully from a
--- monitor wall down to a pocket computer without a pile of width branches at
--- the call site.
---
--- `rows` is a list of { color = <row default>, cells = { "text", { text=, color= } } }.
--- Returns how many rows were drawn.
function ui.table(x, y, width, specs, rows, maxRows)
  local columns = {}
  local cursor = x

  for index, spec in ipairs(specs) do
    if cursor + spec.width - 1 > x + width - 1 then
      break
    end
    columns[#columns + 1] = { spec = spec, x = cursor, index = index }
    cursor = cursor + spec.width + 1
  end

  for _, column in ipairs(columns) do
    ui.text(
      column.x,
      y,
      ui.pad(column.spec.title, column.spec.width, column.spec.align),
      ui.theme.dim
    )
  end

  local drawn = 0
  for rowIndex, row in ipairs(rows) do
    if maxRows and drawn >= maxRows then
      break
    end

    for _, column in ipairs(columns) do
      local cell = row.cells[column.index]
      local text, color = cell, row.color or ui.theme.fg
      if type(cell) == "table" then
        text, color = cell.text, cell.color or color
      end
      ui.text(column.x, y + rowIndex, ui.pad(text, column.spec.width, column.spec.align), color)
    end

    drawn = drawn + 1
  end

  return drawn
end

--- Arrow-key menu. Optional help lines explain the page without becoming
--- selectable actions. Returns the chosen index, or nil if the user pressed Q.
function ui.menu(title, items, help)
  if type(help) == "string" then
    help = { help }
  elseif type(help) ~= "table" then
    help = {}
  end

  local selected = 1
  local scroll = 0
  while true do
    local width, height = ui.size()
    local helpVisible = math.min(#help, math.max(0, height - 4))
    local visible = math.max(1, height - 3 - helpVisible)
    if selected <= scroll then
      scroll = selected - 1
    elseif selected > scroll + visible then
      scroll = selected - visible
    end
    ui.clear()
    ui.header(
      title,
      #items > visible and ((scroll + 1) .. "-" .. math.min(#items, scroll + visible)) or nil
    )
    for row = 1, helpVisible do
      ui.text(2, 1 + row, ui.pad(help[row], width - 2), ui.theme.dim)
    end
    local itemTop = 2 + helpVisible
    for slot = 1, visible do
      local i = scroll + slot
      local label = items[i]
      if not label then
        break
      end
      local active = i == selected
      ui.text(
        2,
        itemTop + slot - 1,
        ui.pad(" " .. tostring(label), width - 2),
        active and ui.theme.bg or ui.theme.fg,
        active and ui.theme.fg or ui.theme.bg
      )
    end
    ui.footer("up/down + enter    Q to quit")

    local event = { os.pullEvent() }
    local kind, key = event[1], event[2]
    if kind == "key" and key == keys.up then
      selected = selected > 1 and selected - 1 or #items
    elseif kind == "key" and key == keys.down then
      selected = selected < #items and selected + 1 or 1
    elseif kind == "key" and key == keys.enter then
      return selected
    elseif kind == "key" and key == keys.q then
      return nil
    elseif kind == "mouse_scroll" then
      selected = math.max(1, math.min(#items, selected + event[2]))
    elseif kind == "mouse_click" then
      local clicked = scroll + event[4] - itemTop + 1
      if event[4] >= itemTop and event[4] < height and clicked >= 1 and clicked <= #items then
        return clicked
      end
    end
  end
end

--- Prompt for a line of text with a default, on the current terminal.
function ui.ask(prompt, default)
  term.setTextColor(ui.theme.fg)
  term.setBackgroundColor(ui.theme.bg)
  write(prompt .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local answer = read() or ""
  if answer == "" then
    return default
  end
  return answer
end

--- Same, but insists on a number.
function ui.askNumber(prompt, default)
  while true do
    local answer = ui.ask(prompt, default)
    local number = tonumber(answer)
    if number then
      return math.floor(number)
    end
    printError("Enter a number.")
  end
end

return ui
