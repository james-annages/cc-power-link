--
-- cc-power-link Storage Adapters
-- Reads energy storage on the sender: Mekanism induction matrices, and anything that reports stored and
-- maximum energy through the generic ComputerCraft energy methods (such as a Draconic Evolution energy core)
--
-- Everything handed to the protocol is in Joules and Joules/tick (Mekanism's unit), so the display needs one
-- model for every kind. Generic storage reports Forge Energy, which is converted here.
--

local ppm = require("scada-common.ppm")
local util = require("scada-common.util")

local clock    = require("ccpl.clock")
local protocol = require("ccpl.protocol")

local storage = {}

local J_PER_FE = 2.5 -- 1 FE = 2.5 J (Mekanism's 0.4 FE per J)

-- method name pairs that report (stored energy, maximum energy), in order of preference
local GENERIC_METHODS = {
    { "getEnergy", "getEnergyCapacity" },        -- ComputerCraft's generic energy storage peripheral
    { "getEnergyStored", "getMaxEnergyStored" }, -- RF API style names
}

-- check if a mounted device really has a method<br>
-- the PPM answers any missing name with a fault-reporting stand-in function, so only look at what is stored
---@nodiscard
local function has(dev, name) return type(dev) == "table" and type(rawget(dev, name)) == "function" end

-- find which generic method pair a device supports
---@nodiscard
---@return string|nil get_energy, string|nil get_capacity
local function generic_methods(dev)
    for _, pair in ipairs(GENERIC_METHODS) do
        if has(dev, pair[1]) and has(dev, pair[2]) then return pair[1], pair[2] end
    end

    return nil, nil
end

-- how long to wait before probing the peripherals again when no storage was found
local NO_STORAGE_SCAN_MS = 2000

-- how often auto-detect re-checks for a better storage
local RESCAN_MS = 10000

local MATRIX_TYPES = { inductionPort = true, reinforcedInductionPort = true }

-- the peripheral type Draconic Evolution gives its energy core (same one cc-mek-scada's RTU gateway uses),
-- methods: getEnergyStored, getMaxEnergyStored, getInputPerTick, getOutputPerTick (all RF)
local CORE_TYPE = "draconic_rf_storage"

---@class ccpl_candidate
---@field iface string
---@field kind integer protocol.KIND
---@field dev table
---@field capacity number|nil maximum energy in FE (generic only)

-- list every mounted device that can be read as storage
---@nodiscard
---@return ccpl_candidate[]
local function candidates()
    local list = {}

    for iface, entry in pairs(ppm.list_mounts()) do
        if MATRIX_TYPES[entry.type] then
            table.insert(list, { iface = iface, kind = protocol.KIND.MATRIX, dev = entry.dev })
        elseif entry.type == CORE_TYPE then
            local cap = has(entry.dev, "getMaxEnergyStored") and entry.dev.getMaxEnergyStored()

            if type(cap) == "number" and cap > 0 then
                table.insert(list, { iface = iface, kind = protocol.KIND.CORE, dev = entry.dev, capacity = cap })
            end
        else
            local get_e, get_c = generic_methods(entry.dev)

            if get_e then
                local cap = entry.dev[get_c]()

                if type(cap) == "number" and cap > 0 then
                    table.insert(list, { iface = iface, kind = protocol.KIND.GENERIC, dev = entry.dev, capacity = cap })
                end
            end
        end
    end

    -- matrices first, then energy cores, then the biggest generic storage, then by name so the choice is stable
    local rank = { [protocol.KIND.MATRIX] = 1, [protocol.KIND.CORE] = 2, [protocol.KIND.GENERIC] = 3 }

    table.sort(list, function (a, b)
        if a.kind ~= b.kind then return rank[a.kind] < rank[b.kind] end
        if a.capacity ~= b.capacity then return (a.capacity or 0) > (b.capacity or 0) end
        return a.iface < b.iface
    end)

    return list
end

-- find the storage to read
---@nodiscard
---@param wanted string peripheral name from the config, "" to auto-detect
---@return ccpl_candidate|nil
function storage.find(wanted)
    local list = candidates()

    if wanted ~= "" then
        for _, c in ipairs(list) do
            if c.iface == wanted then return c end
        end

        return nil
    end

    return list[1]
end

-- create a reader for the sender<br>
-- tier_override: energy core tier label to show (1-8), 0 to show none
---@nodiscard
---@param wanted string StorageInterface config value
---@param tier_override integer StorageTier config value
function storage.new_reader(wanted, tier_override)
    local self = {
        last_fe = nil,  ---@type number|nil derived rates for generic storage
        last_ms = 0,
        iface = nil,    ---@type string|nil
        chosen = nil,   ---@type ccpl_candidate|nil storage in use, so the whole peripheral list is not probed every read
        next_scan = 0   -- earliest time the peripheral list may be probed again
    }

    -- get the storage to read, keeping the previous choice while it is still mounted
    ---@nodiscard
    local function current()
        local c, now = self.chosen, clock.now_ms()

        if c and ppm.get_periph(c.iface) == c.dev then
            -- auto-detect: look again now and then, so a better storage that is attached later is picked up
            if wanted ~= "" or now < self.next_scan then return c end
        elseif now < self.next_scan then
            -- nothing usable, don't probe every peripheral on every call
            return nil
        end

        local found = storage.find(wanted)

        self.next_scan = now + util.trinary(found == nil, NO_STORAGE_SCAN_MS, RESCAN_MS)

        if found and c and found.iface == c.iface and found.dev == c.dev then found = c end

        self.chosen = found

        return found
    end

    ---@class ccpl_reader
    local public = {}

    -- the name of the storage that was read last
    function public.iface() return self.iface end

    -- read the live state
    ---@nodiscard
    ---@return table state, integer|nil kind
    function public.read_state()
        local state = {
            attached = false, formed = false, faulted = false,
            energy = 0, fill = 0, last_input = 0, last_output = 0,
            time = clock.now_ms()
        }

        local c = current()

        if c == nil then
            self.iface, self.last_fe = nil, nil
            return state, nil
        end

        self.iface = c.iface
        state.attached = true

        local dev = c.dev

        if c.kind == protocol.KIND.MATRIX then
            self.last_fe = nil

            local formed = dev.isFormed()

            if formed == nil then
                state.faulted = true
            elseif formed then
                state.formed = true

                local energy, fill = dev.getEnergy(), dev.getEnergyFilledPercentage()
                local input, output = dev.getLastInput(), dev.getLastOutput()

                if energy == nil or fill == nil or input == nil or output == nil then
                    state.faulted = true
                else
                    state.energy, state.fill, state.last_input, state.last_output = energy, fill, input, output
                end
            end
        elseif c.kind == protocol.KIND.CORE then
            self.last_fe = nil

            local fe, cap = dev.getEnergyStored(), dev.getMaxEnergyStored()
            local input, output = dev.getInputPerTick(), dev.getOutputPerTick()

            if type(fe) ~= "number" or type(cap) ~= "number" or cap <= 0 or type(input) ~= "number" or type(output) ~= "number" then
                state.faulted = true
            else
                state.formed = true
                state.energy = fe * J_PER_FE
                state.fill = math.min(fe / cap, 1.0)
                state.last_input = math.max(input, 0) * J_PER_FE
                state.last_output = math.max(output, 0) * J_PER_FE
            end
        else
            local get_e, get_c = generic_methods(dev)
            local fe, cap = get_e and dev[get_e](), get_c and dev[get_c]()

            if type(fe) ~= "number" or type(cap) ~= "number" or cap <= 0 then
                state.faulted = true
                self.last_fe = nil
            else
                state.formed = true
                state.energy = fe * J_PER_FE
                state.fill = math.min(fe / cap, 1.0)

                -- no rate methods: measure the change in stored energy, in FE per tick (50 ms)
                if self.last_fe ~= nil and state.time > self.last_ms then
                    local per_tick = (fe - self.last_fe) / ((state.time - self.last_ms) / 50)

                    if per_tick > 0 then state.last_input = per_tick * J_PER_FE
                    else state.last_output = -per_tick * J_PER_FE end
                end

                self.last_fe, self.last_ms = fe, state.time
            end
        end

        return state, c.kind
    end

    -- read the build properties
    ---@nodiscard
    ---@return table|nil build nil if not available
    function public.read_build()
        local c = current()

        if c == nil then return nil end

        local dev = c.dev

        if c.kind == protocol.KIND.MATRIX then
            if dev.isFormed() ~= true then return nil end

            local b = {
                max_energy   = dev.getMaxEnergy(),
                transfer_cap = dev.getTransferCap(),
                cells        = dev.getInstalledCells(),
                providers    = dev.getInstalledProviders(),
                length       = dev.getLength(),
                width        = dev.getWidth(),
                height       = dev.getHeight(),
                kind         = protocol.KIND.MATRIX,
                tier         = 0
            }

            -- a failed read leaves a nil field, so check each key by name
            for _, key in ipairs({ "max_energy", "transfer_cap", "cells", "providers", "length", "width", "height" }) do
                if type(b[key]) ~= "number" then return nil end
            end

            return b
        end

        local _, get_c = generic_methods(dev)
        local cap

        if c.kind == protocol.KIND.CORE then cap = dev.getMaxEnergyStored() else cap = get_c and dev[get_c]() end

        if type(cap) ~= "number" or cap <= 0 then return nil end

        -- the capacity is always read from the core, the tier is only a label the player can choose to show
        local tier = tier_override

        return {
            max_energy = cap * J_PER_FE, transfer_cap = 0, cells = 0, providers = 0,
            length = 0, width = 0, height = 0,
            kind = c.kind, tier = tier
        }
    end

    return public
end

return storage
