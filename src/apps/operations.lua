--- Shared-mine setup and coordinated quarry control for desktop and handheld.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local log = require("core.log")
local control = require("fleet.control")

local state = nil

local function call(action, fields)
  ui.clear()
  ui.header("MINE CONTROL", "working")
  ui.text(2, 3, "Contacting fleet base...", ui.theme.dim)
  local ok, message, data = control.operation(action, fields)
  if data then
    state = data
  end
  log[ok and "info" or "warn"]("operations: " .. tostring(message))
  ui.clear()
  ui.header("MINE CONTROL", ok and "done" or "failed")
  ui.text(2, 3, ui.pad(message, select(1, ui.size()) - 3), ok and ui.theme.good or ui.theme.bad)
  sleep(1.2)
  return ok
end

local function number(prompt, default)
  ui.clear()
  ui.header("MINE CONTROL")
  term.setCursorPos(1, 3)
  return ui.askNumber(prompt, default)
end

local function confirmGridChange()
  return not (state and state.plan and state.plan.configured)
    or ui.menu(
        "RESET SECTOR MAP?",
        { "Continue and clear progress", "Cancel" },
        { "Grid geometry is changing.", "Saved sector progress will reset." }
      )
      == 1
end

call("mine_state")
while true do
  local plan = state and state.plan or {}
  local summary = state and state.summary or {}
  local mineLabel = plan.configured
      and ("Mine: %d,%d at Y%d"):format(plan.centreX, plan.centreZ, plan.surfaceY)
    or "Mine: not configured"
  local sectorLabel = ("Sectors: %s open, %s active"):format(
    summary.opened or 0,
    summary.active or 0
  )
  local labels = {
    "Refresh status",
    "Set mine centre from GPS",
    "Set mine centre manually",
    "Sector size (area per shaft)",
    "Outer rings (mine capacity)",
    "Keepout (protect the base)",
    "Assign quarry to parked fleet",
    "Back to Home",
  }
  local choice = ui.menu("MINE CONTROL", labels, {
    "Shared prospecting + quarry.",
    mineLabel,
    sectorLabel,
  })
  if not choice or choice == 8 then
    break
  elseif choice == 1 then
    call("mine_state")
  elseif choice == 2 and confirmGridChange() then
    call("mine_here")
  elseif choice == 3 and confirmGridChange() then
    local x = number("Mine centre X", plan.centreX or 0)
    local y = number("Surface Y", plan.surfaceY or 64)
    local z = number("Mine centre Z", plan.centreZ or 0)
    call("mine_at", { x = x, y = y, z = z })
  elseif choice == 4 and confirmGridChange() then
    call("mine_config", { cellSize = number("Sector size", plan.cellSize or 48) })
  elseif choice == 5 then
    call("mine_config", { maxRing = number("Outer ring", plan.maxRing or 4) })
  elseif choice == 6 and confirmGridChange() then
    call("mine_config", { keepout = number("Keepout blocks", 96) })
  elseif choice == 7 then
    local x1 = number("First X", plan.centreX or 0)
    local z1 = number("First Z", plan.centreZ or 0)
    local x2 = number("Last X", x1)
    local z2 = number("Last Z", z1)
    local topY = number("Top Y", plan.surfaceY or 64)
    local bottomY = number("Bottom Y", -59)
    local confirmed = ui.menu("ASSIGN QUARRY?", { "Assign to parked miners", "Cancel" }, {
      "This replaces their jobs.",
      ("X %d..%d  Z %d..%d"):format(
        math.min(x1, x2),
        math.max(x1, x2),
        math.min(z1, z2),
        math.max(z1, z2)
      ),
      ("Y %d down to %d"):format(math.max(topY, bottomY), math.min(topY, bottomY)),
    }) == 1
    if confirmed then
      call("quarry", { x1 = x1, z1 = z1, x2 = x2, z2 = z2, topY = topY, bottomY = bottomY })
    end
  end
end

ui.clear()
