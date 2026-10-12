local H = require("harness")
local sim = require("sim")

-- a computer running the wizard on its own terminal (51x19 advanced computer)
local function setup(role, periph, cfg)
    local w = sim.new_world(PY)
    local m = w:add_machine{name=role, id=1, dist=ROOT.."/dist/"..role, sandbox_root=SANDBOX}
    sim.modem(w, m, true)
    if periph then periph(w, m) end
    if cfg then m:write_file("/ccpl_" .. role .. ".cfg", cfg) end
    m:write_file("/wiz.lua", 'require("/initenv").init_env(); WIZ_RESULT = require("ccpl.configure").run("' .. role .. '"); WIZ_DONE = true')
    m:boot("/wiz.lua")
    return w, m
end

local function screen(m) return table.concat(m.term.dump(), "\n") end
local function click(w, m, x, y) m:queue("mouse_click", 1, x, y); m:queue("mouse_up", 1, x, y); w:run(300) end

-- click a field, empty it, type text
local function type_into(w, m, x, y, text)
    click(w, m, x, y)
    for _ = 1, 40 do m:queue("key", m.env.keys["end"], false) end
    for _ = 1, 40 do m:queue("key", m.env.keys.backspace, false) end
    for c in text:gmatch(".") do m:queue("char", c) end
    w:run(100)
end

local NEXT = { 46, 18 }
local function next_page(w, m) click(w, m, NEXT[1], NEXT[2]) end
local function configure_button(w, m) click(w, m, 5, 6) end

H.test("every field is on exactly one page, with a label and a short hint", function()
    local w = sim.new_world(PY)
    for _, role in ipairs{"sender", "display"} do
        local m = w:add_machine{name=role, id=1, dist=ROOT.."/dist/"..role, sandbox_root=SANDBOX}
        local wizard, config = m:require("ccpl.wizard"), m:require("ccpl.config")
        local seen = {}
        for _, def in ipairs(wizard.PAGES[role]) do
            for _, key in ipairs(def.keys) do seen[key] = (seen[key] or 0) + 1 end
        end
        for _, f in ipairs(config.fields(role)) do
            H.eq(seen[f.key], 1, role .. " " .. f.key .. " is on one page")
            H.check(wizard.LABELS[f.key] ~= nil and #wizard.LABELS[f.key] <= 18, f.key .. " has a short label")
            H.check(wizard.HINTS[f.key] ~= nil and #wizard.HINTS[f.key] <= 48, f.key .. " has a hint that fits")
        end
    end
end)

H.test("sender wizard: pick storage, change values, review, save", function()
    local w, m = setup("sender", function(w, m) sim.matrix(m, "inductionPort_0", "inductionPort", {}) end)
    H.check(m.error == nil, "starts: " .. tostring(m.error))
    H.has(screen(m), "sender configurator", "header")
    H.has(screen(m), "Configure System", "main page")
    H.hasnt(screen(m), "Startup", "no startup button before a config exists")

    configure_button(w, m)
    H.has(screen(m), "Network (1/5)", "network page")
    type_into(w, m, 22, 4, "16300")
    next_page(w, m)

    H.has(screen(m), "Security (2/5)", "security page")
    type_into(w, m, 22, 4, "my secret key")
    next_page(w, m)

    H.has(screen(m), "Storage (3/5)", "storage page")
    H.has(screen(m), "inductionPort_0 (inductionPort)", "attached storage is listed")
    click(w, m, 4, 6) -- the second line: the induction port
    next_page(w, m)

    H.has(screen(m), "Timing (4/5)", "timing page")
    next_page(w, m)
    H.has(screen(m), "Log (5/5)", "log page")
    next_page(w, m)

    local s = screen(m)
    H.has(s, "Review and save", "summary")
    H.has(s, "16300", "channel shown")
    H.has(s, "inductionPort_0", "storage shown")
    H.hasnt(s, "my secret key", "key is hidden on the summary")
    H.has(s, "*************", "key is masked")

    click(w, m, 45, 18) -- Save
    H.has(screen(m), "Settings saved", "saved page")
    local cfg = m:read_file("/ccpl_sender.cfg")
    H.has(cfg, "SenderChannel = 16300", "channel written")
    H.has(cfg, 'AuthKey = "my secret key"', "key written")
    H.has(cfg, 'StorageInterface = "inductionPort_0"', "storage written")
    local loaded, err = m:require("ccpl.config").load("/ccpl_sender.cfg", "sender")
    H.check(loaded ~= nil, "the saved file loads again: " .. tostring(err))

    click(w, m, 4, 18) -- Close
    H.check(m.exited and m.error == nil, "wizard closed cleanly: " .. tostring(m.error))
    H.check(m.env.WIZ_RESULT == true, "reports saved")
end)

H.test("a bad value stays on the page with a message and nothing is saved", function()
    local w, m = setup("sender")
    configure_button(w, m)
    type_into(w, m, 22, 4, "99999") -- over 65535
    next_page(w, m)
    H.has(screen(m), "Network (1/5)", "still on the network page")
    H.has(screen(m), "must be an integer from 1 to 65535", "says why")

    type_into(w, m, 22, 4, "16251")  -- same as the display channel
    next_page(w, m)
    H.has(screen(m), "must be different", "equal channels refused")

    type_into(w, m, 22, 4, "16260")
    next_page(w, m)
    H.has(screen(m), "Security (2/5)", "moves on once it is valid")
    type_into(w, m, 22, 4, "short")
    next_page(w, m)
    H.has(screen(m), "at least 8 characters", "short key refused")
    H.check(m:read_file("/ccpl_sender.cfg") == nil, "nothing written")

    click(w, m, 4, 18) -- Back
    click(w, m, 4, 18) -- Back to the main page
    H.has(screen(m), "Configure System", "back on the main page")
    click(w, m, 4, 18) -- Exit
    H.check(m.exited and m.env.WIZ_RESULT == false, "exit without saving reports false")
end)

H.test("display wizard: monitor list, choices, existing settings are the start", function()
    local w, m = setup("display", function(w, m) sim.monitor(w, m, "monitor_3", 36, 24) end,
                       'return { Theme = "smooth_stone", StaleMs = 8000 }')
    H.has(screen(m), "Startup", "startup button when a config exists")
    configure_button(w, m)
    next_page(w, m); next_page(w, m)

    H.has(screen(m), "Monitor (3/5)", "monitor page")
    H.has(screen(m), "monitor_3 (monitor)", "monitor listed")
    click(w, m, 4, 6)
    next_page(w, m)

    H.has(screen(m), "Appearance (4/5)", "appearance page")
    click(w, m, 22, 5) -- second energy unit choice: J
    next_page(w, m); next_page(w, m)
    click(w, m, 45, 18) -- Save

    local cfg = m:read_file("/ccpl_display.cfg")
    H.has(cfg, 'Monitor = "monitor_3"', "monitor picked")
    H.has(cfg, 'EnergyUnit = "J"', "unit chosen")
    H.has(cfg, 'Theme = "smooth_stone"', "existing theme kept")
    H.has(cfg, "StaleMs = 8000", "existing value kept")
end)

H.test("view configuration shows the saved settings", function()
    local w, m = setup("sender", nil, 'return { SenderChannel = 16777 % 65536, SendPeriodMs = 750 }')
    click(w, m, 5, 8) -- View Configuration
    local s = screen(m)
    H.has(s, "Current configuration", "view title")
    H.has(s, "750", "saved value shown")
    H.hasnt(s, "Save", "no save button in the view")
    click(w, m, 4, 18) -- Back
    H.has(screen(m), "Configure System", "back on the main page")
end)

H.test("computers without a color screen get the text menu", function()
    local w = sim.new_world(PY)
    local m = w:add_machine{name="sender", id=1, dist=ROOT.."/dist/sender", sandbox_root=SANDBOX}
    m.env.term.isColor = function () return false end
    w.inputs = { "s" }
    local configure = m:require("ccpl.configure")
    H.check(configure.run("sender"), "text menu saved")
    H.check(m:read_file("/ccpl_sender.cfg") ~= nil, "config written")
end)
return H.done()
