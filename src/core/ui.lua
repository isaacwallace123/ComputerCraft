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

--- Write at a position with explicit colours. The workhorse - everything else
--- is built on it.
function ui.text(x, y, text, fg, bg)
  term.setCursorPos(x, y)
  term.setTextColor(fg or ui.theme.fg)
  term.setBackgroundColor(bg or ui.theme.bg)
  term.write(tostring(text))
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
  ui.text(2, 1, title, ui.theme.headerFg, ui.theme.headerBg)
  if right then
    ui.text(math.max(2, width - #right), 1, right, ui.theme.headerFg, ui.theme.headerBg)
  end
end

function ui.footer(text)
  local _, height = ui.size()
  ui.row(height, ui.theme.headerBg)
  ui.text(2, height, text, ui.theme.headerFg, ui.theme.headerBg)
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

--- Arrow-key menu. Returns the chosen index, or nil if the user pressed Q.
function ui.menu(title, items)
  local selected = 1
  while true do
    ui.clear()
    ui.header(title)
    for i, label in ipairs(items) do
      local active = i == selected
      ui.text(
        2,
        2 + i,
        (" %-24s"):format(label),
        active and ui.theme.bg or ui.theme.fg,
        active and ui.theme.fg or ui.theme.bg
      )
    end
    ui.footer("up/down + enter    Q to quit")

    local _, key = os.pullEvent("key")
    if key == keys.up then
      selected = selected > 1 and selected - 1 or #items
    elseif key == keys.down then
      selected = selected < #items and selected + 1 or 1
    elseif key == keys.enter then
      return selected
    elseif key == keys.q then
      return nil
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
