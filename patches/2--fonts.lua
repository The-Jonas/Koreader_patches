--[[
2--fonts.lua — interface font and Project: Title font sizes

Goal: choose the font of KOReader's own interface (menus, dialogs, status bar)
like the book font is chosen, and keep the Project: Title library text at
steady sizes instead of growing and shrinking from book to book.

What it does:
  - Adds Settings → UI font, listing the fonts installed for books. The chosen
    font replaces Noto Sans everywhere in the interface after a restart. Fonts
    without a bold file use the regular file for bold text.
  - Sets the font size limits used by Project: Title. By default it picks the
    largest size that fits each title, so titles end up in different sizes; the
    values below keep them the same.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader. Keep the name
     starting with "2--": the UI font must be set before other patches create
     any text.
  2. Settings → UI font, then restart when asked.
  3. Project: Title sizes: edit PT_SIZES below. Only the values listed change;
     the rest keep the plugin defaults.
]]

local PT_SIZES = {
    list = {
        title_font_max = 20,   -- plugin default 26; same as the minimum, so every title has one size
    },
    grid = {
        dir_font_nominal = 18, -- plugin default 22; folder names on the cover grid
    },
}

local Font = require("ui/font")
local FontList = require("fontlist")
local UIManager = require("ui/uimanager")
local userpatch = require("userpatch")
local _ = require("gettext")
local T = require("ffi/util").template

local DEFAULT_FONT = "Noto Sans"
local REGULAR, BOLD = "NotoSans-Regular.ttf", "NotoSans-Bold.ttf"

-- Font name saved in the settings
local function savedFont()
    return G_reader_settings:readSetting("ui_font_name", DEFAULT_FONT)
end

-- Regular and bold files of every font installed for books, by name
local function installedFonts()
    local cre = require("document/credocument"):engineInit()
    local exists = {}
    for __, path in ipairs(FontList.fontlist) do exists[path] = true end
    local names, files = {}, {}
    for __, name in ipairs(cre.getFontFaces()) do
        local regular = cre.getFontFaceFilenameAndFaceIndex(name)
        if regular and exists[regular] then
            local bold = regular:gsub("%-Regular%.", "-Bold.", 1)
            table.insert(names, name)
            files[name] = { regular = regular, bold = exists[bold] and bold or regular }
        end
    end
    return names, files
end

local font_names, font_files = installedFonts()

-- Interface font entries that use Noto Sans, and whether each is the regular or the bold one
local replaced = {}
for key, file in pairs(Font.fontmap) do
    if file == REGULAR then replaced[key] = "regular" elseif file == BOLD then replaced[key] = "bold" end
end

-- Points the interface font entries to the chosen font
local function applyFont(name)
    local files = font_files[name]
    if not files then return end
    for key, kind in pairs(replaced) do Font.fontmap[key] = files[kind] end
end

if savedFont() ~= DEFAULT_FONT then applyFont(savedFont()) end

-- Settings → UI font: one entry per installed font, each shown in its own typeface
local function fontMenu()
    return {
        text_func = function() return T(_("UI font: %1"), savedFont()) end,
        sub_item_table_func = function()
            local items = {}
            for __, name in ipairs(font_names) do
                table.insert(items, {
                    text = name,
                    font_func = function(size) return Font:getFace(font_files[name].regular, size) end,
                    checked_func = function() return savedFont() == name end,
                    radio = true,
                    callback = function()
                        if name == savedFont() then return end
                        G_reader_settings:saveSetting("ui_font_name", name)
                        UIManager:askForRestart(_("Restart to apply the UI font change"))
                    end,
                })
            end
            return items
        end,
    }
end

-- Adds the UI font entry at the end of the settings tab in both menus
for __, m in ipairs({
    { "apps/filemanager/filemanagermenu", "ui/elements/filemanager_menu_order" },
    { "apps/reader/modules/readermenu", "ui/elements/reader_menu_order" },
}) do
    local Menu, order = require(m[1]), require(m[2])
    local orig = Menu.setUpdateItemTable
    Menu.setUpdateItemTable = function(self, ...)
        if not require("util").arrayContains(order.setting, "ui_font") then
            table.insert(order.setting, "----------------------------")
            table.insert(order.setting, "ui_font")
        end
        self.menu_items.ui_font = fontMenu()
        return orig(self, ...)
    end
end

-- Sets the Project: Title font size limits
userpatch.registerPatchPluginFunc("projecttitle", function()
    local ptutil = require("ptutil")
    for key, value in pairs(PT_SIZES.list) do ptutil.list_defaults[key] = value end
    for key, value in pairs(PT_SIZES.grid) do ptutil.grid_defaults[key] = value end
end)
