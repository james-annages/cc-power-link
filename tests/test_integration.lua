local H = require("harness")
local sim = require("sim")

local function setup(opts)
    opts = opts or {}
    local world = sim.new_world(PY)
    local S = world:add_machine{name="sender", id=1, dist=ROOT.."/dist/sender", sandbox_root=SANDBOX}
    local D = world:add_machine{name="display", id=2, dist=ROOT.."/dist/display", sandbox_root=SANDBOX}
    local st = {formed=true, energy=5e9, max=1e10, transfer=2e8, input=1e6, output=0, cells=12, providers=8}
    sim.modem(world, S, true); sim.modem(world, D, true)
    if opts.dcore then
        st = {energy = opts.dcore.energy, capacity = opts.dcore.capacity, input = opts.dcore.input, output = opts.dcore.output}
        sim.draconic_core(S, "draconic_rf_storage_0", st)
    elseif opts.core then
        st = {energy = opts.core.energy, capacity = opts.core.capacity}
        sim.energy_storage(S, "draconic_core_0", st, opts.core.methods)
    else
        sim.matrix(S, "inductionPort_0", "inductionPort", st)
    end
    local mon = sim.monitor(world, D, "monitor_0", opts.mw or 36, opts.mh or 24)
    S:boot(); D:boot()
    local function cfg(key_s, key_d)
        S:write_file("/ccpl_sender.cfg", string.format('return { AuthKey = %q, TrustedRange = %d }', key_s or "", opts.range or 0))
        D:write_file("/ccpl_display.cfg", string.format('return { AuthKey = %q, TrustedRange = %d, PeerID = %d }', key_d or key_s or "", opts.range or 0, opts.peer or 0))
    end
    cfg(opts.key_s, opts.key_d)
    world.distance = opts.distance
    S:boot(); D:boot()
    return world, S, D, st, mon
end
local function screen(mon) return table.concat(mon.dump(), "\n") end

H.test("first run creates config", function()
    local world = sim.new_world(PY)
    local S = world:add_machine{name="sender", id=1, dist=ROOT.."/dist/sender", sandbox_root=SANDBOX}
    sim.modem(world, S, true)
    world.inputs = {"s"}
    S:boot()
    H.check(S.error == nil, "first start runs the configuration then the sender: " .. tostring(S.error))
    H.check(S:read_file("/ccpl_sender.cfg") ~= nil, "cfg created")
end)

for _, case in ipairs{
    {name="plain", key=""},
    {name="authenticated", key="correct horse"},
} do
    H.test("end to end, cross-dimension, " .. case.name, function()
        local world, S, D, st, mon = setup{key_s=case.key, distance=nil, range=0}
        world:run(20000)
        H.check(not S.exited, "sender running: " .. tostring(S.error) .. S:printed())
        H.check(not D.exited, "display running: " .. tostring(D.error) .. D:printed())
        local scr = screen(mon)
        H.has(scr, "INDUCTION MATRIX", "title")
        H.has(scr, "Capacity", "capacity")
        H.has(scr, "ONLINE", "status online")
        H.has(scr, "50.00", "fill 50%")
        H.has(D.term.dump()[4], "link:", "terminal status row")
        print("  " .. D.term.dump()[4] .. " | " .. D.term.dump()[5])

        -- charging with input
        st.input = 5e7; st.energy = 6e9
        world:run(8000)
        scr = screen(mon)
        H.has(scr, "Charging", "charging label")
        H.hasnt(scr, "ETA Unknown", "ETA computed")

        -- sender stops sending -> OFF-LINE
        S.exited = true
        world:run(6000)
        H.has(screen(mon), "OFF-LINE", "offline after sender stops")
        H.has(D.term.dump()[4], "data:", "status row still drawn")
    end)
end

H.test("trusted range with cross-dimension frames", function()
    local world, S, D, st, mon = setup{key_s="correct horse", distance=nil, range=64}
    world:run(8000)
    H.hasnt(screen(mon), "ONLINE", "nil-distance frames are dropped when a trusted range is set")
end)

H.test("wrong key is rejected", function()
    local world, S, D, st, mon = setup{key_s="correct horse", key_d="battery staple", distance=10}
    world:run(8000)
    H.hasnt(screen(mon), "ONLINE", "no data accepted with wrong key")
    H.has(D.term.dump()[5], "auth:", "stats row")
    H.check(not D.term.dump()[5]:find("auth:0", 1, true), "auth rejections counted")
end)

H.test("monitor too small", function()
    local world, S, D, st, mon = setup{mw=29, mh=19}
    world:run(3000)
    H.has(screen(mon), "monitor too small", "message")
end)

H.test("sender with unformed matrix", function()
    local world, S, D, st, mon = setup{}
    st.formed = false
    world:run(6000)
    H.has(screen(mon), "NOT FORMED", "not formed shown")
end)

H.test("peer id and replay", function()
    local world, S, D, st, mon = setup{peer=99}
    world:run(5000)
    H.hasnt(screen(mon), "ONLINE", "wrong PeerID rejected")
    print("  exited=" .. tostring(D.exited) .. " err=" .. tostring(D.error)); H.check(not D.term.dump()[5]:find("peer:0", 1, true), "peer rejections counted")

    -- replay: resend an old captured frame to a normal display
    local w2, S2, D2, st2, mon2 = setup{}
    w2:run(3000)
    local before = D2.term.dump()[5]
    local cap = S2.modem.last
    for i = 1, 5 do D2:queue("modem_message", "back", 16251, 16250, sim.deep_copy(cap), 10) end
    w2:run(600)
    H.has(D2.term.dump()[5], "order:", "stats row")
    H.check(not D2.term.dump()[5]:find("order:0", 1, true), "replayed frames counted as out of order")
end)

H.test("draconic energy core (draconic_rf_storage)", function()
    -- tier 5 core, 59.3B FE, half full, 1e6 RF/t in
    local world, S, D, st, mon = setup{dcore={energy=2.965e10, capacity=5.93e10, input=1e6, output=0}}
    for i = 1, 40 do world:at(i * 500, function() st.energy = st.energy + 1e7 end) end
    world:run(18000)
    local scr = screen(mon)
    H.check(not S.exited, "sender running: " .. tostring(S.error))
    H.has(scr, "DRACONIC ENERGY CORE", "title")
    H.has(scr, "Type:", "core type shown")
    H.hasnt(scr, "Tier ?", "no placeholder tier")
    H.has(scr, "live", "rates from the core")
    H.has(scr, "Charging", "charging")
    H.has(scr, "Full in", "time to full")
    H.hasnt(scr, "INDUCTION MATRIX", "not a matrix")
    H.has(scr, "ONLINE", "online")
    print("  " .. scr:match("[^\n]*Full in[^\n]*"))

    -- discharging
    st.input, st.output = 0, 2e6
    for i = 1, 40 do world:at(i * 500, function() st.energy = st.energy - 2e7 end) end
    world:run(15000)
    scr = screen(mon)
    H.has(scr, "Discharging", "discharging")
    H.has(scr, "Empty in", "time to empty")
end)

H.test("generic storage discharging, alternate method names, unknown tier", function()
    local world, S, D, st, mon = setup{core={energy=5e8, capacity=1e9, methods={"getEnergyStored","getMaxEnergyStored"}}}
    for i = 1, 40 do world:at(i * 500, function() st.energy = st.energy - 5e5 * 10 end) end
    world:run(12000)
    local scr = screen(mon)
    H.has(scr, "ENERGY STORAGE", "generic title")
    H.has(scr, "Discharging", "discharging")
    H.has(scr, "Empty in", "time to empty")
end)

H.test("energy core capacity is read from the core, tier is only a label", function()
    local world = sim.new_world(PY)
    local S = world:add_machine{name="s", id=1, dist=ROOT.."/dist/sender", sandbox_root=SANDBOX}
    local storage = S:require("ccpl.storage")
    H.check(storage.tier_for == nil and storage.CORE_TIERS == nil, "no hardcoded capacity table")
end)
return H.done()
