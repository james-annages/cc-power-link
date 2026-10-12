--
-- cc-power-link Protocol
-- Induction matrix telemetry carried in cc-mek-scada style SCADA frames
--

local comms = require("scada-common.comms")

local protocol = {}

protocol.version = "0.1.0"

-- scada_frame protocol number<br>
-- cc-mek-scada uses 0-3 (see comms.PROTOCOL), so stay far outside of that range
protocol.PROTOCOL = 100

---@enum CCPL_MSG
protocol.MSG = {
    BUILD = 0, -- multiblock build properties (rarely changes)
    STATE = 1  -- live state (energy, fill, last input/output)
}

---@enum CCPL_KIND
protocol.KIND = {
    MATRIX  = 1, -- Mekanism induction matrix, rates come from the multiblock
    GENERIC = 2, -- any other energy storage, rates are measured from the change in stored energy
    CORE    = 3  -- Draconic Evolution energy core (draconic_rf_storage), rates come from the core
}

-- BUILD payload: { max_energy, transfer_cap, cells, providers, length, width, height, kind, tier }<br>
-- STATE payload: { attached, formed, faulted, energy, fill, last_input, last_output, time }<br>
-- energy values are Joules, as returned by the Mekanism peripheral

local BUILD_LEN = 10 -- msg type + 9 fields
local STATE_LEN = 9 -- msg type + 8 fields

local type = type

-- check that a value is a finite number
---@nodiscard
---@param x any
local function is_num(x) return type(x) == "number" and x == x and x > -math.huge and x < math.huge end

-- check that a value is a finite, non-negative number
---@nodiscard
---@param x any
local function is_pos(x) return is_num(x) and x >= 0 end

-- check that a value is a non-negative whole number of a sane size (block counts and dimensions)
---@nodiscard
---@param x any
local function is_count(x) return is_pos(x) and x == math.floor(x) and x <= 2147483647 end

-- make a SCADA frame carrying a cc-power-link message
---@nodiscard
---@param dest_addr integer destination computer ID, or comms.BROADCAST
---@param seq_num integer sequence number
---@param msg_type CCPL_MSG message type
---@param fields table message fields (array, no holes)
---@return scada_frame frame
function protocol.make_frame(dest_addr, seq_num, msg_type, fields)
    local payload = { msg_type }
    for i = 1, #fields do payload[i + 1] = fields[i] end

    local frame = comms.scada_frame()
    frame.make(dest_addr, seq_num, protocol.PROTOCOL, payload)

    return frame
end

-- create the field array for a BUILD message
---@nodiscard
---@param b { max_energy: number, transfer_cap: number, cells: integer, providers: integer, length: integer, width: integer, height: integer }
function protocol.build_fields(b)
    return { b.max_energy, b.transfer_cap, b.cells, b.providers, b.length, b.width, b.height, b.kind, b.tier }
end

-- create the field array for a STATE message
---@nodiscard
---@param s { attached: boolean, formed: boolean, faulted: boolean, energy: number, fill: number, last_input: number, last_output: number, time: integer }
function protocol.state_fields(s)
    return { s.attached, s.formed, s.faulted, s.energy, s.fill, s.last_input, s.last_output, s.time }
end

-- decode and validate a cc-power-link message from a SCADA frame<br>
-- anything malformed is rejected rather than trusted
---@nodiscard
---@param frame scada_frame
---@return CCPL_MSG|nil msg_type, table|nil message
function protocol.decode(frame)
    if frame == nil or frame.protocol() ~= protocol.PROTOCOL then return nil, nil end

    local d = frame.data()
    local t = d[1]

    if t == protocol.MSG.BUILD and #d == BUILD_LEN then
        for i = 2, BUILD_LEN do
            if not is_pos(d[i]) then return nil, nil end
        end

        if d[9] ~= protocol.KIND.MATRIX and d[9] ~= protocol.KIND.GENERIC and d[9] ~= protocol.KIND.CORE then return nil, nil end
        if d[10] > 8 or d[10] ~= math.floor(d[10]) then return nil, nil end

        -- cells, providers and the dimensions are whole numbers
        for i = 4, 8 do
            if not is_count(d[i]) then return nil, nil end
        end

        return t, {
            kind         = d[9],
            tier         = d[10],
            max_energy   = d[2],
            transfer_cap = d[3],
            cells        = d[4],
            providers    = d[5],
            length       = d[6],
            width        = d[7],
            height       = d[8]
        }
    elseif t == protocol.MSG.STATE and #d == STATE_LEN then
        if type(d[2]) ~= "boolean" or type(d[3]) ~= "boolean" or type(d[4]) ~= "boolean" then return nil, nil end

        for i = 5, STATE_LEN do
            if not is_pos(d[i]) then return nil, nil end
        end

        return t, {
            attached    = d[2],
            formed      = d[3],
            faulted     = d[4],
            energy      = d[5],
            fill        = math.min(d[6], 1.0),
            last_input  = d[7],
            last_output = d[8],
            time        = d[9]
        }
    end

    return nil, nil
end

return protocol
