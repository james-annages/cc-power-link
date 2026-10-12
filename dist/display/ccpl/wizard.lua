--
-- cc-power-link Configuration Wizard
-- Touch driven, page by page setup in the style of the cc-mek-scada configurators, drawn with the bundled
-- graphics library on the computer's own terminal (needs an advanced computer)
--

local tcd         = require("scada-common.tcd")

local core        = require("graphics.core")
local themes      = require("graphics.themes")

local DisplayBox  = require("graphics.elements.DisplayBox")
local Div         = require("graphics.elements.Div")
local MultiPane   = require("graphics.elements.MultiPane")
local TextBox     = require("graphics.elements.TextBox")

local PushButton  = require("graphics.elements.controls.PushButton")
local RadioButton = require("graphics.elements.controls.RadioButton")

local NumberField = require("graphics.elements.form.NumberField")
local TextField   = require("graphics.elements.form.TextField")

local config      = require("ccpl.config")

local wizard = {}

local cpair  = core.cpair
local CENTER = core.ALIGN.CENTER

local style = {}

style.root          = cpair(colors.black, colors.lightGray)
style.header        = cpair(colors.white, colors.gray)
style.section       = cpair(colors.black, colors.lightBlue)
style.colors        = themes.smooth_stone.colors
style.bw_fg_bg      = cpair(colors.black, colors.white)
style.g_lg_fg_bg    = cpair(colors.gray, colors.lightGray)
style.nav_fg_bg     = style.bw_fg_bg
style.btn_act_fg_bg = cpair(colors.white, colors.gray)
style.btn_dis_fg_bg = cpair(colors.lightGray, colors.white)
style.error         = cpair(colors.red, colors.lightGray)

-- how the wizard groups the configuration fields into pages (every field of a role must be on exactly one page)
wizard.PAGES = {
    sender = {
        { title = "Network",    keys = { "SenderChannel", "DisplayChannel" } },
        { title = "Security",   keys = { "AuthKey", "TrustedRange", "PeerID" } },
        { title = "Storage",    keys = { "StorageInterface", "StorageTier" } },
        { title = "Timing",     keys = { "SendPeriodMs", "BuildPeriodMs" } },
        { title = "Log",        keys = { "LogPath" } }
    },
    display = {
        { title = "Network",    keys = { "SenderChannel", "DisplayChannel" } },
        { title = "Security",   keys = { "AuthKey", "TrustedRange", "PeerID" } },
        { title = "Monitor",    keys = { "Monitor" } },
        { title = "Appearance", keys = { "EnergyUnit", "Theme", "StaleMs" } },
        { title = "Log",        keys = { "LogPath" } }
    }
}

-- short names and one line hints (49 characters at most) for the fields
wizard.LABELS = {
    SenderChannel = "Sender channel", DisplayChannel = "Display channel", AuthKey = "Auth key",
    TrustedRange = "Trusted range", PeerID = "Peer computer ID", LogPath = "Log file",
    StorageInterface = "Storage", StorageTier = "Core tier label", SendPeriodMs = "State every (ms)",
    BuildPeriodMs = "Build every (ms)", Monitor = "Monitor", EnergyUnit = "Energy unit", Theme = "Theme",
    StaleMs = "Stale after (ms)"
}

wizard.HINTS = {
    SenderChannel = "Channel the sender listens on, same on both",
    DisplayChannel = "Channel the display listens on, same on both",
    AuthKey = "Same on both, 8+ characters, or empty for none",
    TrustedRange = "0 = no limit (must be 0 across dimensions)",
    PeerID = "Computer ID of the other end, 0 = accept any",
    LogPath = "Where this computer writes its log",
    StorageInterface = "The induction port, energy core or other storage",
    StorageTier = "Label an energy core as tier 1-8, 0 = none shown",
    SendPeriodMs = "Milliseconds between state messages (250-10000)",
    BuildPeriodMs = "Milliseconds between build messages (1000-60000)",
    Monitor = "The monitor that shows the panel",
    EnergyUnit = "Unit shown on the panel",
    Theme = "Dark (deepslate) or light (smooth stone)",
    StaleMs = "Show OFF-LINE after this long without data"
}

-- the most options a peripheral list shows (the first is always "automatic")
local MAX_PICK = 6

-- text for a value on the summary page
---@nodiscard
local function show(f, v, reveal)
    if f.secret and not reveal then return (v == "" and "(none)" or string.rep("*", #v)) end
    if v == "" then return "(auto)" end
    return tostring(v)
end

-- run the wizard for a role
---@param role string "sender" or "display"
---@param opts { values: table, load: fun(): table, peripherals: fun(kind: string): { name: string, type: string }[] } starting values, a loader for the saved file, and the peripheral lister
---@return boolean saved true if there is a saved configuration the caller can carry on with
function wizard.run(role, opts)
    local path = config.path(role)
    local fields = config.fields(role)
    local defs = wizard.PAGES[role]
    local values = opts.values

    local by_key = {}
    for _, f in ipairs(fields) do by_key[f.key] = f end

    -- the summary lists the fields in the order of the pages
    local ordered = {}
    for _, def in ipairs(defs) do
        for _, key in ipairs(def.keys) do ordered[#ordered + 1] = by_key[key] end
    end

    local ctl = {}        -- key -> { kind, f, el }
    local picks = {}      -- key -> { holder, names, radio }
    local saved = false
    local running = true
    local reveal = false
    local saved_values = {} -- what the settings file holds, for the view page

    local function has_config() return fs.exists(path) end

    local function exit_wizard() running = false end

    ----------------------------------------
    -- the interface
    ----------------------------------------

    local function build(display)
        local bw_fg_bg, g_lg_fg_bg, nav_fg_bg = style.bw_fg_bg, style.g_lg_fg_bg, style.nav_fg_bg
        local btn_act, btn_dis = style.btn_act_fg_bg, style.btn_dis_fg_bg

        TextBox{parent=display,y=1,text="cc-power-link " .. role .. " configurator",alignment=CENTER,fg_bg=style.header}

        local root = Div{parent=display,y=2}

        local main_page = Div{parent=root,y=1}
        local page_divs = {}
        for i = 1, #defs do page_divs[i] = Div{parent=root,y=1} end
        local summary = Div{parent=root,y=1}
        local done = Div{parent=root,y=1}

        local panes = { main_page }
        for i = 1, #page_divs do panes[#panes + 1] = page_divs[i] end
        panes[#panes + 1] = summary
        panes[#panes + 1] = done

        local pane = MultiPane{parent=root,y=1,panes=panes}

        local FIRST = 2
        local SUMMARY = #defs + 2
        local DONE = #defs + 3

        local summary_title, summary_back_to = nil, 1
        local sum_keys, sum_vals = {}, {}
        local sum_err, save_btn, startup_btn, view_btn

        ---- reading and checking values ----

        -- the current value of a field from its control, nil and a message if it can't be read
        ---@return any|nil value, string|nil error_message
        local function read(key)
            local c = ctl[key]

            if c.kind == "number" then
                local n = tonumber(c.el.get_value())

                if n == nil then return nil, "enter a number" end

                return n, nil
            elseif c.kind == "text" then
                return c.el.get_value(), nil
            elseif c.kind == "choice" then
                return c.f.choices[c.el.get_value()], nil
            end

            local p = picks[key]
            local i = p.radio.get_value()

            return (i == 1) and "" or p.names[i], nil
        end

        -- check the fields of a page and keep their values, returns an error message if one is not acceptable
        ---@nodiscard
        ---@return string|nil error_message
        local function submit(def)
            local found = {}

            for _, key in ipairs(def.keys) do
                local f = by_key[key]
                local v, err = read(key)

                if v == nil then return wizard.LABELS[key] .. ": " .. (err or "choose a value") end
                if type(v) ~= f.type then return wizard.LABELS[key] .. " must be a " .. f.type end
                if f.check and not f.check(v) then return wizard.LABELS[key] .. " " .. (f.err or "is invalid") end

                found[key] = v
            end

            -- one more check that spans two fields
            if found.SenderChannel and found.SenderChannel == found.DisplayChannel then
                return "Sender and display channel must be different"
            end

            for key, v in pairs(found) do values[key] = v end

            return nil
        end

        ---- pages ----

        for index, def in ipairs(defs) do
            local page = page_divs[index]

            TextBox{parent=page,y=1,text=" " .. def.title .. " (" .. index .. "/" .. #defs .. ")",fg_bg=style.section}

            local err = TextBox{parent=page,x=2,y=15,height=2,width=49,text="",fg_bg=style.error}
            local y = 3

            for _, key in ipairs(def.keys) do
                local f = by_key[key]

                TextBox{parent=page,x=2,y=y,width=18,text=wizard.LABELS[key]}

                if f.pick then
                    -- a list of what is attached right now, with "automatic" first
                    local holder = Div{parent=page,x=3,y=y+1,width=47,height=MAX_PICK}
                    picks[key] = { holder = holder, kind = f.pick }
                    ctl[key] = { kind = "pick", f = f }

                    TextBox{parent=page,x=2,y=y+1+MAX_PICK,width=48,text=wizard.HINTS[key],fg_bg=g_lg_fg_bg}

                    y = y + MAX_PICK + 3
                elseif f.choices then
                    local default = 1
                    for i, c in ipairs(f.choices) do if c == values[key] then default = i end end

                    local el = RadioButton{parent=page,x=21,y=y,default=default,options=f.choices,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.blue}
                    ctl[key] = { kind = "choice", f = f, el = el }

                    TextBox{parent=page,x=2,y=y+#f.choices,width=48,text=wizard.HINTS[key],fg_bg=g_lg_fg_bg}

                    y = y + #f.choices + 2
                else
                    local el

                    if f.type == "number" then
                        el = NumberField{parent=page,x=21,y=y,width=10,max_chars=9,default=values[key],allow_decimal=(key == "TrustedRange"),fg_bg=bw_fg_bg}
                        ctl[key] = { kind = "number", f = f, el = el }
                    elseif f.secret then
                        el = TextField{parent=page,x=21,y=y,width=22,max_len=64,value=values[key],censor="*",fg_bg=bw_fg_bg}
                        ctl[key] = { kind = "text", f = f, el = el }

                        PushButton{parent=page,x=44,y=y,min_width=6,text="Show",callback=function()
                            reveal = not reveal
                            el.censor(reveal and nil or "*")
                        end,fg_bg=nav_fg_bg,active_fg_bg=btn_act}
                    else
                        -- the log path is long, so it gets a full width line of its own
                        local wide = (key == "LogPath")

                        el = TextField{parent=page,x=wide and 2 or 21,y=wide and y + 1 or y,width=wide and 48 or 28,max_len=128,value=values[key],fg_bg=bw_fg_bg}
                        ctl[key] = { kind = "text", f = f, el = el }

                        if wide then y = y + 1 end
                    end

                    TextBox{parent=page,x=2,y=y+1,width=48,text=wizard.HINTS[key],fg_bg=g_lg_fg_bg}

                    y = y + 3
                end
            end

            local function back()
                err.set_value("")
                pane.set_value(index) -- the pane before this one (the main page for the first page)
            end

            local function next_page()
                local msg = submit(def)

                if msg then
                    err.set_value(msg)
                    return
                end

                err.set_value("")

                if index == #defs then
                    summary_back_to = index + FIRST - 1 -- the last page, for the summary's back button
                    summary_title.set_value(" Review and save")
                    save_btn.show()
                    pane.set_value(SUMMARY)
                    wizard._render(sum_keys, sum_vals, ordered, values, reveal)
                else
                    pane.set_value(index + FIRST)
                end
            end

            PushButton{parent=page,x=2,y=17,text="\x1b Back",callback=back,fg_bg=nav_fg_bg,active_fg_bg=btn_act}
            PushButton{parent=page,x=44,y=17,text=(index == #defs) and "Review" or "Next \x1a",min_width=6,callback=next_page,fg_bg=nav_fg_bg,active_fg_bg=btn_act}
        end

        ---- summary ----

        summary_title = TextBox{parent=summary,y=1,text=" Review and save",fg_bg=style.section}

        for i, f in ipairs(ordered) do
            sum_keys[i] = TextBox{parent=summary,x=2,y=2 + i,width=19,text=wizard.LABELS[f.key]}
            sum_vals[i] = TextBox{parent=summary,x=22,y=2 + i,width=28,text="",fg_bg=style.bw_fg_bg}
        end

        sum_err = TextBox{parent=summary,x=2,y=15,height=2,width=49,text="",fg_bg=style.error}

        local function summary_back()
            sum_err.set_value("")
            pane.set_value(summary_back_to)
        end

        PushButton{parent=summary,x=2,y=17,text="\x1b Back",callback=summary_back,fg_bg=nav_fg_bg,active_fg_bg=btn_act}
        PushButton{parent=summary,x=16,y=17,min_width=13,text="Show/Hide key",callback=function()
            reveal = not reveal
            wizard._render(sum_keys, sum_vals, ordered, summary_back_to == 1 and saved_values or values, reveal)
        end,fg_bg=nav_fg_bg,active_fg_bg=btn_act}

        local function save()
            local ok, msg = config.save(path, role, values)

            if not ok then
                sum_err.set_value("cannot save: " .. tostring(msg))
                return
            end

            saved = true
            sum_err.set_value("")
            startup_btn.show()
            view_btn.enable()
            pane.set_value(DONE)
        end

        save_btn = PushButton{parent=summary,x=43,y=17,min_width=8,text="Save",callback=save,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act}

        ---- saved ----

        TextBox{parent=done,y=1,text=" Settings saved",fg_bg=style.section}
        TextBox{parent=done,x=2,y=3,height=4,width=48,text="Your settings were written to " .. path .. ". Reboot the computer to apply them, or close this tool to carry on."}

        PushButton{parent=done,x=2,y=17,min_width=7,text="Close",callback=exit_wizard,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act}
        PushButton{parent=done,x=36,y=17,min_width=14,text="Reboot now",callback=function() os.reboot() end,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act}

        ---- main page ----

        TextBox{parent=main_page,x=2,y=2,height=3,width=48,text="Welcome to the " .. role .. " configurator! Please select one of the following options."}

        PushButton{parent=main_page,x=2,y=5,min_width=18,text="Configure System",callback=function() pane.set_value(FIRST) end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act}

        view_btn = PushButton{parent=main_page,x=2,y=7,min_width=20,text="View Configuration",callback=function()
            saved_values = opts.load()
            summary_back_to = 1
            summary_title.set_value(" Current configuration")
            save_btn.hide(true)
            wizard._render(sum_keys, sum_vals, ordered, saved_values, reveal)
            pane.set_value(SUMMARY)
        end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act,dis_fg_bg=btn_dis}

        TextBox{parent=main_page,x=2,y=10,width=48,text="Settings file: " .. path,fg_bg=g_lg_fg_bg}

        PushButton{parent=main_page,x=2,y=17,min_width=6,text="Exit",callback=exit_wizard,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act}
        startup_btn = PushButton{parent=main_page,x=42,y=17,min_width=9,text="Startup",callback=exit_wizard,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act}

        if not has_config() then
            view_btn.disable()
            startup_btn.hide(true)
        end
    end

    -- fill the lists of attached peripherals (also when something is attached or removed)
    local function refresh_picks()
        for key, p in pairs(picks) do
            local found = opts.peripherals(p.kind)
            local current = values[key]

            local names, labels = { "" }, { "Automatic" }

            if current ~= "" then
                names[#names + 1] = current
                labels[#labels + 1] = current .. " (not found)"
            end

            for _, per in ipairs(found) do
                if per.name == current then
                    labels[#names] = per.name .. " (" .. per.type .. ")"
                elseif #names < MAX_PICK then
                    names[#names + 1] = per.name
                    labels[#labels + 1] = per.name .. " (" .. per.type .. ")"
                end
            end

            -- keep what is selected right now, if there is a radio button already
            local want = current

            if p.radio then
                local i = p.radio.get_value()
                want = (i == 1) and "" or p.names[i]
            end

            local default = 1
            for i, n in ipairs(names) do if n == want then default = i end end

            p.holder.remove_all()
            p.names = names
            p.radio = RadioButton{parent=p.holder,default=default,options=labels,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.blue}
        end
    end

    ----------------------------------------
    -- run
    ----------------------------------------

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    for i = 1, #style.colors do term.setPaletteColor(style.colors[i].c, style.colors[i].hex) end

    local ok, err = pcall(function ()
        local display = DisplayBox{window=term.current(),fg_bg=style.root}

        -- the pages are built first so that the lists below have somewhere to go
        build(display)
        refresh_picks()

        while running do
            local event, p1, p2, p3 = os.pullEventRaw()

            if event == "timer" then
                tcd.handle(p1)
            elseif event == "mouse_click" or event == "mouse_up" or event == "mouse_drag" or event == "mouse_scroll" or event == "double_click" then
                local m_e = core.events.new_mouse_event(event, p1, p2, p3)
                if m_e then display.handle_mouse(m_e) end
            elseif event == "char" or event == "key" or event == "key_up" then
                local k_e = core.events.new_key_event(event, p1, p2)
                if k_e then display.handle_key(k_e) end
            elseif event == "paste" then
                display.handle_paste(p1)
            elseif event == "peripheral" or event == "peripheral_detach" or event == "monitor_resize" then
                refresh_picks()
            elseif event == "terminate" then
                running = false
            end
        end
    end)

    -- put the palette and the screen back
    if term.nativePaletteColor then
        for i = 1, #style.colors do
            local r, g, b = term.nativePaletteColor(style.colors[i].c)
            term.setPaletteColor(style.colors[i].c, r, g, b)
        end
    end

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    if not ok then print("configurator error: " .. tostring(err)) end

    return saved
end

-- write a settings table onto the summary page's text boxes
---@param key_boxes table[]
---@param val_boxes table[]
---@param fields ccpl_field[]
---@param vals table
---@param reveal boolean show the auth key
function wizard._render(key_boxes, val_boxes, fields, vals, reveal)
    for i, f in ipairs(fields) do
        key_boxes[i].set_value(wizard.LABELS[f.key])

        local text = show(f, vals[f.key], reveal)

        if #text > 28 then text = text:sub(1, 25) .. "..." end

        val_boxes[i].set_value(text)
    end
end

return wizard
