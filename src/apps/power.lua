--- ICOS power menu.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local boot = require("core.boot")

local choice = ui.menu("Power", { "Restart ICOS", "Shut down", "Cancel" })

if choice == 1 then
  boot.reboot()
elseif choice == 2 then
  boot.shutdown()
  os.shutdown()
end
