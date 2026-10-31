--[[
2-status-bar.lua — clearer items in the reading status bar

Goal: a status bar that reads naturally at a glance, especially in the compact
"compact items" style.

What it does:
  - Time left: "1 h 05 min left in chapter" and "6 h 20 min left in book" instead
    of the short "1:05" forms (needs Reading statistics, like the original items).
  - Compact items: uses the regular frontlight and warmth icons, which are easier
    to read than the compact ones, and shows the battery percentage next to its
    icon.
  - Compact items with no separator: title, chapter and author get a small arrow
    between them, so they don't run into each other or into the other items.
  Each part can be turned off in the CONFIG table below.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. Choose the items in the reading menu → Status bar. The changes apply to the
     "Time left to finish chapter/book", frontlight, battery, title, chapter and
     author items.
]]

local CONFIG = {
    time_left_in_words = true,   -- "1 h 05 min left in chapter"
    compact_light_icons = true,  -- regular frontlight icons in compact items
    compact_battery_percent = true, -- battery percentage in compact items
    compact_text_separator = true,  -- arrow between title, chapter and author
}

local ReaderFooter = require("apps/reader/modules/readerfooter")
local userpatch = require("userpatch")

local generators = ReaderFooter.textGeneratorMap
local symbol_prefix = userpatch.getUpValue(generators.frontlight, "symbol_prefix")

-- Formats seconds as "1 h 05 min" or "12 min"
local function formatDuration(secs)
    local mins = math.max(0, math.floor(secs / 60 + 0.5))
    if mins >= 60 then
        return string.format("%d h %02d min", math.floor(mins / 60), mins % 60)
    end
    return string.format("%d min", mins)
end

-- "<time> left in <where>", or "" when Reading statistics has no reading speed yet
local function timeLeft(footer, pages, where)
    local avg = footer.ui.statistics and footer.ui.statistics.avg_time
    if not pages or not avg or avg ~= avg or avg <= 0 then return "" end
    return formatDuration(pages * avg) .. " left in " .. where
end

if CONFIG.time_left_in_words then
    generators.chapter_time_to_read = function(footer)
        local left = footer.ui.toc:getChapterPagesLeft(footer.pageno, true)
            or footer.ui.document:getTotalPagesLeft(footer.pageno)
        return timeLeft(footer, left, "chapter")
    end
    generators.book_time_to_read = function(footer)
        return timeLeft(footer, footer.ui.document:getTotalPagesLeft(footer.pageno), "book")
    end
end

if CONFIG.compact_light_icons and symbol_prefix then
    for __, item in ipairs({ "frontlight", "frontlight_warmth" }) do
        symbol_prefix.compact_items[item] = symbol_prefix.icons[item]
    end
end

if CONFIG.compact_battery_percent then
    local orig_battery = generators.battery
    -- Builds the battery item as in the "icons" style, which includes the percentage
    generators.battery = function(footer, ...)
        local prefix = footer.settings.item_prefix
        if prefix == "compact_items" then footer.settings.item_prefix = "icons" end
        local ok, text = pcall(orig_battery, footer, ...)
        footer.settings.item_prefix = prefix
        return ok and text or ""
    end
end

if CONFIG.compact_text_separator and symbol_prefix then
    local OPEN, CLOSE = string.char(0x1E), string.char(0x1F)
    for __, item in ipairs({ "book_author", "book_title", "book_chapter" }) do
        local orig = generators[item]
        -- Marks the start and end of the item so the separators can be placed later
        generators[item] = function(footer, ...)
            local text = orig(footer, ...)
            local s = footer.settings
            if not text or text == "" or not s.all_at_once
                    or s.item_prefix ~= "compact_items" or s.items_separator ~= "none" then
                return text
            end
            return OPEN .. text .. CLOSE
        end
    end
    local arrow = symbol_prefix.compact_items.pages_left
    local REPLACEMENTS = {
        { CLOSE .. " " .. OPEN, " " .. arrow .. " " }, -- between title, chapter and author
        { "^" .. OPEN, "" },
        { CLOSE .. "$", "" },
        { OPEN, arrow .. " " },
        { CLOSE, "" },
    }
    local orig_gen = ReaderFooter.genAllFooterText
    -- Turns the marks into arrows
    ReaderFooter.genAllFooterText = function(self, ...)
        local text, is_filler_inside = orig_gen(self, ...)
        if text and text:find(OPEN, 1, true) then
            for __, r in ipairs(REPLACEMENTS) do text = text:gsub(r[1], r[2]) end
        end
        return text, is_filler_inside
    end
end
