--
-- cc-power-link Sender
-- Reads an induction matrix or an energy core and sends its telemetry to the display over a wireless/ender modem
--

require("/initenv").init_env()

local log      = require("scada-common.log")
local util     = require("scada-common.util")

local clock    = require("ccpl.clock")
local config   = require("ccpl.config")
local link     = require("ccpl.link")
local protocol = require("ccpl.protocol")
local storage  = require("ccpl.storage")

local SENDER_VERSION = "0.3.0"

local CFG_PATH = "/ccpl_sender.cfg"

-- how often the main loop wakes up, in seconds
local TICK_S = 0.25

local println = util.println

println(">> CC-POWER-LINK SENDER v" .. SENDER_VERSION .. " <<")

----------------------------------------
-- configuration and log
----------------------------------------

local cfg, cfg_err, reason = config.load(CFG_PATH, "sender")

if cfg == nil and reason == "missing" then
    -- first start: walk through the configuration, then carry on
    println("config> no configuration yet, starting the configuration tool")

    if require("ccpl.configure").run("sender") then cfg, cfg_err = config.load(CFG_PATH, "sender") end
end

if cfg == nil then
    println("config> " .. tostring(cfg_err))
    return
end

log.init(cfg.LogPath, log.MODE.APPEND, false)

log.info("========================================")
log.info("BOOTING cc-power-link sender v" .. SENDER_VERSION .. " (protocol v" .. protocol.version .. ")")
log.info("========================================")

----------------------------------------
-- network
----------------------------------------

println("startup> setting up the wireless link (authentication takes a moment)...")

local lk, lk_err = link.new(cfg, "sender")

if lk == nil then
    println("startup> " .. lk_err)
    log.fatal("startup failed: " .. lk_err)
    return
end

println("startup> link ready, display channel " .. cfg.DisplayChannel)

----------------------------------------
-- storage access
----------------------------------------

local reader = storage.new_reader(cfg.StorageInterface, cfg.StorageTier)

----------------------------------------
-- main loop
----------------------------------------

local function main()
    local next_state, next_build = 0, 0
    local last_iface, last_ok = nil, nil ---@type string|nil, boolean|nil

    println("startup> sending (hold ctrl+t to stop)")

    local timer = os.startTimer(TICK_S)

    while true do
        local event, p1, p2, p3, p4, p5 = os.pullEventRaw()

        if event == "timer" and p1 == timer then
            local now = clock.now_ms()

            lk.periodic()

            if now >= next_state then
                next_state = now + cfg.SendPeriodMs

                local state = reader.read_state()
                local iface, ok = reader.iface(), state.attached and state.formed

                if last_iface ~= iface or last_ok ~= ok then
                    last_iface, last_ok = iface, ok
                    log.info("storage " .. tostring(iface) .. ": " .. util.trinary(ok, "readable", "not available"))
                    println("storage> " .. util.trinary(iface, iface, "none found") .. " " .. util.trinary(ok, "(reading)", "(not available)"))
                end

                lk.send(protocol.MSG.STATE, protocol.state_fields(state))
            end

            if now >= next_build then
                local build = reader.read_build()

                -- only count a build as sent if there was one, otherwise try again next tick
                if build then
                    next_build = now + cfg.BuildPeriodMs
                    lk.send(protocol.MSG.BUILD, protocol.build_fields(build))
                end
            end

            timer = os.startTimer(TICK_S)
        elseif event == "modem_message" then
            -- lets the NIC answer link probes from the display
            lk.receive(p1, p2, p3, p4, p5)
        elseif event == "peripheral" then
            lk.handle_attach(p1)
        elseif event == "peripheral_detach" then
            lk.handle_detach(p1)
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
