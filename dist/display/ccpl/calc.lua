--
-- cc-power-link Calculations
-- Energy statistics, ETA and status logic, ported from cc-mek-scada
-- (supervisor/facility_update.lua, coordinator/ioctl.lua, scada-common/constants.lua)
--

local util = require("scada-common.util")

local calc = {}

-- Mekanism Joules to Forge Energy (same factor as util.joules_to_fe_rf)
local J_TO_FE = 0.4

calc.J_TO_FE = J_TO_FE

-- same thresholds as cc-mek-scada's RS_THRESHOLDS.ENERGY_CHARGE_LOW/HIGH
calc.CHARGE_LOW  = 0.05
calc.CHARGE_HIGH = 0.95

---@enum CCPL_STATE
calc.STATE = {
    OFFLINE     = 1, -- no telemetry received
    UNFORMED    = 2, -- matrix not formed
    FAULT       = 3, -- peripheral reads failing on the sender
    ONLINE      = 4,
    LOW_CHARGE  = 5,
    HIGH_CHARGE = 6,
    NO_MATRIX   = 7  -- sender has no storage attached
}

-- convert Joules to Forge Energy
---@nodiscard
---@param j number
function calc.joules_to_fe(j) return j * J_TO_FE end

-- convert Forge Energy to Joules
---@nodiscard
---@param fe number
function calc.fe_to_joules(fe) return fe / J_TO_FE end

-- generate the text string for the charge/discharge ETA<br>
-- (same output as cc-mek-scada's coordinator gen_eta_text)
---@nodiscard
---@param eta_ms number eta in milliseconds, negative when discharging
---@return string
function calc.eta_text(eta_ms)
    local str, pre = "", util.trinary(eta_ms >= 0, "Full in ", "Empty in ")

    local seconds = math.abs(eta_ms) / 1000
    local minutes = seconds / 60
    local hours   = minutes / 60
    local days    = hours / 24

    if math.abs(eta_ms) < 1000 or (eta_ms ~= eta_ms) then
        -- really small or NaN
        str = "No ETA"
    elseif days < 1000 then
        days    = math.floor(days)
        hours   = math.floor(hours % 24)
        minutes = math.floor(minutes % 60)
        seconds = math.floor(seconds % 60)

        if days > 0 then
            str = days .. "d"
        elseif hours > 0 then
            str = hours .. "h " .. minutes .. "m"
        elseif minutes > 0 then
            str = minutes .. "m " .. seconds .. "s"
        elseif seconds > 0 then
            str = seconds .. "s"
        end

        str = pre .. str
    else
        local years = math.floor(days / 365.25)

        if years <= 99999999 then
            str = pre .. years .. "y"
        else
            str = pre .. "eras"
        end
    end

    return str
end

-- classify the matrix status
---@nodiscard
---@param attached boolean
---@param formed boolean
---@param faulted boolean
---@param fill number 0.0 to 1.0
---@return CCPL_STATE
function calc.classify(attached, formed, faulted, fill)
    local S = calc.STATE

    if not attached then return S.NO_MATRIX end
    if faulted then return S.FAULT end
    if not formed then return S.UNFORMED end

    if fill > calc.CHARGE_HIGH then return S.HIGH_CHARGE end
    if fill < calc.CHARGE_LOW then return S.LOW_CHARGE end

    return S.ONLINE
end

-- text for the panel's title, sub title and two detail lines, from a model view
---@nodiscard
---@param v table model view
---@return string title, string subtitle, string line_a, string line_b
function calc.describe(v)
    local function row(label, value) return string.format("%-10s%9s", label, tostring(value)) end

    if v.kind == 0 then
        return "ENERGY STORAGE", "", "", ""
    elseif v.kind == 1 then
        return "INDUCTION MATRIX", util.trinary(v.size ~= "", "Size " .. v.size, ""), row("Cells:", v.cells), row("Providers:", v.providers)
    elseif v.kind == 3 then
        -- the tier is only known if the player set StorageTier, the capacity itself is always shown
        local tier = util.trinary(v.tier > 0, "Tier " .. v.tier, "")
        return "DRACONIC ENERGY CORE", tier, row("Type:", "Core"), row("Rates:", "live")
    end

    return "ENERGY STORAGE", "", row("Type:", "RF block"), row("Rates:", "measured")
end

-- create a new matrix model<br>
-- tracks moving averages in Forge Energy (the same ~3 second averages the supervisor uses)
---@nodiscard
function calc.new_model()
    local self = {
        build = nil,    ---@type table|nil
        state = nil,    ---@type table|nil
        init = false,
        last_energy = 0,
        last_t = 0,
        avg_charge  = util.ema_filter(0.2857),
        avg_inflow  = util.ema_filter(0.2857),
        avg_outflow = util.ema_filter(0.2857),
        avg_net     = util.ema_filter(0.075)
    }

    ---@class ccpl_model
    local public = {}

    -- reset all statistics (call when telemetry is lost)
    function public.reset()
        self.state = nil
        self.init = false
        self.avg_net.reset()
    end

    -- set the build properties (from a BUILD message)
    ---@param b table decoded BUILD message
    function public.set_build(b)
        local capacity = b.max_energy * J_TO_FE

        -- if the capacity changed, toss out existing rate data
        if self.build and self.build.capacity ~= capacity then self.avg_net.reset() end

        self.build = {
            capacity     = capacity,
            transfer_cap = b.transfer_cap * J_TO_FE,
            cells        = b.cells,
            providers    = b.providers,
            length       = b.length,
            width        = b.width,
            height       = b.height,
            kind         = b.kind,
            tier         = b.tier
        }
    end

    -- update the state (from a STATE message)
    ---@param s table decoded STATE message
    function public.set_state(s)
        self.state = s

        if not (s.attached and s.formed and not s.faulted) then
            -- cannot reliably track stats, start over once healthy again
            self.init = false
            return
        end

        local energy, t = s.energy * J_TO_FE, s.time

        if self.init then
            self.avg_charge.update(energy, t)
            self.avg_inflow.update(s.last_input * J_TO_FE, t)
            self.avg_outflow.update(s.last_output * J_TO_FE, t)

            if t > self.last_t then
                -- energy delta per millisecond
                self.avg_net.update((energy - self.last_energy) / (t - self.last_t), t)

                self.last_energy = energy
                self.last_t = t
            end
        else
            self.init = true

            self.avg_charge.reset(energy)
            self.avg_inflow.reset(s.last_input * J_TO_FE)
            self.avg_outflow.reset(s.last_output * J_TO_FE)
            self.avg_net.reset()

            self.last_energy = energy
            self.last_t = t
        end
    end

    -- get the current view of the matrix, everything in Forge Energy (FE) and FE/t
    ---@nodiscard
    function public.view()
        local s, b = self.state, self.build

        local v = {
            has_state    = s ~= nil,
            has_build    = b ~= nil,
            status       = calc.STATE.OFFLINE,
            capacity     = 0.0,
            energy       = 0.0,
            fill         = 0.0,
            input        = 0.0,
            output       = 0.0,
            transfer_cap = 0.0,
            cells        = 0,
            providers    = 0,
            kind         = 0,
            tier         = 0,
            size         = "",
            avg_charge   = 0.0,
            avg_inflow   = 0.0,
            avg_outflow  = 0.0,
            in_sat       = 0.0,
            out_sat      = 0.0,
            charging     = false,
            discharging  = false,
            at_max_io    = false,
            eta_ms       = 0
        }

        if b then
            v.capacity     = b.capacity
            v.transfer_cap = b.transfer_cap
            v.cells        = b.cells
            v.providers    = b.providers
            v.kind         = b.kind
            v.tier         = b.tier
            v.size         = util.trinary(b.length > 0, b.length .. "x" .. b.width .. "x" .. b.height, "")
        end

        if s then
            v.status = calc.classify(s.attached, s.formed, s.faulted, s.fill)

            v.energy = s.energy * J_TO_FE
            v.fill   = s.fill
            v.input  = s.last_input * J_TO_FE
            v.output = s.last_output * J_TO_FE

            if self.init then
                v.avg_charge  = self.avg_charge.get()
                v.avg_inflow  = self.avg_inflow.get()
                v.avg_outflow = self.avg_outflow.get()

                v.charging    = v.avg_inflow > v.avg_outflow
                v.discharging = v.avg_outflow > v.avg_inflow

                local net = self.avg_net.get()

                if net ~= 0 and b then
                    -- remaining until full (charging) or empty (discharging), from the instantaneous energy
                    local remaining = util.trinary(net > 0, math.max(b.capacity - v.energy, 0), v.energy)
                    v.eta_ms = remaining / net
                end
            end

            if b and b.transfer_cap > 0 then
                v.in_sat  = math.min(v.input / b.transfer_cap, 1.0)
                v.out_sat = math.min(v.output / b.transfer_cap, 1.0)

                v.at_max_io = v.avg_inflow >= b.transfer_cap or v.avg_outflow >= b.transfer_cap
            end
        end

        return v
    end

    return public
end

return calc
