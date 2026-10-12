--
-- cc-power-link Display Styling
-- Themes and indicator styles taken from cc-mek-scada's coordinator (standard color mode)
--

local core   = require("graphics.core")
local themes = require("graphics.themes")

local cpair = core.cpair

---@class ccpl_style
local style = {}

---@class ccpl_theme
local smooth_stone = {
    text = colors.black,
    label = colors.gray,
    bg = colors.lightGray,

    text_fg = cpair(colors.black, colors._INHERIT),
    label_fg = cpair(colors.gray, colors._INHERIT),

    field_box = cpair(colors.black, colors.white),

    colors = themes.smooth_stone.colors
}

---@type ccpl_theme
local deepslate = {
    text = colors.white,
    label = colors.lightGray,
    bg = colors.black,

    text_fg = cpair(colors.white, colors._INHERIT),
    label_fg = cpair(colors.lightGray, colors._INHERIT),

    field_box = cpair(colors.white, colors.gray),

    colors = themes.deepslate.colors
}

style.theme = deepslate

-- select the theme and derive the styles that depend on it
---@param name string "deepslate" or "smooth_stone"
function style.set_theme(name)
    if name == "smooth_stone" then style.theme = smooth_stone else style.theme = deepslate end

    -- indicator light background (gray in standard color mode)
    style.ind_bkg = colors.gray

    style.root = cpair(style.theme.text, style.theme.bg)

    -- label & unit colors
    style.lu_colors = cpair(style.theme.label, style.theme.label)

    style.ind_yel = cpair(colors.yellow, style.ind_bkg)
    style.ind_wht = cpair(colors.white, style.ind_bkg)
end

-- states shown by the status indicator, in the same order as calc.STATE
style.states = {
    { color = cpair(colors.black, colors.yellow), text = "OFF-LINE" },
    { color = cpair(colors.black, colors.orange), text = "NOT FORMED" },
    { color = cpair(colors.black, colors.orange), text = "READ FAULT" },
    { color = cpair(colors.black, colors.green),  text = "ONLINE" },
    { color = cpair(colors.black, colors.yellow), text = "LOW CHARGE" },
    { color = cpair(colors.black, colors.yellow), text = "HIGH  CHARGE" },
    { color = cpair(colors.black, colors.orange), text = "NO STORAGE" }
}

style.set_theme("deepslate")

return style
