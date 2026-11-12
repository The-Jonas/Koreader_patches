--[[
2-highlights.lua — highlight colors, style meanings, pickers and filter shortcuts

Goal: tell highlights apart at a glance and find each kind again later, even on a
grayscale e-ink screen.

What it does:
  - The MEANING of a highlight lives in its style (styles come from
    2-highlight-styles.lua): Box means Important, Wavy means Confusing, Quotes means
    Smart Quote, and so on. Style buttons read "Important · Box" — meaning first,
    style name after — and the styles that have a meaning come first in the list.
  - Colors are just colors, by name. Each one is tuned to land on its own gray level
    of a 16-level e-ink screen (from Black, level 0, to Yellow, level 14), so no two
    look alike on a grayscale Kindle; the hue is kept, so they stay recognizable on
    color screens and in exports. Gray is reserved for 2-vocabulary-highlights.lua,
    which watches for it to send words to the Vocabulary builder.
  - The dark colors (Black, Maroon, Blue, Purple) get white text: on their buttons in
    the color picker, and — with 2-highlight-styles.lua — on the page too.
  - The color and style pickers are laid out in a grid (4 colors / 2 styles per row),
    so the whole list fits on the screen without scrolling.
  - Everything is renamable from the Kindle itself, no file editing or restart: menu →
    Tools → More tools → Highlight labels → Colors / Styles. Pick one, type a new name
    (or clear it to go back to the default) and the pickers update right away.
  - Three gesture actions (Settings → Taps and gestures → Gesture manager → pick a
    gesture → Reader), each opening the highlight list with the filter already shown:
      Filter highlights by style
      Filter highlights by color
      Filter highlights by style and color

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader (fully: patches are only
     read when KOReader starts). Renames from the menu need no restart.
  2. Colors, their tones, style meanings and grid columns are in CONFIG below.
     The color key (red, orange…) is what each highlight stores: don't remove a key that
     highlights already use; its name and tone can be changed freely.
  3. A default color for new highlights is native: menu → Typeset → Highlights →
     Highlight color — tap to pick it for this book, hold to make it the default.
]]

local CONFIG = {
    -- Ordered from darkest to lightest. Each tone was picked so its gray value
    -- (KOReader's formula: 0.299 R + 0.587 G + 0.114 B) lands right on one of the
    -- 16 e-ink levels: 0x00, 0x11, 0x22... The four darkest get white text.
    colors = {
        { key = "black",  hex = "#000000" }, -- level 0
        { key = "maroon", hex = "#750000" }, -- level 2
        { key = "blue",   hex = "#004ADF" }, -- level 4
        { key = "purple", hex = "#AF26F4" }, -- level 6
        { key = "red",    hex = "#FF5848" }, -- level 8
        { key = "orange", hex = "#FF8204" }, -- level 9
        { key = "green",  hex = "#50E080" }, -- level 10
        { key = "cyan",   hex = "#3BEFFF" }, -- level 11
        { key = "gray",   hex = "#CCCCCC" }, -- level 12, Vocabulary (2-vocabulary-highlights.lua)
        { key = "olive",  hex = "#DDE8A5" }, -- level 13
        { key = "yellow", hex = "#FFF88F" }, -- level 14
    },
    -- Below this gray value (0-255), text on the color is drawn white instead of black.
    -- 2-highlight-styles.lua uses the same value for highlights on the page.
    dark_level = 0x80,
    -- Every style key we know about, with its plain name and, for some, the meaning it
    -- carries by default. Styles without a meaning show just their name until one is set
    -- from the menu. Styles with a meaning are listed first, in this order.
    styles = {
        { key = "box",               name = "Box",               meaning = "Important" },
        { key = "wavy",              name = "Wavy",              meaning = "Confusing" },
        { key = "quotes",            name = "Quotes",            meaning = "Smart Quote" },
        { key = "dashed",            name = "Dashed",            meaning = "Reference" },
        { key = "dotted",            name = "Dotted",            meaning = "WorldBuilding" },
        { key = "brackets",          name = "Brackets",          meaning = "Entities" },
        { key = "italic",            name = "Italic",            meaning = "Emotional" },
        { key = "bold",              name = "Bold",              meaning = "Disturbing" },
        { key = "lighten",           name = "Lighten" },
        { key = "underscore",        name = "Underline" },
        { key = "strikeout",         name = "Strikethrough" },
        { key = "invert",            name = "Invert" },
        { key = "stars",             name = "Stars" },
        { key = "marker",            name = "Marker underline" },
        { key = "double_underline",  name = "Double underline" },
        { key = "rounded_box",       name = "Rounded box" },
        { key = "bold_italic",       name = "Bold + italic" },
        { key = "lighten_underline", name = "Lighten + underline" },
        { key = "lighten_rounded",   name = "Lighten + rounded box" },
    },
    -- Pickers as a grid: buttons per row, and dialog width (fraction of the screen width)
    picker_columns = { colors = 4, styles = 2 },
    picker_width = 0.9,
}

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonSelector = require("ui/widget/buttonselector")
local Dispatcher = require("dispatcher")
local InputDialog = require("ui/widget/inputdialog")
local ReaderBookmark = require("apps/reader/modules/readerbookmark")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template


for _, c in ipairs(CONFIG.colors) do
    Blitbuffer.HIGHLIGHT_COLORS[c.key] = c.hex
end

------------------------------------------------------------------------
-- Labels: defaults from CONFIG, overridden from the menu
------------------------------------------------------------------------

-- { color = { red = "...", ... }, style = { box = "...", ... } }
local function savedLabels()
    return G_reader_settings:readSetting("highlight_labels") or {}
end

-- Sets (or, with an empty string, clears) one label override and saves it
local function setSavedLabel(kind, key, text)
    local saved = savedLabels()
    saved[kind] = saved[kind] or {}
    saved[kind][key] = (text ~= "") and text or nil
    G_reader_settings:saveSetting("highlight_labels", saved)
end

local function titleCase(word)
    return word:sub(1, 1):upper() .. word:sub(2)
end

-- The name shown for a color: the saved override, or the color's own name
local function colorLabel(key)
    return (savedLabels().color or {})[key] or titleCase(key)
end

local style_defaults, style_rank = {}, {}
for i, s in ipairs(CONFIG.styles) do
    style_defaults[s.key] = s
    style_rank[s.key] = i
end

-- The meaning saved for a style, or its CONFIG default (nil if it has neither)
local function styleMeaning(key)
    local saved = (savedLabels().style or {})[key]
    if saved then return saved end
    return style_defaults[key] and style_defaults[key].meaning
end

-- "Important · Box" when the style has a meaning, otherwise just "Box"
local function styleButtonLabel(key)
    local name = style_defaults[key] and style_defaults[key].name or key
    local meaning = styleMeaning(key)
    if not meaning then return name end
    return meaning .. " · " .. name
end

------------------------------------------------------------------------
-- Wires the labels into the lists the pickers are built from
------------------------------------------------------------------------

-- The style list is a local table of readerhighlight.lua (2-highlight-styles.lua, which
-- loads first, has already added its styles to it). It's found among the upvalues of
-- ReaderHighlight's functions, by the "underscore" entry only it has.
local function findEntryShape(t)
    if type(t.underscore) == "string" then return "map" end
    for _, e in ipairs(t) do
        if type(e) == "table" then
            if e[2] == "underscore" then return "array_label_key" end
            if e[1] == "underscore" then return "array_key_label" end
        end
    end
end

local function findStyleTable()
    for _, fn in pairs(ReaderHighlight) do
        if type(fn) == "function" then
            local i = 1
            while true do
                local name, val = debug.getupvalue(fn, i)
                if not name then break end
                if type(val) == "table" then
                    local shape = findEntryShape(val)
                    if shape then return val, shape end
                end
                i = i + 1
            end
        end
    end
end

local style_table, style_shape = findStyleTable()
local key_idx = style_shape == "array_key_label" and 1 or 2
local label_idx = style_shape == "array_key_label" and 2 or 1

-- Position of a style in the list: styles with a meaning first (CONFIG order), then the
-- others (CONFIG order), then any style CONFIG doesn't know, as they came
local first_seen = {}
local function styleOrder(key)
    local base = style_rank[key] or (1000 + (first_seen[key] or 0))
    return styleMeaning(key) and base or base + 100
end

-- Rebuilds the color list, relabels every known style and puts the styles in order;
-- called at startup and after every rename, so changes show up right away
local function refreshLabels()
    local highlight_colors = {}
    for _, c in ipairs(CONFIG.colors) do
        table.insert(highlight_colors, { colorLabel(c.key), c.key })
    end
    ReaderHighlight.highlight_colors = highlight_colors

    if style_table and style_shape ~= "map" then
        for i, e in ipairs(style_table) do
            local key = e[key_idx]
            first_seen[key] = first_seen[key] or i
            if style_defaults[key] then
                e[label_idx] = styleButtonLabel(key)
            end
        end
        table.sort(style_table, function(a, b) return styleOrder(a[key_idx]) < styleOrder(b[key_idx]) end)
    end
end
refreshLabels()

------------------------------------------------------------------------
-- Pickers: grid layout, white text on the dark colors
------------------------------------------------------------------------

-- True while a highlight picker builds its buttons (see ButtonDialog.init below)
local building_picker = false

-- Gray value (0-255) of a color, or nil
local function grayOf(color)
    local ok, gray = pcall(function() return color:getColor8().a end)
    return ok and gray or nil
end

-- Button text is always drawn black: on a dark color swatch it turns white
local orig_button_init = Button.init
Button.init = function(self, ...)
    orig_button_init(self, ...)
    if building_picker then self._on_highlight_picker = true end
    if self._on_highlight_picker and self.background and self.text and self.label_widget then
        local gray = grayOf(self.background)
        if gray and gray < CONFIG.dark_level then
            self.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
            if self.label_widget.update then -- two-line TextBoxWidget: redraw with the new color
                self.label_widget:update()
            end
        end
    end
end

-- Regroups the one-button rows of a picker into rows of `columns` buttons; the last row is
-- completed with blank cells so every button keeps the same width
local function arrangeInGrid(dialog, columns)
    local n = #dialog.values
    local rows = {}
    for i = 1, n do
        local r = math.ceil(i / columns)
        rows[r] = rows[r] or {}
        table.insert(rows[r], dialog.buttons[i][1])
    end
    local last = rows[#rows]
    if last and #last < columns then
        last[#last].no_vertical_sep = true
        while #last < columns do
            table.insert(last, { text = "", enabled = false, no_vertical_sep = true, callback = function() end })
        end
    end
    for i = n + 1, #dialog.buttons do -- rows the picker adds after the values, if any
        table.insert(rows, dialog.buttons[i])
    end
    dialog.buttons = rows
end

-- Marks the highlight color and style pickers (wherever they're opened from) as grids
local orig_selector_init = ButtonSelector.init
ButtonSelector.init = function(self, ...)
    local styles = ReaderHighlight.getHighlightStyles and ReaderHighlight.getHighlightStyles()
    if self.bg_colors then
        self._grid_columns = CONFIG.picker_columns.colors
    elseif styles and self.values == styles then
        self._grid_columns = CONFIG.picker_columns.styles
    end
    if self._grid_columns and not self.width then
        self.width_factor = CONFIG.picker_width
    end
    return orig_selector_init(self, ...)
end

-- ButtonSelector.init ends by calling this with its one-button rows: they're regrouped
-- here, right before the buttons are created
local orig_dialog_init = ButtonDialog.init
ButtonDialog.init = function(self, ...)
    if not self._grid_columns then
        return orig_dialog_init(self, ...)
    end
    if self._grid_columns > 1 and #self.values > self._grid_columns then
        arrangeInGrid(self, self._grid_columns)
    end
    building_picker = true
    local ok, err = pcall(orig_dialog_init, self, ...)
    building_picker = false
    if not ok then error(err, 0) end
end

------------------------------------------------------------------------
-- Filtering the highlight list
------------------------------------------------------------------------

-- Removes items whose field differs from value from the open list and refreshes it
local function keepOnly(bookmark, field, value, flag)
    local item_table = bookmark.bookmark_menu[1].item_table
    for i = #item_table, 1, -1 do
        if item_table[i][field] ~= value then
            table.remove(item_table, i)
        end
    end
    bookmark[flag] = value
    bookmark:updateBookmarkList(item_table)
end

-- Shows the color picker and filters the open list; on_done runs afterwards
function ReaderBookmark:pickHighlightColor(on_done)
    UIManager:show(ButtonSelector:new {
        current_value = self.show_color_only,
        values = self.ui.highlight.highlight_colors,
        bg_colors = self.ui.highlight:getHighlightColorList(),
        callback = function(value)
            keepOnly(self, "color", value, "show_color_only")
            if on_done then on_done() end
        end,
    })
end

-- Shows the style picker and filters the open list; on_done runs afterwards
function ReaderBookmark:pickHighlightStyle(on_done)
    UIManager:show(ButtonSelector:new {
        current_value = self.show_drawer_only,
        values = ReaderHighlight.getHighlightStyles(),
        callback = function(value)
            keepOnly(self, "drawer", value, "show_drawer_only")
            if on_done then on_done() end
        end,
    })
end

-- Opens the highlight list and runs the filter picker right after
function ReaderBookmark:openFilteredList(picker)
    self:onShowBookmark()
    UIManager:scheduleIn(0.1, picker)
end

-- The action ids are the ones gestures were bound to before styles carried the meaning:
-- "filter_highlights_category" now filters by style, "filter_highlights_style" by color,
-- so a gesture that used to filter by meaning still does.

-- Gesture action: filter by style
function ReaderBookmark:onFilterHighlightsByCategory()
    self:openFilteredList(function() self:pickHighlightStyle() end)
    return true
end

-- Gesture action: filter by color
function ReaderBookmark:onFilterHighlightsByStyle()
    self:openFilteredList(function() self:pickHighlightColor() end)
    return true
end

-- Gesture action: filter by style, then by color
function ReaderBookmark:onFilterHighlightsByCategoryAndStyle()
    self:openFilteredList(function()
        self:pickHighlightStyle(function() self:pickHighlightColor() end)
    end)
    return true
end

Dispatcher:registerAction("filter_highlights_category", {
    category = "none", event = "FilterHighlightsByCategory",
    title = "Filter highlights by style", reader = true,
})
Dispatcher:registerAction("filter_highlights_style", {
    category = "none", event = "FilterHighlightsByStyle",
    title = "Filter highlights by color", reader = true,
})
Dispatcher:registerAction("filter_highlights_category_style", {
    category = "none", event = "FilterHighlightsByCategoryAndStyle",
    title = "Filter highlights by style and color", reader = true, separator = true,
})

------------------------------------------------------------------------
-- Tools → More tools → Highlight labels: rename colors and style meanings
------------------------------------------------------------------------

-- Opens a text box to rename a color or style; empty text goes back to the default
local function renameDialog(title, current, on_save)
    local dialog
    dialog = InputDialog:new {
        title = title,
        input = current or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                UIManager:close(dialog)
                on_save(dialog:getInputText())
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- One menu entry per color: "Red: <name>"
local function colorMenuItems()
    local items = {}
    for _, c in ipairs(CONFIG.colors) do
        table.insert(items, {
            text_func = function() return T("%1: %2", titleCase(c.key), colorLabel(c.key)) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                renameDialog(T("Name for %1", titleCase(c.key)), colorLabel(c.key), function(text)
                    setSavedLabel("color", c.key, text)
                    refreshLabels()
                    touchmenu_instance:updateItems()
                end)
            end,
        })
    end
    return items
end

-- One menu entry per style: "Box: <meaning>"
local function styleMenuItems()
    local items = {}
    for _, s in ipairs(CONFIG.styles) do
        table.insert(items, {
            text_func = function() return T("%1: %2", s.name, styleMeaning(s.key) or "—") end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                renameDialog(T("Meaning for %1", s.name), styleMeaning(s.key), function(text)
                    setSavedLabel("style", s.key, text)
                    refreshLabels()
                    touchmenu_instance:updateItems()
                end)
            end,
        })
    end
    return items
end

local HighlightLabels = WidgetContainer:extend { name = "highlight_labels" }

-- Registers the menu entry
function HighlightLabels:init()
    self.ui.menu:registerToMainMenu(self)
end

-- Adds Tools → More tools → Highlight labels
function HighlightLabels:addToMainMenu(menu_items)
    menu_items.highlight_labels = {
        text = "Highlight labels",
        sorting_hint = "more_tools",
        sub_item_table = {
            { text = "Colors", sub_item_table_func = colorMenuItems },
            { text = "Styles", sub_item_table_func = styleMenuItems },
        },
    }
end

-- Registers the module in every opened book
local orig_init = ReaderUI.init
ReaderUI.init = function(self, ...)
    orig_init(self, ...)
    self:registerModule("highlight_labels", HighlightLabels:new { ui = self })
end
