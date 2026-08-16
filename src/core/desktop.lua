--- A page-based desktop: icons, maximised apps, and a persistent taskbar.
---
--- Apps are coroutines, each drawing into its own `window`. The event loop
--- resumes them the way CraftOS's multishell does - keyboard and mouse go to
--- whichever app has focus, everything else (timers, rednet) goes to all of
--- them, because a background app still needs its own timers to fire.
---
--- Each page owns row 1, so there is exactly one title bar: ICOS on Home, or
--- the app's own header while that app is focused. The taskbar is the only
--- global chrome and Home is the one page which cannot be closed.

local ui = require("core.ui")
local apps = require("core.apps")

local desktop = {}

-- Events that belong to whoever has focus. Everything else is broadcast.
local FOCUSED_ONLY = {
  key = true,
  key_up = true,
  char = true,
  paste = true,
  mouse_click = true,
  mouse_up = true,
  mouse_drag = true,
  mouse_scroll = true,
}

function desktop.run(parent, appList, opts)
  opts = opts or {}
  local name = opts.name or "ICOS"

  local width, height = parent.getSize()
  local contentTop, contentHeight = 1, height - 1

  local tasks = {}
  local focused = nil
  local chips, icons = {}, {}
  local running = true

  local function onParent(fn)
    local previous = term.redirect(parent)
    local ok, err = pcall(fn)
    term.redirect(previous)
    if not ok then
      error(err, 0)
    end
  end

  local function resume(task, event)
    if task.dead then
      return
    end
    if
      task.filter
      and event[1]
      and event[1] ~= task.filter
      and event[1] ~= "terminate"
      and not event[1]:match("^icos_")
    then
      return
    end

    local previous = term.redirect(task.win)
    local ok, result = coroutine.resume(task.co, table.unpack(event))
    term.redirect(previous)

    if not ok then
      task.dead, task.error = true, result
    elseif coroutine.status(task.co) == "dead" then
      task.dead = true
    else
      task.filter = result
    end
  end

  local function setVisibility()
    for index, task in ipairs(tasks) do
      task.win.setVisible(index == focused)
    end
  end

  local function launch(app, payload)
    for index, task in ipairs(tasks) do
      if task.app.id == app.id then
        focused = index
        setVisibility()
        if payload then
          resume(task, { "icos_open", payload })
        end
        return
      end
    end

    local task = {
      app = app,
      win = window.create(parent, 1, contentTop, width, contentHeight, false),
    }
    task.co = coroutine.create(function()
      local ok, err = apps.run(app)
      if not ok then
        error(err or (app.name .. " exited with an error"), 0)
      end
    end)

    tasks[#tasks + 1] = task
    focused = #tasks
    setVisibility()
    resume(task, {})
    if payload then
      resume(task, { "icos_open", payload })
    end
  end

  local function availableApp(id)
    for _, app in ipairs(appList) do
      if app.id == id then
        return app
      end
    end
    return nil
  end

  local function close(index)
    local task = tasks[index]
    if task and not task.dead then
      -- ICOS-aware apps use this event to release modems and other resources.
      resume(task, { "icos_close" })
    end
    table.remove(tasks, index)
    focused = nil
    setVisibility()
  end

  local function drawChrome()
    onParent(function()
      if focused == nil then
        ui.row(1, ui.theme.headerBg)
        ui.text(2, 1, name, ui.theme.headerFg, ui.theme.headerBg)
        local clock = textutils.formatTime(os.time(), true)
        ui.text(math.max(2, width - #clock), 1, clock, ui.theme.headerFg, ui.theme.headerBg)
      end

      ui.row(height, ui.theme.headerBg)
      chips = {}

      local x = 2
      local home = " " .. name .. " "
      local onDesktop = focused == nil
      ui.text(
        x,
        height,
        home,
        onDesktop and ui.theme.bg or ui.theme.headerFg,
        onDesktop and ui.theme.fg or ui.theme.headerBg
      )
      chips[#chips + 1] = { from = x, to = x + #home - 1, action = "home" }
      x = x + #home + 1

      for index, task in ipairs(tasks) do
        local label = " " .. task.app.name .. (task.dead and " !" or "") .. " x "
        if x + #label < width then
          local active = index == focused
          ui.text(
            x,
            height,
            label,
            active and ui.theme.bg or ui.theme.headerFg,
            active and ui.theme.fg or ui.theme.headerBg
          )
          -- The trailing "x" is the close box; the rest focuses.
          chips[#chips + 1] = { from = x, to = x + #label - 4, action = "focus", index = index }
          chips[#chips + 1] =
            { from = x + #label - 3, to = x + #label - 1, action = "close", index = index }
          x = x + #label + 1
        end
      end
    end)
  end

  local function drawDesktop()
    onParent(function()
      for row = contentTop, height - 1 do
        ui.text(1, row, string.rep(" ", width), ui.theme.fg, ui.theme.bg)
      end

      icons = {}
      local cell = 12
      local perRow = math.max(1, math.floor((width - 2) / cell))

      for index, app in ipairs(appList) do
        local column = (index - 1) % perRow
        local row = math.floor((index - 1) / perRow)
        local x = 2 + column * cell
        local y = contentTop + 2 + row * 4

        if y + 2 < height then
          ui.text(x, y, " +----+ ", ui.theme.accent)
          ui.text(x, y + 1, " | ** | ", ui.theme.accent)
          ui.text(x, y + 2, ui.pad(index .. " " .. app.name, cell - 1), ui.theme.fg)
          icons[#icons + 1] = { x1 = x, x2 = x + cell - 2, y1 = y, y2 = y + 2, app = app }
        end
      end

      if #appList == 0 then
        ui.center(math.floor(height / 2), "No apps available for this machine.", ui.theme.dim)
      end
    end)
  end

  local function draw()
    if focused and tasks[focused] then
      setVisibility()
      local task = tasks[focused]
      if task.dead and task.error and not task.errorDrawn then
        local previous = term.redirect(task.win)
        ui.clear()
        ui.header(task.app.name, "stopped")
        local taskWidth = ui.size()
        ui.text(2, 3, ui.pad(tostring(task.error), taskWidth - 3), ui.theme.bad)
        ui.footer("Click ICOS to go home, or x to close")
        term.redirect(previous)
        task.errorDrawn = true
      end
    else
      focused = nil
      setVisibility()
      drawDesktop()
    end
    drawChrome()
  end

  local function click(x, y)
    if y == height then
      for _, chip in ipairs(chips) do
        if x >= chip.from and x <= chip.to then
          if chip.action == "home" then
            focused = nil
          elseif chip.action == "focus" then
            focused = chip.index
          elseif chip.action == "close" then
            close(chip.index)
          end
          return
        end
      end
      return
    end

    if focused and tasks[focused] then
      resume(tasks[focused], { "mouse_click", 1, x, y - contentTop + 1 })
      return
    end

    for _, icon in ipairs(icons) do
      if x >= icon.x1 and x <= icon.x2 and y >= icon.y1 and y <= icon.y2 then
        launch(icon.app)
        return
      end
    end
  end

  -- Auto-open a single app rather than making the player click one icon.
  if opts.autoLaunch and #appList == 1 then
    launch(appList[1])
  end

  draw()
  local clock = os.startTimer(1)

  while running do
    local event = { os.pullEventRaw() }
    local kind = event[1]

    if kind == "terminate" then
      running = false
    else
      -- A monitor is a mouse with one button. Normalising here means apps never
      -- need to know whether they are on a screen or a wall.
      local monitorInput = kind == "monitor_touch"
        and (not opts.monitorName or event[2] == opts.monitorName)
      local primaryResize = kind == "monitor_resize"
        and (not opts.monitorName or event[2] == opts.monitorName)
      if monitorInput then
        event = { "mouse_click", 1, event[3], event[4] }
        kind = "mouse_click"
      end

      if kind == "icos_open_app" then
        local app = availableApp(event[2])
        if app then
          launch(app, event[3])
        end
      elseif primaryResize or (kind == "term_resize" and opts.localInput ~= false) then
        draw()
      elseif kind == "timer" and event[2] == clock then
        clock = os.startTimer(1)
        for _, task in ipairs(tasks) do
          resume(task, event)
        end
      elseif kind == "mouse_click" and (monitorInput or opts.localInput ~= false) then
        click(event[3], event[4])
      elseif FOCUSED_ONLY[kind] then
        if opts.localInput ~= false then
          if focused and tasks[focused] then
            resume(tasks[focused], event)
          elseif kind == "char" and event[2] == "q" then
            running = false
          elseif kind == "char" then
            local index = tonumber(event[2])
            if index and appList[index] then
              launch(appList[index])
            end
          end
        end
      else
        for _, task in ipairs(tasks) do
          resume(task, event)
        end
      end

      draw()
    end
  end

  for index = #tasks, 1, -1 do
    close(index)
  end

  onParent(function()
    ui.clear()
  end)
end

return desktop
