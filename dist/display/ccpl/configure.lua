--
-- cc-power-link Configuration Tool
-- Menu driven editor for the sender / display configuration file
--

local config = require("ccpl.config")

local configure = {}

-- peripheral types that count as storage for the sender
local STORAGE_TYPES = {
    inductionPort = true, reinforcedInductionPort = true, draconic_rf_storage = true, energy_storage = true
}

-- default input/output using the computer's terminal and peripherals
---@nodiscard
local function terminal_io()
    local io = {}

    function io.print(text) print(text) end

    -- read a line, mask: show this character instead of what is typed
    function io.read(prompt, mask)
        write(prompt)
        return read(mask)
    end

    -- names of attached peripherals for a pick kind ("storage" or "monitor")
    function io.peripherals(kind)
        local list = {}

        for _, name in ipairs(peripheral.getNames()) do
            local ptype = peripheral.getType(name)

            if (kind == "monitor" and ptype == "monitor") or (kind == "storage" and (STORAGE_TYPES[ptype] or false)) then
                table.insert(list, { name = name, type = ptype })
            end
        end

        return list
    end

    return io
end

-- show a value for the menu
---@nodiscard
local function show(f, v)
    if f.secret then return (v == "" and "(none)" or string.rep("*", #v)) end
    if v == "" then return "(auto)" end
    return tostring(v)
end

-- parse text typed for a field
---@nodiscard
---@return any|nil value, string|nil error_message
local function parse(f, text)
    if f.type == "number" then
        local n = tonumber(text)

        if n == nil then return nil, "that is not a number" end

        return n, nil
    end

    return text, nil
end

-- ask for a new value for one field
---@param io table
---@param f ccpl_field
---@param current any
---@return any value new value (the current one if unchanged)
local function edit(io, f, current)
    io.print("")
    io.print(f.key .. ": " .. f.desc)

    if f.pick then
        local found = io.peripherals(f.pick)

        if #found > 0 then
            io.print("found:")
            for i, p in ipairs(found) do io.print("  " .. i .. ") " .. p.name .. " (" .. p.type .. ")") end
            io.print("enter a number, a name, or nothing for automatic")
        else
            io.print("none found right now; type a name or leave empty for automatic")
        end

        local text = io.read("> ")

        if text == nil then return current end

        local n = tonumber(text)

        if n and found[n] then return found[n].name end

        return text
    elseif f.choices then
        for i, c in ipairs(f.choices) do io.print("  " .. i .. ") " .. c) end

        local text = io.read("> ")

        if text == nil or text == "" then return current end

        local n = tonumber(text)

        if n and f.choices[n] then return f.choices[n] end

        return text
    end

    local text = io.read("> ", f.secret and "*" or nil)

    if text == nil then return current end

    -- empty input keeps the value, except for text fields where it can clear it (type - to clear)
    if text == "" then return current end
    if text == "-" and f.type == "string" then return "" end

    local v, err = parse(f, text)

    if v == nil then
        io.print(err)
        return current
    end

    return v
end

-- run the configuration tool for a role
---@param role string "sender" or "display"
---@param io? table input/output (for tests)
---@return boolean saved
function configure.run(role, io)
    io = io or terminal_io()

    local path = config.path(role)
    local fields = config.fields(role)

    -- start from the saved file, or the defaults
    local values = {}

    if fs.exists(path) then
        local fn = loadfile(path, "t", {})
        local ok, raw = false, nil

        if fn then ok, raw = pcall(fn) end
        if ok and type(raw) == "table" then values = raw end
    end

    for _, f in ipairs(fields) do
        if values[f.key] == nil then values[f.key] = f.default end
    end

    local message = ""

    while true do
        io.print("")
        io.print("== cc-power-link " .. role .. " configuration ==")

        for i, f in ipairs(fields) do
            io.print(string.format("%2d) %-16s %s", i, f.key, show(f, values[f.key])))
        end

        if message ~= "" then io.print(message) end
        message = ""

        io.print("number = change, d <n> = default, s = save, q = quit")

        local text = io.read("> ")

        if text == nil then return false end

        text = text:gsub("^%s+", ""):gsub("%s+$", "")

        local n = tonumber(text)
        local reset = text:match("^d%s+(%d+)$")

        if text == "s" then
            local ok, err = config.save(path, role, values)

            if ok then
                io.print("saved " .. path .. ", reboot the computer (ctrl+r) to apply")
                return true
            end

            message = "cannot save: " .. tostring(err)
        elseif text == "q" then
            return false
        elseif reset and fields[tonumber(reset)] then
            local f = fields[tonumber(reset)]
            values[f.key] = f.default
        elseif n and fields[n] then
            local f = fields[n]
            local new = edit(io, f, values[f.key])

            -- check this value on its own right away
            local trial = {}
            for k, v in pairs(values) do trial[k] = v end
            trial[f.key] = new

            if f.check and not f.check(new) then
                message = f.key .. " " .. (f.err or "is invalid") .. ", kept " .. show(f, values[f.key])
            elseif type(new) ~= f.type then
                message = f.key .. " must be a " .. f.type
            else
                values[f.key] = new
            end
        elseif text ~= "" then
            message = "unknown choice '" .. text .. "'"
        end
    end
end

return configure
