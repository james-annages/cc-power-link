local H = require("harness")
local sim = require("sim")

local function scripted(inputs, peripherals)
    local io = { log = {}, inputs = inputs }
    function io.print(t) io.log[#io.log + 1] = t end
    function io.read(prompt, mask) io.last_mask = mask; return table.remove(io.inputs, 1) end
    function io.peripherals(kind) return (peripherals or {})[kind] or {} end
    function io.text() return table.concat(io.log, "\n") end
    return io
end

local function machine(role)
    local w = sim.new_world(PY)
    return w:add_machine{name=role, id=1, dist=ROOT.."/dist/"..role, sandbox_root=SANDBOX}
end

H.test("sender: change fields, pick storage from the list, save", function()
    local m = machine("sender")
    local configure = m:require("ccpl.configure")
    local idx = {}
    for i, f in ipairs(m:require("ccpl.config").fields("sender")) do idx[f.key] = tostring(i) end
    local io = scripted({
        idx.SenderChannel, "16300",
        idx.AuthKey, "my secret key",  -- masked
        idx.StorageInterface, "1",     -- first found
        "s"
    }, { storage = { { name = "draconic_rf_storage_0", type = "draconic_rf_storage" } } })
    local saved = configure.run("sender", io)
    H.check(saved, "saved")
    local cfg = m:read_file("/ccpl_sender.cfg")
    H.has(cfg, "SenderChannel = 16300", "channel written")
    H.has(cfg, 'AuthKey = "my secret key"', "key written")
    H.has(cfg, 'StorageInterface = "draconic_rf_storage_0"', "storage picked")
    H.hasnt(io.text(), "my secret key", "key never printed")
    -- the saved file loads back through the normal path
    local config = m:require("ccpl.config")
    local loaded, err = config.load("/ccpl_sender.cfg", "sender")
    H.check(loaded ~= nil and loaded.SenderChannel == 16300, "reloads: " .. tostring(err))
end)

H.test("invalid values are refused and the old value is kept", function()
    local m = machine("sender")
    local configure = m:require("ccpl.configure")
    local io = scripted({ "3", "short", "2", "abc", "1", "70000", "q" })
    H.check(not configure.run("sender", io), "quit without saving")
    local t = io.text()
    H.has(t, "AuthKey must be empty or at least 8 characters", "short key rejected")
    H.has(t, "that is not a number", "non-number rejected")
    H.has(t, "SenderChannel must be an integer from 1 to 65535", "channel range")
    H.check(m:read_file("/ccpl_sender.cfg") == nil, "nothing written")
end)

H.test("cross-field check blocks saving", function()
    local m = machine("sender")
    local configure = m:require("ccpl.configure")
    local io = scripted({ "1", "16251", "s", "q" }) -- sender channel = display channel
    configure.run("sender", io)
    H.has(io.text(), "cannot save", "refused")
    H.check(m:read_file("/ccpl_sender.cfg") == nil, "nothing written")
end)

H.test("display: choices, reset to default, existing file is the starting point", function()
    local m = machine("display")
    m:write_file("/ccpl_display.cfg", 'return { Theme = "smooth_stone", StaleMs = 8000 }')
    local configure = m:require("ccpl.configure")
    local io = scripted({ "5", "2", "d 6", "s" }) -- field order: channels, key, range, peer, ... check by name below
    local fields = m:require("ccpl.config").fields("display")
    local idx = {}
    for i, f in ipairs(fields) do idx[f.key] = i end
    io.inputs = { tostring(idx.EnergyUnit), "2", "d " .. idx.StaleMs, "s" }
    H.check(configure.run("display", io), "saved")
    local cfg = m:read_file("/ccpl_display.cfg")
    H.has(cfg, 'EnergyUnit = "J"', "choice 2 is J")
    H.has(cfg, 'Theme = "smooth_stone"', "existing value preserved")
    H.has(cfg, "StaleMs = 3000", "reset to default")
end)
return H.done()
