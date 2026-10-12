-- cc-power-link configuration tool: run "configure" to change the settings of this computer
require("/initenv").init_env()

local ROLE = "sender"

require("ccpl.configure").run(ROLE)
