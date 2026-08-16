--- Touch-first single-window shell for a Pocket Computer.
---
--- Apps keep their normal header and footer in a 26x19 window. The final row
--- belongs to ICOS, so Home and recovery are always reachable without a
--- keyboard and app-to-app navigation still works through `icos_open_app`.

local ui = require("core.ui")
local apps = require("core.apps")

local handheld = {}

function handheld.run(parent, appList, opts)
  opts = opts or {}
  local name = opts.name or "ICOS"
  local width, height = parent.getSize()
  local task = nil
  local barTargets = {}
  local appTargets = {}
  local scroll = 0
  local running = true

  local function onParent(fn)
    local previous = term.redirect(parent)
    local ok, err = pcall(fn)
    term.redirect(previous)
    if not ok then
      error(err, 0)
    end
  end

  local function resume(event)
    if not task or task.dead then
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

  local function closeTask()
    if task and not task.dead then
      resume({ "icos_close" })
    end
    task = nil
  end

  local function findApp(id)
    for _, app in ipairs(appList) do
      if app.id == id then
        return app
      end
    end
    return nil
  end

  local function launch(app, payload)
    closeTask()
    task = {
      app = app,
      win = window.create(parent, 1, 1, width, math.max(1, height - 1), true),
    }
    task.co = coroutine.create(function()
      local ok, err = apps.run(app)
      if not ok then
        error(err or (app.name .. " exited with an error"), 0)
      end
    end)
    resume({})
    if payload then
      resume({ "icos_open", payload })
    end
  end

  local function drawBar()
    onParent(function()
      ui.row(height, ui.theme.headerBg)
      barTargets = {}
      local function button(x, label, action)
        local text = " " .. label .. " "
        ui.text(x, height, text, ui.theme.bg, ui.theme.headerFg)
        barTargets[#barTargets + 1] = { from = x, to = x + #text - 1, action = action }
        return x + #text + 1
      end
      local x = 2
      if task then
        x = button(x, "HOME", "home")
      end
      button(x, "SYSTEM", "system")
    end)
  end

  local function drawHome()
    onParent(function()
      ui.clear()
      ui.header(name, textutils.formatTime(os.time(), true))
      if opts.homeMessage then
        ui.text(
          2,
          2,
          ui.pad(opts.homeMessage, width - 3),
          opts.homeWarning and ui.theme.warn or ui.theme.dim
        )
      end

      local firstY = 4
      local capacity = math.max(1, height - firstY - 1)
      scroll = math.max(0, math.min(scroll, math.max(0, #appList - capacity)))
      appTargets = {}
      for slot = 1, capacity do
        local index = scroll + slot
        local app = appList[index]
        if not app then
          break
        end
        local y = firstY + slot - 1
        local active = slot % 2 == 1
        ui.text(
          2,
          y,
          ui.pad(" " .. app.name, width - 2),
          ui.theme.fg,
          active and colors.gray or ui.theme.bg
        )
        appTargets[#appTargets + 1] = { from = 2, to = width, y = y, app = app }
      end
      if #appList == 0 then
        ui.center(math.floor(height / 2), "No apps available", ui.theme.dim)
      end
    end)
  end

  local function draw()
    -- Apps use a normal return for their in-app Back action. Treat that as a
    -- completed page and reveal Home; keep failed tasks so the error is visible.
    if task and task.dead and not task.error then
      task = nil
    end
    if task then
      task.win.setVisible(true)
      if task.dead and task.error then
        local previous = term.redirect(task.win)
        ui.clear()
        ui.header(task.app.name, "stopped")
        ui.text(
          2,
          3,
          ui.pad(tostring(task.error or "App closed"), width - 3),
          task.error and ui.theme.bad or ui.theme.dim
        )
        ui.footer("Use HOME to return")
        term.redirect(previous)
      end
    else
      drawHome()
    end
    drawBar()
  end

  draw()
  while running do
    local event = { os.pullEventRaw() }
    local kind = event[1]

    if kind == "terminate" then
      if task then
        closeTask()
      else
        running = false
      end
    elseif kind == "icos_open_app" then
      local app = findApp(event[2])
      if app then
        launch(app, event[3])
      end
    elseif kind == "term_resize" then
      width, height = parent.getSize()
      if task then
        task.win.reposition(1, 1, width, math.max(1, height - 1))
        resume({ "term_resize" })
      end
    elseif kind == "mouse_click" and event[4] == height then
      for _, target in ipairs(barTargets) do
        if event[3] >= target.from and event[3] <= target.to then
          if target.action == "home" then
            closeTask()
          elseif target.action == "system" then
            closeTask()
            running = false
          end
          break
        end
      end
    elseif not task and kind == "mouse_click" then
      for _, target in ipairs(appTargets) do
        if target.app and event[4] == target.y then
          launch(target.app)
          break
        end
      end
    elseif not task and kind == "mouse_scroll" then
      scroll = math.max(0, scroll + event[2])
    elseif not task and kind == "key" and event[2] == keys.down then
      scroll = scroll + 1
    elseif not task and kind == "key" and event[2] == keys.up then
      scroll = math.max(0, scroll - 1)
    elseif task then
      resume(event)
    end

    draw()
  end

  closeTask()
  onParent(ui.clear)
end

return handheld
