--
-- cc-power-link Configuration
-- A plain Lua table file that is edited in-game (edit /ccpl_<role>.cfg), generated from defaults on first run
--

local config = {}

---@class ccpl_field
---@field key string
---@field type string
---@field default any
---@field roles string[] roles this field applies to
---@field desc string
---@field check? fun(v: any): boolean
---@field err? string
---@field choices? string[] the only allowed values
---@field pick? string "storage" or "monitor": the value is a peripheral name
---@field secret? boolean hide the value when shown or typed

local ALL, SENDER, DISPLAY = { "sender", "display" }, { "sender" }, { "display" }

local function is_channel(v) return v == math.floor(v) and v >= 1 and v <= 65535 end

---@type ccpl_field[]
local FIELDS = {
    { key = "SenderChannel", type = "number", default = 16250, roles = ALL,
      desc = "channel the sender listens on (must match on both computers; avoid 16240-16244, used by cc-mek-scada)",
      check = is_channel, err = "must be an integer from 1 to 65535" },
    { key = "DisplayChannel", type = "number", default = 16251, roles = ALL,
      desc = "channel the display listens on (must match on both computers)",
      check = is_channel, err = "must be an integer from 1 to 65535" },
    { key = "AuthKey", type = "string", default = "", roles = ALL,
      desc = "shared passkey for message authentication, \"\" to disable (same on both, at least 8 characters)",
      secret = true,
      check = function (v) return #v == 0 or #v >= 8 end, err = "must be empty or at least 8 characters" },
    { key = "TrustedRange", type = "number", default = 0, roles = ALL,
      desc = "max accepted distance in blocks, 0 = no limit (MUST be 0 across dimensions)",
      check = function (v) return v >= 0 end, err = "must be 0 or greater" },
    { key = "PeerID", type = "number", default = 0, roles = ALL,
      desc = "computer ID of the other end (sender: the display, display: the sender), 0 = any",
      check = function (v) return v == math.floor(v) and v >= 0 end, err = "must be an integer, 0 or greater" },
    { key = "LogPath", type = "string", default = "/ccpl.log", roles = ALL,
      desc = "log file path",
      check = function (v) return #v > 0 end, err = "must not be empty" },

    -- sender only
    { key = "StorageInterface", type = "string", default = "", roles = SENDER,
      desc = "peripheral name of the storage to read (induction port, or an energy core / other energy block), \"\" to auto-detect",
      pick = "storage" },
    { key = "StorageTier", type = "number", default = 0, roles = SENDER,
      desc = "label an energy core as this tier (1-8), 0 to show no tier (the capacity is always read from the core)",
      check = function (v) return v == math.floor(v) and v >= 0 and v <= 8 end, err = "must be an integer from 0 to 8" },
    { key = "SendPeriodMs", type = "number", default = 500, roles = SENDER,
      desc = "milliseconds between state messages",
      check = function (v) return v >= 250 and v <= 10000 end, err = "must be from 250 to 10000" },
    { key = "BuildPeriodMs", type = "number", default = 3000, roles = SENDER,
      desc = "milliseconds between build messages",
      check = function (v) return v >= 1000 and v <= 60000 end, err = "must be from 1000 to 60000" },

    -- display only
    { key = "Monitor", type = "string", default = "", roles = DISPLAY,
      desc = "peripheral name of the monitor, \"\" to use the first one found",
      pick = "monitor" },
    { key = "EnergyUnit", type = "string", default = "FE", roles = DISPLAY,
      desc = "energy unit to show: \"FE\" (also RF) or \"J\"",
      choices = { "FE", "J" },
      check = function (v) return v == "FE" or v == "J" end, err = "must be \"FE\" or \"J\"" },
    { key = "Theme", type = "string", default = "deepslate", roles = DISPLAY,
      desc = "color theme: \"deepslate\" (dark) or \"smooth_stone\" (light)",
      choices = { "deepslate", "smooth_stone" },
      check = function (v) return v == "deepslate" or v == "smooth_stone" end, err = "must be \"deepslate\" or \"smooth_stone\"" },
    { key = "StaleMs", type = "number", default = 3000, roles = DISPLAY,
      desc = "milliseconds without telemetry before the display shows OFF-LINE (keep it at least 3x the sender's SendPeriodMs)",
      check = function (v) return v >= 1000 end, err = "must be 1000 or greater" }
}

-- check if a field applies to a role
---@nodiscard
---@param field ccpl_field
---@param role string
local function has_role(field, role)
    for _, r in ipairs(field.roles) do
        if r == role then return true end
    end

    return false
end

-- format a default value as Lua source
---@nodiscard
---@param v any
local function lua_value(v)
    if type(v) == "string" then return string.format("%q", v) else return tostring(v) end
end

-- the configuration file path for a role
---@nodiscard
---@param role string "sender" or "display"
function config.path(role) return "/ccpl_" .. role .. ".cfg" end

-- the fields that apply to a role, in file order
---@nodiscard
---@param role string "sender" or "display"
---@return ccpl_field[]
function config.fields(role)
    local list = {}

    for _, f in ipairs(FIELDS) do
        if has_role(f, role) then table.insert(list, f) end
    end

    return list
end

-- generate the configuration file text for a role, using the given values (defaults for any missing)
---@nodiscard
---@param role string "sender" or "display"
---@param values? table field values
---@return string
function config.render(role, values)
    values = values or {}

    local lines = {
        "-- cc-power-link " .. role .. " configuration",
        "-- change values with the configure tool (run \"configure\"), or edit them here and reboot (ctrl+r)",
        "return {"
    }

    for _, f in ipairs(FIELDS) do
        if has_role(f, role) then
            local v = values[f.key]

            if v == nil then v = f.default end

            table.insert(lines, "")
            table.insert(lines, "    -- " .. f.desc)
            table.insert(lines, "    " .. f.key .. " = " .. lua_value(v) .. ",")
        end
    end

    table.insert(lines, "}")
    table.insert(lines, "")

    return table.concat(lines, "\n")
end

-- generate the default configuration file text for a role
---@nodiscard
---@param role string "sender" or "display"
---@return string
function config.template(role) return config.render(role, {}) end

-- validate a configuration table for a role, filling in defaults for missing fields
---@nodiscard
---@param raw any parsed configuration
---@param role string "sender" or "display"
---@return table|nil config, string|nil error_message
function config.validate(raw, role)
    if type(raw) ~= "table" then return nil, "configuration must return a table" end

    local cfg = {}

    for _, f in ipairs(FIELDS) do
        if has_role(f, role) then
            local v = raw[f.key]

            if v == nil then v = f.default end

            if type(v) ~= f.type then
                return nil, f.key .. " must be a " .. f.type
            elseif f.check and not f.check(v) then
                return nil, f.key .. " " .. (f.err or "is invalid")
            end

            cfg[f.key] = v
        end
    end

    if cfg.SenderChannel == cfg.DisplayChannel then
        return nil, "SenderChannel and DisplayChannel must be different"
    end

    return cfg, nil
end

-- write a configuration file after validating it
---@param path string configuration file path
---@param role string "sender" or "display"
---@param values table field values
---@return boolean ok, string|nil error_message
function config.save(path, role, values)
    local cfg, msg = config.validate(values, role)

    if not cfg then return false, msg end

    -- write a temporary file first, so a failure never leaves a half-written configuration
    local tmp = path .. ".tmp"
    local file = fs.open(tmp, "w")

    if file == nil then return false, "could not write " .. path end

    file.write(config.render(role, cfg))
    file.close()

    if fs.exists(path) then fs.delete(path) end

    fs.move(tmp, path)

    return true, nil
end

-- load the configuration for a role from a file
---@nodiscard
---@param path string configuration file path
---@param role string "sender" or "display"
---@return table|nil config, string|nil error_message, string|nil reason "missing" if the file does not exist
function config.load(path, role)
    if not fs.exists(path) then return nil, path .. " does not exist, run configure", "missing" end

    local fn, err = loadfile(path, "t", {})

    if not fn then return nil, "could not read " .. path .. ": " .. tostring(err) end

    local ok, raw = pcall(fn)

    if not ok then return nil, "error in " .. path .. ": " .. tostring(raw) end

    local cfg, msg = config.validate(raw, role)

    if not cfg then return nil, path .. ": " .. msg end

    return cfg, nil
end

return config
