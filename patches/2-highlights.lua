--[[
2-highlights.lua — highlight categories and filter shortcuts

Goal: use highlight colors as reading categories (important, reference,
vocabulary…), tell them apart even on a grayscale screen and find each category
quickly later.

What it does:
  - Renames the highlight colors to categories (with a symbol), shown in the
    color menu, in the highlight list filter and in exports.
  - Tunes each color so that, on a grayscale e-ink screen, every category lands
    on a different gray level (levels 6 to 14 out of 16). The hue is kept, so the
    colors stay recognizable on color screens and in exports.
  - Adds three gesture actions (Settings → Taps and gestures → Gesture manager →
    pick a gesture → Reader):
      Filter highlights by category
      Filter highlights by style
      Filter highlights by category and style
    Each one opens the highlight list with the filter picker already shown.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. To change names, order or tones, edit the CATEGORIES table below. The
     "color" field is the internal key stored in each highlight: don't change the
     key of a category that already has highlights, only its label and tone.
     Similar categories are easier to tell apart on distant gray levels.
]]

local CATEGORIES = {
    { color = "red",    label = "⚠ Important",     hex = "#FF271A" }, -- gray level 6 (darkest)
    { color = "orange", label = "❔ Confusing",     hex = "#D77615" }, -- level 8
    { color = "yellow", label = "❞ Smart Quote",   hex = "#FFF88E" }, -- level 14 (lightest)
    { color = "green",  label = "☍ Reference",     hex = "#C1EED2" }, -- level 13
    { color = "olive",  label = "⚑ WorldBuilding", hex = "#79842C" }, -- level 7
    { color = "cyan",   label = "➤ Entities",      hex = "#2FDCE8" }, -- level 10
    { color = "blue",   label = "💧 Emotional",     hex = "#6E9BFF" }, -- level 9
    { color = "purple", label = "☠ Disturbing",    hex = "#D99FFF" }, -- level 11
    { color = "gray",   label = "✎ Vocabulary",    hex = "#CCCCCC" }, -- level 12
}

local Blitbuffer = require("ffi/blitbuffer")
local ButtonSelector = require("ui/widget/buttonselector")
local Dispatcher = require("dispatcher")
local ReaderBookmark = require("apps/reader/modules/readerbookmark")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local UIManager = require("ui/uimanager")

local highlight_colors = {}
for _, cat in ipairs(CATEGORIES) do
    table.insert(highlight_colors, { cat.label, cat.color })
    Blitbuffer.HIGHLIGHT_COLORS[cat.color] = cat.hex
end
ReaderHighlight.highlight_colors = highlight_colors

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

-- Shows the category picker and filters the open list; on_done runs afterwards
function ReaderBookmark:pickHighlightCategory(on_done)
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

-- Shows the style picker and filters the open list
function ReaderBookmark:pickHighlightStyle()
    UIManager:show(ButtonSelector:new {
        current_value = self.show_drawer_only,
        values = ReaderHighlight.getHighlightStyles(),
        callback = function(value)
            keepOnly(self, "drawer", value, "show_drawer_only")
        end,
    })
end

-- Opens the highlight list and runs the filter picker right after
function ReaderBookmark:openFilteredList(picker)
    self:onShowBookmark()
    UIManager:scheduleIn(0.1, picker)
end

-- Gesture action: filter by category
function ReaderBookmark:onFilterHighlightsByCategory()
    self:openFilteredList(function() self:pickHighlightCategory() end)
    return true
end

-- Gesture action: filter by style
function ReaderBookmark:onFilterHighlightsByStyle()
    self:openFilteredList(function() self:pickHighlightStyle() end)
    return true
end

-- Gesture action: filter by category, then by style
function ReaderBookmark:onFilterHighlightsByCategoryAndStyle()
    self:openFilteredList(function()
        self:pickHighlightCategory(function() self:pickHighlightStyle() end)
    end)
    return true
end

Dispatcher:registerAction("filter_highlights_category", {
    category = "none", event = "FilterHighlightsByCategory",
    title = "Filter highlights by category", reader = true,
})
Dispatcher:registerAction("filter_highlights_style", {
    category = "none", event = "FilterHighlightsByStyle",
    title = "Filter highlights by style", reader = true,
})
Dispatcher:registerAction("filter_highlights_category_style", {
    category = "none", event = "FilterHighlightsByCategoryAndStyle",
    title = "Filter highlights by category and style", reader = true, separator = true,
})
