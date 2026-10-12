--
-- cc-power-link Induction Matrix Panel
-- Adapted from cc-mek-scada's coordinator/ui/components/imatrix.lua
-- (same layout and graphics elements, fed from a local psil instead of the coordinator's ioctl)
--

local util           = require("scada-common.util")

local style          = require("ccpl.ui.style")

local core           = require("graphics.core")

local Div            = require("graphics.elements.Div")
local Rectangle      = require("graphics.elements.Rectangle")
local TextBox        = require("graphics.elements.TextBox")

local DataIndicator  = require("graphics.elements.indicators.DataIndicator")
local IndicatorLight = require("graphics.elements.indicators.IndicatorLight")
local PowerIndicator = require("graphics.elements.indicators.PowerIndicator")
local StateIndicator = require("graphics.elements.indicators.StateIndicator")
local VerticalBar    = require("graphics.elements.indicators.VerticalBar")

local cpair = core.cpair
local border = core.border

local ALIGN = core.ALIGN

local panel = {}

-- size of the panel in characters (fits a 2x2 advanced monitor at text scale 0.5)
panel.WIDTH  = 33
panel.HEIGHT = 24

-- create the induction matrix panel<br>
-- the panel subscribes to these keys of the provided psil, which hold values already converted to the display unit:<br>
-- computed_status, max_energy, energy, avg_charge, last_input, avg_inflow, last_output, avg_outflow, transfer_cap,
-- energy_fill (0.0 to 1.0), title, subtitle, line_a, line_b (strings), is_charging, is_discharging, at_max_io, eta_string, in_sat, out_sat
---@param root Container parent
---@param x integer top left x
---@param y integer top left y
---@param ps psil ps interface
---@param unit string energy unit label, such as "FE"
function panel.new(root, x, y, ps, unit)
    local label_fg = style.theme.label_fg
    local text_fg = style.theme.text_fg
    local lu_col = style.lu_colors

    local ind_yel = style.ind_yel
    local ind_wht = style.ind_wht

    local title = "ENERGY STORAGE"

    local matrix = Div{parent=root,fg_bg=style.root,width=panel.WIDTH,height=panel.HEIGHT,x=x,y=y}

    -- black has low contrast with dark gray, so if background is black use white instead
    local cutout_fg_bg = cpair(util.trinary(style.theme.bg == colors.black, colors.white, style.theme.bg), colors.gray)

    TextBox{parent=matrix,text=" ",width=33,y=1,fg_bg=cutout_fg_bg}
    local title_box = TextBox{parent=matrix,text=title,alignment=ALIGN.CENTER,width=33,y=2,fg_bg=cutout_fg_bg}

    title_box.register(ps, "title", title_box.set_value)

    local rect = Rectangle{parent=matrix,border=border(1,colors.gray,true),width=33,height=22,y=3}

    local subtitle  = TextBox{parent=rect,x=7,y=2,width=26,text="",alignment=ALIGN.CENTER,fg_bg=label_fg}
    local status    = StateIndicator{parent=rect,x=10,y=1,states=style.states,value=1,min_width=14}
    local capacity  = PowerIndicator{parent=rect,x=7,y=3,lu_colors=lu_col,label="Capacity:",unit=unit,format="%8.2f",value=0,width=26,fg_bg=text_fg}
    local energy    = PowerIndicator{parent=rect,x=7,y=4,lu_colors=lu_col,label="Energy:  ",unit=unit,format="%8.2f",value=0,width=26,fg_bg=text_fg}
    local avg_chg   = PowerIndicator{parent=rect,x=7,y=5,lu_colors=lu_col,label="\xb7Average:",unit=unit,format="%8.2f",value=0,width=26,fg_bg=text_fg}
    local input     = PowerIndicator{parent=rect,x=7,y=6,lu_colors=lu_col,label="Input:   ",unit=unit,format="%8.2f",rate=true,value=0,width=26,fg_bg=text_fg}
    local avg_in    = PowerIndicator{parent=rect,x=7,y=7,lu_colors=lu_col,label="\xb7Average:",unit=unit,format="%8.2f",rate=true,value=0,width=26,fg_bg=text_fg}
    local output    = PowerIndicator{parent=rect,x=7,y=8,lu_colors=lu_col,label="Output:  ",unit=unit,format="%8.2f",rate=true,value=0,width=26,fg_bg=text_fg}
    local avg_out   = PowerIndicator{parent=rect,x=7,y=9,lu_colors=lu_col,label="\xb7Average:",unit=unit,format="%8.2f",rate=true,value=0,width=26,fg_bg=text_fg}
    local trans_cap = PowerIndicator{parent=rect,x=7,y=10,lu_colors=lu_col,label="Max I/O: ",unit=unit,format="%8.2f",rate=true,value=0,width=26,fg_bg=text_fg}

    status.register(ps, "computed_status", status.update)
    capacity.register(ps, "max_energy", capacity.update)
    energy.register(ps, "energy", energy.update)
    avg_chg.register(ps, "avg_charge", avg_chg.update)
    input.register(ps, "last_input", input.update)
    avg_in.register(ps, "avg_inflow", avg_in.update)
    output.register(ps, "last_output", output.update)
    avg_out.register(ps, "avg_outflow", avg_out.update)
    trans_cap.register(ps, "transfer_cap", trans_cap.update)

    local fill      = DataIndicator{parent=rect,x=11,y=12,lu_colors=lu_col,label="Fill:     ",format="%7.2f",unit="%",value=0,width=20,fg_bg=text_fg}
    local line_a    = TextBox{parent=rect,x=11,y=13,width=20,text="",fg_bg=text_fg}
    local line_b    = TextBox{parent=rect,x=11,y=14,width=20,text="",fg_bg=text_fg}

    fill.register(ps, "energy_fill", function (val) fill.update(val * 100) end)
    subtitle.register(ps, "subtitle", subtitle.set_value)
    line_a.register(ps, "line_a", line_a.set_value)
    line_b.register(ps, "line_b", line_b.set_value)

    local chging = IndicatorLight{parent=rect,x=11,y=16,label="Charging",colors=ind_wht}
    local dischg = IndicatorLight{parent=rect,x=11,y=17,label="Discharging",colors=ind_wht}
    local max_io = IndicatorLight{parent=rect,x=11,y=18,label="Max I/O Rate",colors=ind_yel}

    chging.register(ps, "is_charging", chging.update)
    dischg.register(ps, "is_discharging", dischg.update)
    max_io.register(ps, "at_max_io", max_io.update)

    local charge  = VerticalBar{parent=rect,x=2,y=2,fg_bg=cpair(colors.green,colors.gray),height=17,width=4}
    local in_cap  = VerticalBar{parent=rect,x=7,y=12,fg_bg=cpair(colors.red,colors.gray),height=7,width=1}
    local out_cap = VerticalBar{parent=rect,x=9,y=12,fg_bg=cpair(colors.blue,colors.gray),height=7,width=1}

    TextBox{parent=rect,text="FILL I/O",x=2,y=20,width=8,fg_bg=label_fg}

    charge.register(ps, "energy_fill", charge.update)
    in_cap.register(ps, "in_sat", in_cap.update)
    out_cap.register(ps, "out_sat", out_cap.update)

    local eta = TextBox{parent=rect,x=11,y=20,width=20,text="ETA Unknown",alignment=ALIGN.CENTER,fg_bg=style.theme.field_box}

    eta.register(ps, "eta_string", eta.set_value)
end

return panel
