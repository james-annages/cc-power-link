local H = require("harness")
local sim = require("sim")
local world = sim.new_world(PY)
local D = world:add_machine{name="d", id=2, dist=ROOT.."/dist/display", sandbox_root=SANDBOX}
local calc, protocol, config = D:require("ccpl.calc"), D:require("ccpl.protocol"), D:require("ccpl.config")

H.test("calc basics", function()
    H.near(calc.joules_to_fe(100), 40, 1e-9, "J to FE")
    H.near(calc.fe_to_joules(40), 100, 1e-9, "FE to J")
    H.eq(calc.classify(true, true, false, 0.5), calc.STATE.ONLINE, "online")
    H.eq(calc.classify(true, true, false, 0.01), calc.STATE.LOW_CHARGE, "low")
    H.eq(calc.classify(true, true, false, 0.99), calc.STATE.HIGH_CHARGE, "high")
    H.eq(calc.classify(true, false, false, 0), calc.STATE.UNFORMED, "unformed")
    H.eq(calc.classify(true, true, true, 0), calc.STATE.FAULT, "fault")
    H.eq(calc.classify(false, false, false, 0), calc.STATE.NO_MATRIX, "no matrix")
    H.check(type(calc.eta_text(0)) == "string", "eta text")
    print("  eta 90s = " .. calc.eta_text(90000) .. ", 3h = " .. calc.eta_text(3 * 3600 * 1000))
end)

H.test("protocol roundtrip and rejects", function()
    local build = {max_energy=1e10, transfer_cap=2e8, cells=12, providers=8, length=5, width=5, height=5, kind=1, tier=0}
    local frame = protocol.make_frame(2, 1, protocol.MSG.BUILD, protocol.build_fields(build))
    local t, d = protocol.decode(frame)
    H.eq(t, protocol.MSG.BUILD, "build type")
    H.check(d ~= nil and d.max_energy == 1e10 and d.cells == 12 and d.kind == 1, "build decoded")
    build.kind = 9
    H.check(select(1, protocol.decode(protocol.make_frame(2, 9, protocol.MSG.BUILD, protocol.build_fields(build)))) == nil, "bad kind rejected")
    build.kind = 2; build.tier = 9
    H.check(select(1, protocol.decode(protocol.make_frame(2, 9, protocol.MSG.BUILD, protocol.build_fields(build)))) == nil, "bad tier rejected")

    build.kind = 1; build.tier = 0; build.cells = 2.5
    H.check(select(1, protocol.decode(protocol.make_frame(2, 9, protocol.MSG.BUILD, protocol.build_fields(build)))) == nil, "fractional cell count rejected")
    build.cells = 12; build.length = 1e300
    H.check(select(1, protocol.decode(protocol.make_frame(2, 9, protocol.MSG.BUILD, protocol.build_fields(build)))) == nil, "huge dimension rejected")

    local st = {attached=true, formed=true, faulted=false, energy=5e9, fill=1.7, last_input=1, last_output=2, time=3}
    t, d = protocol.decode(protocol.make_frame(2, 2, protocol.MSG.STATE, protocol.state_fields(st)))
    H.eq(t, protocol.MSG.STATE, "state type")
    H.check(d ~= nil and d.fill == 1, "fill clamped to 1")

    st.energy = -1
    H.check(select(1, protocol.decode(protocol.make_frame(2, 3, protocol.MSG.STATE, protocol.state_fields(st)))) == nil, "negative rejected")
    st.energy = 0/0
    H.check(select(1, protocol.decode(protocol.make_frame(2, 4, protocol.MSG.STATE, protocol.state_fields(st)))) == nil, "NaN rejected")
    st.energy = 1; st.formed = "yes"
    H.check(select(1, protocol.decode(protocol.make_frame(2, 5, protocol.MSG.STATE, protocol.state_fields(st)))) == nil, "non-boolean rejected")
    H.check(select(1, protocol.decode(protocol.make_frame(2, 6, protocol.MSG.STATE, {true}))) == nil, "short payload rejected")
    H.check(select(1, protocol.decode(nil)) == nil, "nil frame")
end)

H.test("clock module", function()
    local clock = D:require("ccpl.clock")
    H.check(type(clock.now_ms()) == "number", "clock returns milliseconds")
end)

H.test("model charging and eta", function()
    local m = calc.new_model()
    m.set_build{max_energy=1e10, transfer_cap=2e8, cells=1, providers=1, length=5, width=5, height=5, kind=1, tier=0}
    for i = 1, 30 do
        m.set_state{attached=true, formed=true, faulted=false, energy=5e9 + i * 1e7, fill=0.5, last_input=1e7, last_output=0, time=i * 500}
    end
    local v = m.view()
    H.check(v.charging and not v.discharging, "charging")
    H.check(v.eta_ms > 0, "eta positive")
    H.near(v.capacity, calc.joules_to_fe(1e10), 1, "capacity in FE")
end)

H.test("config", function()
    for _, role in ipairs{"sender", "display"} do
        local f = load(config.template(role)); H.check(f ~= nil, role .. " template parses")
        local cfg, err = config.validate(f(), role)
        H.check(cfg ~= nil, role .. " template validates: " .. tostring(err))
    end
    H.check(config.validate({AuthKey="short"}, "sender") == nil, "short key rejected")
    H.check(config.validate({SendPeriodMs=10}, "sender") == nil, "bad period rejected")
    H.check(config.validate({SenderChannel=5, DisplayChannel=5}, "display") == nil, "equal channels rejected")
    H.check(config.validate({EnergyUnit="kWh"}, "display") == nil, "bad unit rejected")
    H.check(config.validate("x", "display") == nil, "non-table rejected")
end)
return H.done()
