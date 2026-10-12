--
-- ComputerCraft simulator for testing cc-power-link
-- Runs the real startup scripts and the real cc-mek-scada libraries (from dist/) against stubs of the
-- CC APIs they use: several computers, a wireless modem bus, monitors/windows, timers, fs, peripherals.
--

local sim = {}

----------------------------------------------------------------------------------------------------
-- colors
----------------------------------------------------------------------------------------------------

local COLOR_NAMES = { "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
                      "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }

local function make_colors()
    local c = {}

    for i, name in ipairs(COLOR_NAMES) do c[name] = 2 ^ (i - 1) end

    c.grey, c.lightGrey = c.gray, c.lightGray

    function c.toBlit(col)
        return string.format("%x", math.floor(math.log(col) / math.log(2) + 0.5))
    end

    return c
end

----------------------------------------------------------------------------------------------------
-- windows / monitors / terminal
----------------------------------------------------------------------------------------------------

-- create a window (or a root surface when parent is nil), behaving like CC's window API
local function new_window(colors, parent, x, y, w, h, visible)
    local self = {
        parent = parent, x = x, y = y, w = w, h = h, visible = visible ~= false,
        cx = 1, cy = 1, fg = colors.white, bg = colors.black,
        lines = {}, palette = {}, scale = 1
    }

    local WHITE, BLACK = colors.toBlit(colors.white), colors.toBlit(colors.black)

    local function blank_line(width)
        return { text = string.rep(" ", width), fg = string.rep(WHITE, width), bg = string.rep(BLACK, width) }
    end

    for row = 1, h do self.lines[row] = blank_line(w) end

    local W = {}

    -- write a string into the buffer at (px, py), clipped, then pass it up if visible
    local function store(px, py, text, fgs, bgs)
        if py < 1 or py > self.h then return end

        -- clip horizontally
        if px < 1 then
            local cut = 1 - px
            text, fgs, bgs = text:sub(cut + 1), fgs:sub(cut + 1), bgs:sub(cut + 1)
            px = 1
        end
        if px + #text - 1 > self.w then
            local keep = self.w - px + 1
            if keep <= 0 then return end
            text, fgs, bgs = text:sub(1, keep), fgs:sub(1, keep), bgs:sub(1, keep)
        end
        if #text == 0 then return end

        local ln = self.lines[py]
        ln.text = ln.text:sub(1, px - 1) .. text .. ln.text:sub(px + #text)
        ln.fg   = ln.fg:sub(1, px - 1) .. fgs .. ln.fg:sub(px + #text)
        ln.bg   = ln.bg:sub(1, px - 1) .. bgs .. ln.bg:sub(px + #text)

        if self.visible and self.parent then
            self.parent.__blit(self.x + px - 1, self.y + py - 1, text, fgs, bgs)
        end
    end

    W.__blit = store

    function W.getSize() return self.w, self.h end
    function W.getPosition() return self.x, self.y end
    function W.setCursorPos(cx, cy) self.cx, self.cy = cx, cy end
    function W.getCursorPos() return self.cx, self.cy end
    function W.setCursorBlink() end
    function W.setTextColor(c) self.fg = c end
    function W.getTextColor() return self.fg end
    function W.setBackgroundColor(c) self.bg = c end
    function W.getBackgroundColor() return self.bg end
    function W.isColor() return true end
    W.setTextColour, W.getTextColour = W.setTextColor, W.getTextColor
    W.setBackgroundColour, W.getBackgroundColour = W.setBackgroundColor, W.getBackgroundColor
    W.isColour = W.isColor

    -- monitor-only
    function W.setTextScale(s) self.scale = s end
    function W.getTextScale() return self.scale end
    function W.setPaletteColor(c, hex) self.palette[c] = hex end
    function W.getPaletteColor(c) return self.palette[c] end
    W.setPaletteColour, W.getPaletteColour = W.setPaletteColor, W.getPaletteColor

    function W.write(text)
        text = tostring(text)
        local n = #text
        store(self.cx, self.cy, text, string.rep(colors.toBlit(self.fg), n), string.rep(colors.toBlit(self.bg), n))
        self.cx = self.cx + n
    end

    function W.blit(text, fgs, bgs)
        assert(#text == #fgs and #text == #bgs, "blit strings must be the same length")
        store(self.cx, self.cy, text, fgs, bgs)
        self.cx = self.cx + #text
    end

    local function fill_row(row)
        local n = self.w
        store(1, row, string.rep(" ", n), string.rep(colors.toBlit(self.fg), n), string.rep(colors.toBlit(self.bg), n))
    end

    function W.clear() for row = 1, self.h do fill_row(row) end end
    function W.clearLine() fill_row(self.cy) end

    function W.scroll(n)
        local old = self.lines
        self.lines = {}
        for row = 1, self.h do self.lines[row] = old[row + n] or blank_line(self.w) end
        W.redraw()
    end

    function W.redraw()
        if self.visible and self.parent then
            for row = 1, self.h do
                local ln = self.lines[row]
                self.parent.__blit(self.x, self.y + row - 1, ln.text, ln.fg, ln.bg)
            end
        end
    end

    function W.setVisible(v)
        self.visible = v
        if v then W.redraw() end
    end

    function W.isVisible() return self.visible end

    function W.reposition(nx, ny, nw, nh)
        self.x, self.y = nx, ny
        if nw and nh and (nw ~= self.w or nh ~= self.h) then
            local old = self.lines
            self.lines = {}
            for row = 1, nh do
                local ln = blank_line(nw)
                if old[row] then
                    ln.text = (old[row].text .. ln.text):sub(1, nw)
                    ln.fg = (old[row].fg .. ln.fg):sub(1, nw)
                    ln.bg = (old[row].bg .. ln.bg):sub(1, nw)
                end
                self.lines[row] = ln
            end
            self.w, self.h = nw, nh
        end
        W.redraw()
    end

    -- test helper: the visible text of this surface, one string per row
    function W.dump()
        local rows = {}
        for row = 1, self.h do rows[row] = self.lines[row].text end
        return rows
    end

    -- test helper: the foreground and background color letters of a row
    function W.dump_colors(row) return self.lines[row].fg, self.lines[row].bg end

    return W
end

----------------------------------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------------------------------

local function deep_copy(v)
    if type(v) ~= "table" then return v end

    local c = {}
    for k, x in pairs(v) do c[deep_copy(k)] = deep_copy(x) end
    return c
end

sim.deep_copy = deep_copy

-- deterministic serialization, enough for the header tables the NIC authenticates
local function serialize(v)
    if type(v) == "table" then
        local parts = {}
        for i = 1, #v do parts[#parts + 1] = serialize(v[i]) end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif type(v) == "string" then return string.format("%q", v)
    else return tostring(v) end
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

----------------------------------------------------------------------------------------------------
-- world
----------------------------------------------------------------------------------------------------

---@class sim_world
local World = {}
World.__index = World

-- create a new world
-- py: table of Python helper functions { copytree(src, dst), rmtree(path) }
function sim.new_world(py)
    local w = setmetatable({
        py = py,
        colors = make_colors(),
        T = 1760000000000,     -- epoch milliseconds
        machines = {},
        actions = {},          -- { at = ms, fn = function }
        next_timer = 1,
        -- distance reported to a receiver, nil models a message sent from another dimension
        distance = 10,
        sandbox_n = 0
    }, World)

    return w
end

-- schedule a function to run at a simulated time (ms from now)
function World:at(ms_from_now, fn)
    table.insert(self.actions, { at = self.T + ms_from_now, fn = fn })
    table.sort(self.actions, function (a, b) return a.at < b.at end)
end

---@class sim_machine
local Machine = {}
Machine.__index = Machine

-- create a computer whose file system is a fresh copy of the built tree dist/<role>
function World:add_machine(spec)
    self.sandbox_n = self.sandbox_n + 1

    local m = setmetatable({
        world = self, name = spec.name, id = spec.id,
        root = spec.sandbox_root .. "/" .. self.sandbox_n .. "_" .. spec.name,
        events = {}, timers = {}, devices = {}, out = {}, exited = false, error = nil
    }, Machine)

    self.py.rmtree(m.root)
    self.py.copytree(spec.dist, m.root)

    self.machines[#self.machines + 1] = m

    m:build_env()

    return m
end

function Machine:build_env()
    local world, m = self.world, self
    local colors = world.colors

    local env = {}
    for k, v in pairs(_G) do env[k] = v end
    env._G = env

    -- terminal
    local termwin = new_window(colors, nil, 1, 1, 51, 19)
    self.term = termwin

    local function term_newline()
        local cx, cy = termwin.getCursorPos()
        local _, h = termwin.getSize()
        if cy >= h then
            termwin.scroll(1)
            termwin.setCursorPos(1, h)
        else
            termwin.setCursorPos(1, cy + 1)
        end
    end

    env.colors, env.colours = colors, colors

    env.term = setmetatable({
        current = function () return termwin end,
        write = termwin.write,
        clear = termwin.clear,
        clearLine = termwin.clearLine,
        setCursorPos = termwin.setCursorPos,
        getCursorPos = termwin.getCursorPos,
        getSize = termwin.getSize,
        setTextColor = termwin.setTextColor,
        setBackgroundColor = termwin.setBackgroundColor,
        scroll = termwin.scroll
    }, { __index = termwin })

    env.print = function (...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, "\t")
        m.out[#m.out + 1] = line
        termwin.write(line)
        term_newline()
    end

    env.keys = setmetatable({ getName = function () return "key" end }, { __index = function () return 0 end })

    env.textutils = { serialize = serialize }
    env.term.isColor = function () return true end

    -- window API: window.create(parent, x, y, w, h, visible)
    env.window = {
        create = function (parent, x, y, w, h, visible)
            return new_window(colors, parent, x, y, w, h, visible)
        end
    }

    -- file system, rooted at this computer's sandbox
    local function real(path) return self.root .. "/" .. path:gsub("^/+", "") end

    local function isfile(p) local f = io.open(real(p), "r"); if f then f:close() return not world.py.isdir(real(p)) end return false end

    env.fs = {
        exists = function (p) return isfile(p) or world.py.isdir(real(p)) end,
        isDir = function (p) return world.py.isdir(real(p)) end,
        list = function (p) return world.py.listdir(real(p)) end,
        getDir = function (p) return (p:gsub("^/+", ""):match("^(.*)/[^/]*$") or "") end,
        delete = function (p) world.py.remove(real(p)) end,
        move = function (a, b) world.py.move(real(a), real(b)) end,
        getFreeSpace = function () return 1e9 end,
        open = function (p, mode)
            mode = (mode or "r"):gsub("b", "")
            if mode == "w" or mode == "a" then
                local dir = real(p):match("^(.*)/[^/]*$")
                if dir then world.py.makedirs(dir) end
            end
            local f = io.open(real(p), mode == "a" and "a" or mode == "w" and "w" or "r")
            if not f then return nil, "no such file" end
            return {
                write = function (s) f:write(s) end,
                writeLine = function (s) f:write(s, "\n") end,
                flush = function () f:flush() end,
                close = function () f:close() end,
                readAll = function () return f:read("*a") end,
                readLine = function () return f:read("*l") end
            }
        end
    }

    -- http: serves files from a local folder for URLs under world.http_root (set by the test)
    env.http = {
        get = function (arg)
            local url = type(arg) == "table" and arg.url or arg
            local prefix = world.http_base
            if not prefix or url:sub(1, #prefix) ~= prefix then return nil, "connection refused" end
            local rel = url:sub(#prefix + 1)
            if world.http_override and world.http_override[rel] then
                local body = world.http_override[rel]
                return { readAll = function () return body end, close = function () end }
            end
            local f = io.open(world.http_root .. "/" .. rel, "rb")
            if not f then return nil, "404" end
            local body = f:read("*a")
            f:close()
            return { readAll = function () return body end, close = function () end }
        end
    }

    env.sleep = function () end
    env.read = function () local v = table.remove(world.inputs or {}, 1); return v end
    env.write = function (s) termwin.write(s) end
    env.textutils.serializeJSON = function (t) return world.py.json_encode(t) end
    env.textutils.unserializeJSON = function (s) return world.py.json_decode(s) end

    env.loadfile = function (p, mode, fenv) return loadfile(real(p), "t", fenv or env) end

    -- time, timers, events
    local real_os = os
    env.os = setmetatable({
        epoch = function () return world.T end,
        getComputerID = function () return m.id end,
        startTimer = function (t)
            local id = world.next_timer
            world.next_timer = id + 1
            m.timers[id] = world.T + math.floor(t * 1000 + 0.5)
            return id
        end,
        cancelTimer = function (id) m.timers[id] = nil end,
        queueEvent = function (...) m.events[#m.events + 1] = { ... } end,
        pullEventRaw = function () return coroutine.yield() end,
        pullEvent = function () return coroutine.yield() end,
        -- CC accepts the C99 specifiers %F and %T, Lua 5.2 does not
        date = function (fmt, t)
            fmt = (fmt or "%c"):gsub("%%F", "%%Y-%%m-%%d"):gsub("%%T", "%%H:%%M:%%S")
            return real_os.date(fmt, t or math.floor(world.T / 1000))
        end
    }, { __index = real_os })

    -- peripherals
    env.peripheral = {
        getNames = function ()
            local names = {}
            for name in pairs(m.devices) do names[#names + 1] = name end
            table.sort(names)
            return names
        end,
        getType = function (name) return m.devices[name] and m.devices[name].type or nil end,
        isPresent = function (name) return m.devices[name] ~= nil end,
        -- like CC, every wrap returns a new table
        wrap = function (name)
            local d = m.devices[name]
            if not d then return nil end
            local t = {}
            for k, v in pairs(d.methods) do t[k] = v end
            return t
        end
    }

    -- module loader (stands in for CC's cc.require and the initial require)
    local builtin = {
        ["cc.strings"] = {
            ensure_width = function (s, width)
                if #s < width then return s .. string.rep(" ", width - #s) end
                return s:sub(1, width)
            end,
            wrap = function (s) return { s } end
        }
    }

    local function make_require(menv)
        local loaded = {}
        for _, lib in ipairs({ "string", "math", "table", "os", "io", "coroutine", "debug", "bit32" }) do
            loaded[lib] = _G[lib]
        end

        local function req(name)
            if loaded[name] ~= nil then return loaded[name] end
            if builtin[name] then return builtin[name] end

            local rel = name:gsub("^/+", ""):gsub("%.", "/")
            local path
            for _, cand in ipairs({ rel .. ".lua", rel .. "/init.lua" }) do
                local f = io.open(real(cand), "r")
                if f then f:close() path = real(cand) break end
            end

            if not path then error("module '" .. name .. "' not found", 2) end

            local chunk, err = loadfile(path, "t", menv)
            if not chunk then error(err, 2) end

            local result = chunk(name)
            if result == nil then result = true end
            loaded[name] = result
            return result
        end

        return req, { loaded = loaded, path = "?.lua" }
    end

    -- the bootstrap require only knows how to find /initenv and cc.require, as on a fresh CC computer
    builtin["cc.require"] = {
        make = function (menv, _dir) return make_require(menv) end
    }

    env.os.reboot = function () m.rebooted = true end

    env.require, env.package = make_require(env)

    self.env = env
end

-- add a peripheral to this computer (and notify the program if it is running)
function Machine:attach(name, ptype, methods, silent)
    self.devices[name] = { type = ptype, methods = methods }
    if not silent then self.events[#self.events + 1] = { "peripheral", name } end
end

-- remove a peripheral from this computer (and notify the program)
function Machine:detach(name, silent)
    self.devices[name] = nil
    if not silent then self.events[#self.events + 1] = { "peripheral_detach", name } end
end

-- queue an event for this computer
function Machine:queue(...) self.events[#self.events + 1] = { ... } end

-- write a file into the sandbox
function Machine:write_file(path, contents)
    local f = assert(io.open(self.root .. "/" .. path:gsub("^/+", ""), "w"))
    f:write(contents)
    f:close()
end

-- read a file from the sandbox
function Machine:read_file(path) return read_file(self.root .. "/" .. path:gsub("^/+", "")) end

-- load a module through this computer's loader (for unit tests)
function Machine:require(name) return self.env.require(name) end

-- start the computer's startup program in a coroutine
function Machine:boot(entry)
    local chunk, err = loadfile(self.root .. "/" .. (entry or "startup.lua"), "t", self.env)

    assert(chunk, err)

    self.co = coroutine.create(chunk)
    self.exited, self.error = false, nil
    self:resume()
end

-- resume the program with an event
function Machine:resume(...)
    if self.exited then return end

    local ok, err = coroutine.resume(self.co, ...)

    if not ok then
        self.exited, self.error = true, tostring(err)
    elseif coroutine.status(self.co) == "dead" then
        self.exited = true
    end
end

-- run a script to completion with arguments (for command line programs such as the installer)
function Machine:run(path, ...)
    local chunk, err = loadfile(self.root .. "/" .. path:gsub("^/+", ""), "t", self.env)

    assert(chunk, err)

    local co = coroutine.create(chunk)
    local ok, e = coroutine.resume(co, ...)

    if not ok then self.error = tostring(e) end

    return ok
end

-- all text the program printed
function Machine:printed() return table.concat(self.out, "\n") end

-- create a wireless (or wired) modem device for a computer
function sim.modem(world, machine, wireless)
    local open = {}

    local modem = { open = open }

    local methods = {
        isWireless = function () return wireless ~= false end,
        open = function (ch) open[ch] = true end,
        close = function (ch) open[ch] = nil end,
        closeAll = function () for k in pairs(open) do open[k] = nil end end,
        isOpen = function (ch) return open[ch] == true end,
        transmit = function (dest, reply, msg)
            modem.last = msg
            for _, other in ipairs(world.machines) do
                if other ~= machine and other.modem and other.modem.open[dest] then
                    other:queue("modem_message", other.modem.name, dest, reply, deep_copy(msg), world.distance)
                end
            end
        end
    }

    modem.methods = methods
    modem.name = "back"
    machine.modem = modem

    machine:attach(modem.name, "modem", methods, true)

    return modem
end

-- create a monitor device, returns the monitor's window (use .dump() to read the screen)
function sim.monitor(world, machine, name, w, h)
    local win = new_window(world.colors, nil, 1, 1, w, h)

    machine:attach(name, "monitor", {
        getSize = win.getSize, setCursorPos = win.setCursorPos, getCursorPos = win.getCursorPos,
        setTextColor = win.setTextColor, getTextColor = win.getTextColor,
        setBackgroundColor = win.setBackgroundColor, getBackgroundColor = win.getBackgroundColor,
        write = win.write, blit = win.blit, clear = win.clear, clearLine = win.clearLine, scroll = win.scroll,
        setCursorBlink = win.setCursorBlink, isColor = win.isColor, setTextScale = win.setTextScale,
        getTextScale = win.getTextScale, setPaletteColor = win.setPaletteColor, getPaletteColor = win.getPaletteColor,
        -- window.create() needs these from a parent
        getPosition = win.getPosition, setVisible = win.setVisible, isVisible = win.isVisible,
        redraw = win.redraw, reposition = win.reposition,
        __blit = win.__blit
    }, true)

    return win
end

-- create an induction matrix device whose readings come from a mutable state table
function sim.matrix(machine, name, ptype, st)
    local function need() if not st.formed then error("Multiblock not formed", 0) end end

    local methods = {
        isFormed = function () return st.formed end,
        getEnergy = function () need() return st.energy end,
        getEnergyFilledPercentage = function () need() return st.energy / st.max end,
        getEnergyNeeded = function () need() return st.max - st.energy end,
        getMaxEnergy = function () need() return st.max end,
        getTransferCap = function () need() return st.transfer end,
        getLastInput = function () need() return st.input end,
        getLastOutput = function () need() return st.output end,
        getInstalledCells = function () need() return st.cells end,
        getInstalledProviders = function () need() return st.providers end,
        getLength = function () need() return 5 end,
        getWidth = function () need() return 5 end,
        getHeight = function () need() return 5 end
    }

    machine:attach(name, ptype or "inductionPort", methods, true)

    return methods
end

-- create a Draconic Evolution energy core device (peripheral type draconic_rf_storage)
function sim.draconic_core(machine, name, st)
    local methods = {
        getEnergyStored = function () return st.energy end,
        getMaxEnergyStored = function () return st.capacity end,
        getInputPerTick = function () return st.input or 0 end,
        getOutputPerTick = function () return st.output or 0 end,
        getTransferPerTick = function () return (st.input or 0) - (st.output or 0) end
    }

    machine:attach(name, "draconic_rf_storage", methods, true)

    return methods
end

-- create a generic energy storage device (what CC:Tweaked exposes for blocks with an energy capability)
function sim.energy_storage(machine, name, st, methods)
    local m = methods or { "getEnergy", "getEnergyCapacity" }
    local methods_t = {}
    methods_t[m[1]] = function () return st.energy end
    methods_t[m[2]] = function () return st.capacity end

    machine:attach(name, "energy_storage", methods_t, true)

    return methods_t
end

----------------------------------------------------------------------------------------------------
-- scheduler
----------------------------------------------------------------------------------------------------

-- run the world for a number of simulated milliseconds
function World:run(duration_ms)
    local stop = self.T + duration_ms
    local guard = 0

    while true do
        guard = guard + 1
        if guard > 200000 then error("simulation did not settle (runaway event loop?)") end

        -- 1. deliver any pending event right away
        local delivered = false
        for _, m in ipairs(self.machines) do
            if not m.exited and #m.events > 0 then
                local ev = table.remove(m.events, 1)
                m:resume(table.unpack(ev))
                delivered = true
                break
            end
        end

        if not delivered then
            -- 2. find the next thing in time: a timer or a scheduled action
            local next_t, kind, who, tid = nil, nil, nil, nil

            for _, m in ipairs(self.machines) do
                if not m.exited then
                    for id, at in pairs(m.timers) do
                        if next_t == nil or at < next_t then next_t, kind, who, tid = at, "timer", m, id end
                    end
                end
            end

            if self.actions[1] and (next_t == nil or self.actions[1].at <= next_t) then
                next_t, kind = self.actions[1].at, "action"
            end

            if next_t == nil or next_t > stop then
                self.T = stop
                return
            end

            if next_t > self.T then self.T = next_t end

            if kind == "timer" then
                who.timers[tid] = nil
                who.events[#who.events + 1] = { "timer", tid }
            else
                local a = table.remove(self.actions, 1)
                a.fn()
            end
        end
    end
end

return sim
