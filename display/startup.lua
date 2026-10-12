--
-- cc-power-link Display
-- Receives induction matrix telemetry over a wireless/ender modem and draws it on an advanced monitor
--

require("/initenv").init_env()

local log        = require("scada-common.log")
local ppm        = require("scada-common.ppm")
local psil       = require("scada-common.psil")
local tcd        = require("scada-common.tcd")
local util       = require("scada-common.util")

local flasher    = require("graphics.flasher")
local DisplayBox = require("graphics.elements.DisplayBox")

local calc       = require("ccpl.calc")
local clock      = require("ccpl.clock")
local config     = require("ccpl.config")
local link       = require("ccpl.link")
local protocol   = require("ccpl.protocol")
local panel      = require("ccpl.ui.panel")
local style      = require("ccpl.ui.style")

local DISPLAY_VERSION = "0.4.0"

local CFG_PATH = "/ccpl_display.cfg"

-- seconds between periodic checks (staleness, link detection, terminal status)
local PERIOD_S = 0.5

local println = util.println

println(">> CC-POWER-LINK DISPLAY v" .. DISPLAY_VERSION .. " <<")

----------------------------------------
-- configuration and log
----------------------------------------

local cfg, cfg_err, reason = config.load(CFG_PATH, "display")

if cfg == nil and reason == "missing" then
    -- first start: walk through the configuration, then carry on
    println("config> no configuration yet, starting the configuration tool")

    if require("ccpl.configure").run("display") then cfg, cfg_err = config.load(CFG_PATH, "display") end
end

if cfg == nil then
    println("config> " .. tostring(cfg_err))
    return
end

log.init(cfg.LogPath, log.MODE.APPEND, false)

log.info("========================================")
log.info("BOOTING cc-power-link display v" .. DISPLAY_VERSION .. " (protocol v" .. protocol.version .. ")")
log.info("========================================")

style.set_theme(cfg.Theme)

----------------------------------------
-- network
----------------------------------------

println("startup> setting up the wireless link (authentication takes a moment)...")

local lk, lk_err = link.new(cfg, "display")

if lk == nil then
    println("startup> " .. lk_err)
    log.fatal("startup failed: " .. lk_err)
    return
end

println("startup> link ready, listening on channel " .. cfg.DisplayChannel)

----------------------------------------
-- state
----------------------------------------

local model = calc.new_model()

-- energy unit conversion, the model works in Forge Energy
local unit_label = cfg.EnergyUnit
local to_unit = util.trinary(cfg.EnergyUnit == "J", calc.fe_to_joules, function (fe) return fe end)

local rx = {
    last = 0,        -- time of the last accepted message, 0 if none yet
    stale = true,
    link_up = false
}

local ui = {
    box = nil,       ---@type DisplayBox|nil
    monitor = nil,   ---@type Monitor|nil
    iface = nil,     ---@type string|nil
    ps = nil         ---@type psil|nil
}

-- last message for the computer's own terminal (shown below the status lines)
local note = ""

-- set the terminal note and log it
---@param msg string
local function set_note(msg)
    note = msg
    log.info("note: " .. msg)
end

----------------------------------------
-- user interface
----------------------------------------

-- publish a model view to the panel
---@param v table model view
local function publish_view(v)
    local ps = ui.ps

    if ps == nil then return end

    ps.publish("computed_status", v.status)
    ps.publish("max_energy", to_unit(v.capacity))
    ps.publish("energy", to_unit(v.energy))
    ps.publish("avg_charge", to_unit(v.avg_charge))
    ps.publish("last_input", to_unit(v.input))
    ps.publish("avg_inflow", to_unit(v.avg_inflow))
    ps.publish("last_output", to_unit(v.output))
    ps.publish("avg_outflow", to_unit(v.avg_outflow))
    ps.publish("transfer_cap", to_unit(v.transfer_cap))
    ps.publish("energy_fill", v.fill)
    local title, subtitle, a, b = calc.describe(v)
    ps.publish("title", title)
    ps.publish("subtitle", subtitle)
    ps.publish("line_a", a)
    ps.publish("line_b", b)
    ps.publish("is_charging", v.charging)
    ps.publish("is_discharging", v.discharging)
    ps.publish("at_max_io", v.at_max_io)
    ps.publish("eta_string", calc.eta_text(v.eta_ms))
    ps.publish("in_sat", v.in_sat)
    ps.publish("out_sat", v.out_sat)
end

-- tear down the UI
local function close_ui()
    if ui.box then
        ui.box.delete()
        ui.box = nil
    end

    ui.ps = nil

    flasher.clear()
end

-- find the monitor to use
---@nodiscard
---@return Monitor|nil monitor, string|nil iface
local function find_monitor()
    local list = ppm.get_monitor_list()

    if cfg.Monitor ~= "" then
        if list[cfg.Monitor] then return list[cfg.Monitor].dev, cfg.Monitor end

        return nil, nil
    end

    local names = {}
    for name, _ in pairs(list) do table.insert(names, name) end
    table.sort(names)

    if #names > 0 then return list[names[1]].dev, names[1] end

    return nil, nil
end

-- start (or restart) the UI on the monitor
---@return boolean success
local function start_ui()
    close_ui()

    local monitor, iface = find_monitor()

    ui.monitor, ui.iface = monitor, iface

    if monitor == nil then
        set_note("no monitor found, waiting for one")
        return false
    end

    -- same init the coordinator uses: half-scale text and the theme palette
    monitor.setTextScale(0.5)
    monitor.setTextColor(colors.white)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    monitor.setCursorPos(1, 1)

    for _, c in ipairs(style.theme.colors) do monitor.setPaletteColor(c.c, c.hex) end

    local w, h = monitor.getSize()

    if w == nil or w < panel.WIDTH or h < panel.HEIGHT then
        monitor.setTextColor(colors.red)
        monitor.write("monitor too small")

        set_note(util.c("monitor ", iface, " is too small, need ", panel.WIDTH, "x", panel.HEIGHT,
                        " characters at text scale 0.5 (a 2x2 advanced monitor), have ", w, "x", h))
        return false
    end

    ui.ps = psil.create()

    local ok, err = pcall(function ()
        ui.box = DisplayBox{window=monitor,fg_bg=style.root}

        -- center the panel on larger monitors
        panel.new(ui.box, math.floor((w - panel.WIDTH) / 2) + 1, math.floor((h - panel.HEIGHT) / 2) + 1, ui.ps, unit_label)
    end)

    if not ok then
        log.error("failed to start the UI: " .. tostring(err))
        set_note("failed to start the UI: " .. tostring(err))
        close_ui()
        return false
    end

    flasher.run()

    -- show whatever we already know
    if model.view().has_state and not rx.stale then publish_view(model.view()) end

    set_note(util.c("showing the matrix on ", iface, " (", w, "x", h, ")"))

    return true
end

----------------------------------------
-- telemetry
----------------------------------------

-- handle an accepted message
---@param msg_type CCPL_MSG
---@param msg table
local function on_message(msg_type, msg)
    rx.last = clock.now_ms()

    if msg_type == protocol.MSG.BUILD then model.set_build(msg) else model.set_state(msg) end

    if rx.stale then
        rx.stale = false
        log.info("telemetry received")
    end

    publish_view(model.view())
end

-- periodic task: link detection, staleness, and the status lines on the computer's own terminal
local function periodic()
    local now = clock.now_ms()

    rx.link_up = lk.periodic()

    local stale = rx.last == 0 or (now - rx.last) > cfg.StaleMs

    if stale and not rx.stale then
        rx.stale = true
        log.warning("telemetry lost")

        -- stop averaging until data returns, keep the last values on screen but flag them as old
        model.reset()

        if ui.ps then
            ui.ps.publish("computed_status", calc.STATE.OFFLINE)
            ui.ps.publish("is_charging", false)
            ui.ps.publish("is_discharging", false)
            ui.ps.publish("at_max_io", false)
            ui.ps.publish("eta_string", calc.eta_text(0))
        end
    end

    -- terminal status lines
    local s = lk.get_stats()
    local age = util.trinary(rx.last == 0, "never", string.format("%.1fs ago", (now - rx.last) / 1000))

    term.setCursorPos(1, 4)
    term.clearLine()
    term.write(util.c("data: ", age, " | link: ", util.trinary(rx.link_up, "up", "down")))
    term.setCursorPos(1, 5)
    term.clearLine()
    term.write(util.c("ok:", s.accepted, " auth:", s.auth, " peer:", s.peer, " order:", s.order, " bad:", s.malformed))
    term.setCursorPos(1, 7)
    term.clearLine()
    term.write(note)

    tcd.dispatch_unique(PERIOD_S, periodic)
end

----------------------------------------
-- main loop
----------------------------------------

local function main()
    term.clear()
    term.setCursorPos(1, 1)
    println(">> CC-POWER-LINK DISPLAY v" .. DISPLAY_VERSION .. " <<")
    println(util.c("listening on channel ", cfg.DisplayChannel, ", hold ctrl+t to stop"))

    start_ui()

    tcd.dispatch(PERIOD_S, periodic)

    while true do
        local event, p1, p2, p3, p4, p5 = os.pullEventRaw()

        if event == "modem_message" then
            local msg_type, msg = lk.receive(p1, p2, p3, p4, p5)

            if msg_type ~= nil then on_message(msg_type, msg) end
        elseif event == "timer" then
            tcd.handle(p1)
        elseif event == "peripheral" then
            local ptype = lk.handle_attach(p1)

            if ptype == "monitor" and ui.box == nil then start_ui() end
        elseif event == "peripheral_detach" then
            local ptype = lk.handle_detach(p1)

            if ptype == "monitor" and p1 == ui.iface then
                close_ui()
                ui.monitor, ui.iface = nil, nil
                set_note("monitor lost, waiting for it to return")
            end
        elseif event == "monitor_resize" then
            if p1 == ui.iface then start_ui() end
        elseif event == "terminate" then
            break
        end
    end
end

local ok, err = pcall(main)

if not ok then
    log.fatal("crashed: " .. tostring(err))
    println("crashed: " .. tostring(err))

    -- nobody is watching an unattended computer, so start over instead of staying dead (ctrl+t cancels)
    println("restarting in 5 seconds (hold ctrl+t to cancel)...")

    local cancelled = false
    local timer = os.startTimer(5)

    while true do
        local event, p1 = os.pullEventRaw()

        if event == "terminate" then cancelled = true break end
        if event == "timer" and p1 == timer then break end
    end

    if not cancelled then os.reboot() end
else
    log.info("stopped")
    println("stopped")
end
