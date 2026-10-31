--[[
2-progress-bar.lua — progress bar styles for the reading status bar

Goal: a status bar progress bar that shows at a glance where you are in the book,
how far along the current chapter is and how much you read in this session, with a
light game-like feel that suits e-ink.

What it does:
  Adds new looks for the progress bar of the status bar (footer) while reading:
    rounded   rounded bar with a small gap between chapters
    segments  one block per chapter, like quest stages: chapters already read
              are filled, the current one fills up as you read
    dual      thin line marking the stretch read in this session (from the page
              where the book was opened to the current one) over a thicker bar
              for the whole book
  Chapters come from the first level of the book's table of contents.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. While reading: menu → Status bar → Progress bar → Style.
     "KOReader default" keeps the original bar.
  3. The bar height is set in Status bar → Progress bar → Thickness, height & colors
     (a taller bar suits "dual").
  The styles draw the whole bar themselves, so they replace other patches that
  also change how the status bar progress bar is drawn while a style is active.
]]

local CONFIG = {
    default_style = "segments", -- "default", "rounded", "segments" or "dual"
    chapter_gap = 3,            -- space between chapters, before DPI scaling
}

local STYLES = {
    { "KOReader default", "default" },
    { "Rounded", "rounded" },
    { "Segments", "segments" },
    { "Dual (session and book)", "dual" },
}

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local ProgressWidget = require("ui/widget/progresswidget")
local ReaderFooter = require("apps/reader/modules/readerfooter")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local TRACK = Blitbuffer.COLOR_GRAY_E

-- Style chosen in the menu, or the CONFIG default
local function currentStyle()
    return G_reader_settings:readSetting("progress_bar_style", CONFIG.default_style)
end

-- First page of every chapter (top level of the table of contents), starting at page 1
local function chapterStarts(footer)
    local starts = { 1 }
    local toc = footer.ui and footer.ui.toc
    local ticks = toc and toc:getTocTicks(1) or {}
    for __, page in ipairs(ticks) do
        if page > starts[#starts] and page <= footer.pages then
            table.insert(starts, page)
        end
    end
    return starts
end

-- Paints a horizontal pill (rounded on both ends) filled up to fill (0 to 1)
local function paintPill(bb, x, y, w, h, fill, color)
    local r = math.floor(h / 2)
    bb:paintRoundedRect(x, y, w, h, TRACK, r)
    local fw = math.floor(w * math.max(0, math.min(1, fill)))
    if fw > 0 then
        bb:paintRoundedRect(x, y, math.max(fw, h), h, color or BLACK, r)
    end
    bb:paintBorder(x, y, w, h, 1, BLACK, r)
end

-- "rounded": one pill for the whole book with white gaps where chapters start
local function paintRounded(bb, x, y, w, h, footer, page)
    paintPill(bb, x, y, w, h, page / footer.pages)
    local gap = math.max(1, math.floor(Screen:scaleBySize(CONFIG.chapter_gap) / 2))
    for i, s in ipairs(chapterStarts(footer)) do
        if i > 1 then
            local gx = x + math.floor(w * (s - 1) / footer.pages)
            bb:paintRect(gx, y, gap, h, WHITE)
        end
    end
end

-- "segments": one block per chapter, filled for read chapters and partially for the current one
local function paintSegments(bb, x, y, w, h, footer, page)
    local starts = chapterStarts(footer)
    local gap = Screen:scaleBySize(CONFIG.chapter_gap)
    local total = footer.pages
    local usable = w - gap * (#starts - 1)
    if usable < #starts * 2 then
        return paintPill(bb, x, y, w, h, page / total)
    end
    local r = math.min(math.floor(h / 2), Screen:scaleBySize(3))
    local cx = x
    for i, s in ipairs(starts) do
        local e = starts[i + 1] or (total + 1)
        local sw = math.max(2, math.floor(usable * (e - s) / total + 0.5))
        if i == #starts then sw = x + w - cx end
        bb:paintRoundedRect(cx, y, sw, h, TRACK, r)
        if page >= e then
            bb:paintRoundedRect(cx, y, sw, h, BLACK, r)
        elseif page >= s then
            local fw = math.floor(sw * (page - s + 1) / (e - s))
            if fw > 0 then bb:paintRoundedRect(cx, y, math.max(fw, 2 * r), h, BLACK, r) end
            bb:paintBorder(cx, y, sw, h, 1, BLACK, r)
        else
            bb:paintBorder(cx, y, sw, h, 1, Blitbuffer.COLOR_GRAY_9, r)
        end
        cx = cx + sw + gap
    end
end

-- "dual": thin line with the stretch read in this session over a thicker pill for the whole book
local function paintDual(bb, x, y, w, h, footer, page)
    local total = footer.pages
    local start = math.min(footer._session_start_page or page, page)
    local line_h = math.max(2, math.floor(h * 0.3))
    local gap = math.max(1, math.floor(h * 0.15))
    local sx = x + math.floor(w * (start - 1) / total)
    local ex = x + math.floor(w * page / total)
    bb:paintRect(x, y, w, line_h, TRACK)
    bb:paintRect(sx, y, math.max(ex - sx, 1), line_h, BLACK)
    paintPill(bb, x, y + line_h + gap, w, h - line_h - gap, page / total)
end

local PAINTERS = {
    rounded = paintRounded,
    segments = paintSegments,
    dual = paintDual,
}

-- Draws the status bar progress bar with the chosen style, or the regular bar for "default"
local function paintStyled(bar, footer, bb, x, y)
    local painter = PAINTERS[currentStyle()]
    if not painter or footer.settings.chapter_progress_bar
            or type(footer.pageno) ~= "number" or not footer.pages or footer.pages < 1 then
        return ProgressWidget.paintTo(bar, bb, x, y)
    end
    footer._session_start_page = footer._session_start_page or footer.pageno
    local size = bar:getSize()
    bar.dimen = Geom:new { x = x, y = y, w = size.w, h = size.h }
    if size.w == 0 or size.h == 0 then return end
    bb:paintRect(x, y, size.w, size.h, WHITE)
    painter(bb, x, y, size.w, size.h, footer, math.min(footer.pageno, footer.pages))
end

-- Gives the status bar progress bar its own paintTo, so other patches that replace
-- ProgressWidget.paintTo keep working for every other bar
local orig_init = ReaderFooter.init
ReaderFooter.init = function(self, ...)
    orig_init(self, ...)
    local footer = self
    if self.progress_bar then
        self.progress_bar.paintTo = function(bar, bb, x, y) paintStyled(bar, footer, bb, x, y) end
    end
end

-- Adds the "Style" choice to Status bar → Progress bar
local orig_addToMainMenu = ReaderFooter.addToMainMenu
ReaderFooter.addToMainMenu = function(self, menu_items)
    orig_addToMainMenu(self, menu_items)
    local status_bar = menu_items.status_bar
    if not status_bar or not status_bar.sub_item_table then return end
    for __, item in ipairs(status_bar.sub_item_table) do
        if item.text == _("Progress bar") and item.sub_item_table then
            local choices = {}
            for __, s in ipairs(STYLES) do
                table.insert(choices, {
                    text = s[1],
                    radio = true,
                    checked_func = function() return currentStyle() == s[2] end,
                    callback = function()
                        G_reader_settings:saveSetting("progress_bar_style", s[2])
                        self:refreshFooter(true, true)
                    end,
                })
            end
            table.insert(item.sub_item_table, 2, {
                text_func = function()
                    for __, s in ipairs(STYLES) do
                        if currentStyle() == s[2] then return T("Style: %1", s[1]) end
                    end
                    return "Style"
                end,
                enabled_func = function() return not self.settings.disable_progress_bar end,
                sub_item_table = choices,
            })
            break
        end
    end
end
