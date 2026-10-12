local H = require("harness")
local sim = require("sim")

local BASE = "https://example.test/dist/"

local function new_machine(world, id)
    local m = world:add_machine{name="blank", id=id or 5, dist=ROOT.."/tests/fixtures/blank", sandbox_root=SANDBOX}
    -- the published installer is the only thing on a fresh computer
    local f = assert(io.open(ROOT.."/dist/install.lua", "rb")); local src = f:read("*a"); f:close()
    -- a build without --base-url has an empty default address, point it at the test server
    src = src:gsub('local DEFAULT_URL = "[^"]*"', function () return 'local DEFAULT_URL = "' .. BASE .. '"' end)
    m:write_file("/install.lua", src)
    return m
end

local function new_world()
    local w = sim.new_world(PY)
    w.http_base, w.http_root = BASE, ROOT.."/dist"
    return w
end

local function out(m) return m:printed() end
local function exists(m, p) return m.env.fs.exists(p) end

H.test("an old installer replaces itself with the published one", function()
    local w = new_world(); local m = new_machine(w)
    -- an out-of-date copy, like one uploaded to pastebin long ago
    m:write_file("/install.lua", m:read_file("/install.lua"):gsub('INSTALLER_VERSION = "[^"]*"', 'INSTALLER_VERSION = "0.0-old"'))
    m:run("/install.lua", "sender", "-y")
    H.has(out(m), "installer updated", "announced: " .. out(m))
    H.hasnt(out(m), "failed", "no failures: " .. out(m))
    H.check(exists(m, "/startup.lua"), "install carried on with the new installer")
    H.check(m:read_file("/install.lua"):find('0.0-old', 1, true) == nil, "installer file replaced")

    -- already current: no restart
    m.out = {}
    m:run("/install.lua", "check")
    H.hasnt(out(m), "installer updated", "no self update when current")

    -- opting out
    m:write_file("/install.lua", m:read_file("/install.lua"):gsub('INSTALLER_VERSION = "[^"]*"', 'INSTALLER_VERSION = "0.0-old"'))
    m.out = {}
    m:run("/install.lua", "check", "--no-self-update")
    H.hasnt(out(m), "installer updated", "--no-self-update respected")
end)

H.test("a bare install on an installed computer updates it", function()
    local w = new_world(); local m = new_machine(w)
    m:run("/install.lua", "display", "-y")
    m:write_file("/ccpl/calc.lua", "-- tampered")
    m.out = {}
    m:run("/install.lua", "-y")
    H.has(out(m), "repairing", "bare install repaired: " .. out(m))
end)

H.test("install sender", function()
    local w = new_world(); local m = new_machine(w)
    m:run("/install.lua", "sender", "-y")
    H.hasnt(out(m), "failed", "no failures: " .. out(m))
    H.check(exists(m, "/startup.lua"), "startup installed")
    H.check(exists(m, "/ccpl/storage.lua"), "ccpl module installed")
    H.check(exists(m, "/configure.lua"), "configure tool installed")
    H.check(exists(m, "/ccpl_install.json"), "record written")
    H.check(m.rebooted == true, "reboots after install")
    H.check(not exists(m, "/ccpl/ui/panel.lua"), "display-only files not installed on a sender")
    H.check(not exists(m, "/.ccpl-staging"), "staging cleaned up")
    -- installed files equal the published ones
    local want = io.open(ROOT.."/dist/sender/startup.lua", "rb"):read("*a")
    H.check(m:read_file("/startup.lua") == want, "startup matches published")

    m.out = {}
    m:run("/install.lua", "check")
    H.has(out(m), "up to date", "check says up to date: " .. out(m))
end)

H.test("installed sender boots into the configuration tool", function()
    local w = new_world(); local m = new_machine(w)
    m:run("/install.lua", "sender", "-y")
    sim.modem(w, m, true)
    m:boot()
    -- the wizard opens by itself: Configure System, next through every page, review, save, close (accepting the defaults)
    local function tap(x, y) m:queue("mouse_click", 1, x, y); m:queue("mouse_up", 1, x, y); w:run(300) end
    tap(5, 6)
    for _ = 1, 5 do tap(46, 18) end
    tap(45, 18)
    tap(4, 18)
    H.check(exists(m, "/ccpl_sender.cfg"), "config written by the first start tool: " .. out(m) .. tostring(m.error))
    H.has(out(m), "no configuration yet", "first start notice")
end)

H.test("check finds changed files and update repairs them", function()
    local w = new_world(); local m = new_machine(w)
    m:run("/install.lua", "display", "-y")
    m:write_file("/ccpl/calc.lua", "-- tampered")
    m.out = {}
    m:run("/install.lua", "check")
    H.has(out(m), "differs from published: ccpl/calc.lua", "tamper detected: " .. out(m))
    m.out = {}
    m:run("/install.lua", "update", "-y")
    H.has(out(m), "repairing", "repair message: " .. out(m))
    local want = io.open(ROOT.."/dist/display/ccpl/calc.lua", "rb"):read("*a")
    H.check(m:read_file("/ccpl/calc.lua") == want, "file repaired")
end)

H.test("update to a newer version removes old files and keeps the config", function()
    local w = new_world(); local m = new_machine(w)
    m:run("/install.lua", "sender", "-y")
    m:write_file("/ccpl_sender.cfg", "return { AuthKey = 'keep this key' }")
    m:write_file("/ccpl/obsolete.lua", "-- old")
    -- record the obsolete file as part of the old install
    local rec = PY.json_decode(m:read_file("/ccpl_install.json"))
    local files = {}
    for i = 1, #rec.files do files[#files + 1] = rec.files[i] end
    files[#files + 1] = "ccpl/obsolete.lua"
    rec.files = files
    m:write_file("/ccpl_install.json", PY.json_encode(rec))

    -- publish version 9.9.9
    local f = io.open(ROOT.."/dist/manifest.json", "rb"); local manifest = PY.json_decode(f:read("*a")); f:close()
    manifest.version = "9.9.9"
    w.http_override = { ["manifest.json"] = PY.json_encode(manifest) }

    m.out = {}
    m:run("/install.lua", "update", "-y")
    H.has(out(m), "0.4.0 -> 9.9.9", "versions shown: " .. out(m))
    H.has(out(m), "removed old ccpl/obsolete.lua", "old file removed")
    H.check(not exists(m, "/ccpl/obsolete.lua"), "obsolete gone")
    H.check(m:read_file("/ccpl_sender.cfg"):find("keep this key", 1, true) ~= nil, "config kept")
    H.has(m:read_file("/ccpl_install.json"), "9.9.9", "record updated")
end)

H.test("a computer installed under the old project name is migrated", function()
    local w = new_world(); local m = new_machine(w)
    m:run("/install.lua", "sender", "-y")

    -- put it back the way the old release (called "ESS Link") left it
    local rec = PY.json_decode(m:read_file("/ess_install.json") or m:read_file("/ccpl_install.json"))
    local files = {}
    for i = 1, #rec.files do files[#files + 1] = rec.files[i] end
    files[#files + 1] = "ess/storage.lua"
    rec.files, rec.version = files, "0.1.0"
    m:write_file("/ess_install.json", PY.json_encode(rec))
    m.env.fs.delete("/ccpl_install.json")
    PY.makedirs(m.root .. "/ess")
    m:write_file("/ess/storage.lua", "-- old program file")
    m:write_file("/ess_sender.cfg", 'return { AuthKey = "keep this key", LogPath = "/ess.log" }')

    m.out = {}
    m:run("/install.lua", "update", "-y")
    H.hasnt(out(m), "failed", "no failures: " .. out(m))
    H.check(not exists(m, "/ess_sender.cfg") and exists(m, "/ccpl_sender.cfg"), "config moved")
    local cfg = m:read_file("/ccpl_sender.cfg")
    H.check(cfg:find("keep this key", 1, true) ~= nil, "config content kept")
    H.check(cfg:find("/ccpl.log", 1, true) ~= nil and cfg:find("/ess.log", 1, true) == nil, "default log path renamed")
    H.check(not exists(m, "/ess_install.json") and exists(m, "/ccpl_install.json"), "record moved")
    H.check(not exists(m, "/ess/storage.lua") and not exists(m, "/ess"), "old program files removed")
    H.check(exists(m, "/ccpl/storage.lua"), "new program files installed")
end)

H.test("a damaged download changes nothing", function()
    local w = new_world(); local m = new_machine(w)
    w.http_override = { ["sender/startup.lua"] = "-- truncated" }
    m:run("/install.lua", "sender", "-y")
    H.has(out(m), "damaged download", "detected: " .. out(m))
    H.check(not exists(m, "/startup.lua"), "nothing installed")
    H.check(not exists(m, "/ccpl_install.json"), "no record")
    H.check(not exists(m, "/.ccpl-staging"), "staging cleaned up")
    H.check(m.rebooted ~= true, "no reboot")
end)

H.test("unreachable server and bad usage", function()
    local w = new_world(); local m = new_machine(w)
    w.http_base = "https://elsewhere.test/"
    m:run("/install.lua", "sender", "-y")
    H.has(out(m), "could not download the manifest", "reports it")
    m.out = {}
    m:run("/install.lua", "bogus")
    H.has(out(m), "usage:", "usage shown")
    m.out = {}
    m:run("/install.lua", "update")
    H.has(out(m), "nothing is installed", "update without install")
end)

H.test("remove keeps the config unless purged", function()
    local w = new_world(); local m = new_machine(w)
    m:run("/install.lua", "sender", "-y")
    m:write_file("/ccpl_sender.cfg", "return {}")
    m:run("/install.lua", "remove", "-y")
    H.check(not exists(m, "/startup.lua") and not exists(m, "/ccpl"), "files and empty dirs removed")
    H.check(exists(m, "/ccpl_sender.cfg"), "config kept")
    H.check(not exists(m, "/ccpl_install.json"), "record removed")

    -- the installer refreshed itself from the (test) build, which has no baked address: point it at the test server again
    m:write_file("/install.lua", (m:read_file("/install.lua"):gsub('local DEFAULT_URL = "[^"]*"', function () return 'local DEFAULT_URL = "' .. BASE .. '"' end)))
    m:run("/install.lua", "sender", "-y")
    m:run("/install.lua", "remove", "--purge", "-y")
    H.check(not exists(m, "/ccpl_sender.cfg"), "config purged: " .. out(m))
end)
return H.done()
