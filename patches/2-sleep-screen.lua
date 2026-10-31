--[[
2-sleep-screen.lua — book card sleep screen while reading, random images elsewhere

Goal: when the device sleeps in the middle of a book, the sleep screen shows that
book — cover, chapter and how far along you are — instead of a random picture;
outside a book, the random pictures keep rotating as before.

What it does:
  - Inside a book: the sleep screen becomes a card with the cover, title, author,
    current chapter, a progress bar with chapter marks, the time left in the
    chapter (from Reading statistics) and the current reading streak.
  - In the file manager: nothing changes, the wallpaper chosen in the sleep screen
    settings is used (for example a random image from a folder).
  - Three layouts: "card" (cover on white with the details below), "poster" (cover
    filling the screen with a details panel over it) and "night" (white on black).
  - Books marked "exclude from sleep screen" and books without a cover keep the
    regular wallpaper.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. Settings → Screen → Sleep screen → Wallpaper: pick "Show random image from
     folder" (or "Show book cover") — the card replaces it only while reading.
  3. Settings → Screen → Sleep screen → Book card while reading: on/off, layout,
     streak.
]]

local CONFIG = {
    defaults = {
        enabled = true,
        layout = "card",  -- "card", "poster" or "night"
        streak = true,    -- show the reading streak
    },
    corner_radius = 18,   -- rounded corners of the cover and panels, before DPI scaling
}

local LAYOUTS = {
    { "Card", "card" },
    { "Poster", "poster" },
    { "Night", "night" },
}

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local Screen = require("device").screen
local Screensaver = require("ui/screensaver")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_GRAY_7
local LIGHT = Blitbuffer.COLOR_GRAY_E

-- Value of an option chosen in the menu, or its default from CONFIG
local function opt(key)
    local saved = G_reader_settings:readSetting("sleep_screen_card") or {}
    if saved[key] == nil then return CONFIG.defaults[key] end
    return saved[key]
end

-- Saves an option chosen in the menu
local function setOpt(key, value)
    local saved = G_reader_settings:readSetting("sleep_screen_card") or {}
    saved[key] = value
    G_reader_settings:saveSetting("sleep_screen_card", saved)
end

-- Formats seconds as "1 h 05 min" or "12 min"
local function formatDuration(secs)
    local mins = math.max(1, math.floor(secs / 60 + 0.5))
    if mins >= 60 then
        return string.format("%d h %02d min", math.floor(mins / 60), mins % 60)
    end
    return string.format("%d min", mins)
end

-- Days in a row with reading, ending today or yesterday; uses the daily goal of
-- 2-reading-session.lua when it is set, any reading otherwise
local function readingStreak()
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if not util.fileExists(db) then return 0 end
    local ok, days = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db)
        local res = conn:exec([[
            SELECT date(start_time, 'unixepoch', 'localtime'), count(*), sum(duration)
            FROM page_stat_data WHERE start_time > strftime('%s', 'now', '-400 days') GROUP BY 1;
        ]])
        conn:close()
        local out = {}
        if res then
            for i = 1, #res[1] do out[res[1][i]] = { tonumber(res[2][i]) or 0, tonumber(res[3][i]) or 0 } end
        end
        return out
    end)
    if not ok then
        logger.warn("sleep-screen: could not read statistics:", days)
        return 0
    end
    local session = G_reader_settings:readSetting("reading_session")
    local goal = session and (session.goal or 30) or 1
    local by_minutes = session and session.goal_type == "minutes"
    local function met(day)
        local d = days[day]
        if not d then return false end
        return (by_minutes and d[2] / 60 or d[1]) >= goal
    end
    local now = os.time()
    local k = met(os.date("%Y-%m-%d", now)) and 0 or 1
    local streak = 0
    while met(os.date("%Y-%m-%d", now - k * 86400)) do
        streak = streak + 1
        k = k + 1
    end
    return streak
end

-- Everything the card shows about the open book
local function collectInfo(ui)
    local props = ui.doc_props or {}
    local page = ui:getCurrentPage()
    local total = ui.document:getPageCount()
    local info = {
        title = props.display_title or "",
        author = props.authors and props.authors:gsub("\n", ", ") or nil,
        percent = total > 0 and page / total or 0,
        ticks = {},
    }
    if ui.toc then
        info.chapter = ui.toc:getTocTitleByPage(page)
        for __, p in ipairs(ui.toc:getTocTicks(1) or {}) do
            if p > 1 and p <= total then table.insert(info.ticks, (p - 1) / total) end
        end
        local left = ui.toc:getChapterPagesLeft(page, true)
        local avg = ui.statistics and ui.statistics.avg_time
        if left and avg and avg == avg and avg > 0 then
            info.chapter_left = formatDuration((left + 1) * avg)
        end
    end
    if opt("streak") then info.streak = readingStreak() end
    return info
end

-- Paints bg over the parts of a rectangle outside its rounded corners
local function roundCorners(bb, x, y, w, h, r, bg)
    for dy = 0, r - 1 do
        local dist = r - dy - 0.5
        local span = r - math.floor(math.sqrt(math.max(0, r * r - dist * dist)) + 0.5)
        if span > 0 then
            bb:paintRect(x, y + dy, span, 1, bg)
            bb:paintRect(x + w - span, y + dy, span, 1, bg)
            bb:paintRect(x, y + h - 1 - dy, span, 1, bg)
            bb:paintRect(x + w - span, y + h - 1 - dy, span, 1, bg)
        end
    end
end

-- Progress bar as a pill with white notches where chapters start
local function paintBar(bb, x, y, w, h, info, fg, track)
    local r = math.floor(h / 2)
    bb:paintRoundedRect(x, y, w, h, track, r)
    local fw = math.floor(w * info.percent)
    if fw > 0 then bb:paintRoundedRect(x, y, math.max(fw, h), h, fg, r) end
    if #info.ticks <= 60 then
        local notch = math.max(1, Screen:scaleBySize(1.5))
        for __, t in ipairs(info.ticks) do
            local tx = x + math.floor(w * t)
            bb:paintRect(tx, y, notch, h, tx < x + fw and track or fg)
        end
    end
end

-- Text block of a given width, cut to opts.lines lines; returns the widget and its height
local function text(str, size, width, opts)
    opts = opts or {}
    local args = {
        text = str,
        face = Font:getFace(opts.bold and "tfont" or "cfont", size),
        bold = opts.bold,
        width = width,
        alignment = opts.align or "center",
        fgcolor = opts.fg or BLACK,
        bgcolor = opts.bg or WHITE,
    }
    local tb = TextBoxWidget:new(args)
    if opts.lines and tb:getSize().h > tb.line_height_px * opts.lines then
        args.height = tb.line_height_px * opts.lines
        args.height_adjust = true
        args.height_overflow_show_ellipsis = true
        tb:free()
        tb = TextBoxWidget:new(args)
    end
    return tb, tb:getSize().h
end

local BookCard = Widget:extend {
    info = nil,
    cover = nil,
    layout = "card",
    width = 0,
    height = 0,
}

-- The card always fills the screen
function BookCard:getSize()
    return Geom:new { w = self.width, h = self.height }
end

-- Paints the cover scaled to fit max_w × max_h, centered on cx, with rounded corners and a border
function BookCard:paintCover(bb, cx, top, max_w, max_h, bg, border)
    local scale = math.min(max_w / self.cover:getWidth(), max_h / self.cover:getHeight())
    local img = ImageWidget:new {
        image = self.cover,
        image_disposable = false,
        scale_factor = scale,
    }
    local size = img:getSize()
    local x = cx - math.floor(size.w / 2)
    img:paintTo(bb, x, top)
    img:free()
    local r = Screen:scaleBySize(CONFIG.corner_radius)
    roundCorners(bb, x, top, size.w, size.h, r, bg)
    bb:paintBorder(x, top, size.w, size.h, Screen:scaleBySize(1), border, r)
    return size
end

-- Paints title, author, chapter, bar and stats from top, centered in width w; returns the height used
function BookCard:paintDetails(bb, x, top, w, fg, muted, track, bg)
    local info = self.info
    local y = top
    local gap = Screen:scaleBySize(10)
    local function put(str, size, opts)
        if not str or str == "" then return end
        opts = opts or {}
        opts.fg, opts.bg = opts.fg or fg, bg
        local tb, h = text(str, size, w, opts)
        tb:paintTo(bb, x, y)
        tb:free()
        y = y + h + (opts.after or gap)
    end
    put(info.title, 30, { bold = true, lines = 2, after = Screen:scaleBySize(4) })
    put(info.author, 20, { fg = muted, after = gap * 2 })
    put(info.chapter, 22, { lines = 2 })
    local bar_h = Screen:scaleBySize(12)
    paintBar(bb, x, y, w, bar_h, info, fg, track)
    y = y + bar_h + gap
    local stats = { string.format("%d%%", math.floor(info.percent * 100)) }
    if info.chapter_left then table.insert(stats, T("%1 left in chapter", info.chapter_left)) end
    if info.streak and info.streak > 0 then
        table.insert(stats, T("%1-day streak", info.streak))
    end
    put(table.concat(stats, "  ·  "), 19, { fg = muted, after = 0 })
    return y - top
end

-- Cover on white, details below
function BookCard:paintCardLayout(bb, x, y)
    local w, h = self.width, self.height
    local m = Screen:scaleBySize(36)
    bb:paintRect(x, y, w, h, WHITE)
    local cover_h = math.floor(h * 0.56)
    self:paintCover(bb, x + math.floor(w / 2), y + m * 2, w - 4 * m, cover_h, WHITE, BLACK)
    self:paintDetails(bb, x + m, y + m * 3 + cover_h, w - 2 * m, BLACK, GRAY, LIGHT, WHITE)
end

-- Cover filling the screen, details on a white panel at the bottom
function BookCard:paintPosterLayout(bb, x, y)
    local w, h = self.width, self.height
    local m = Screen:scaleBySize(28)
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_3)
    self:paintCover(bb, x + math.floor(w / 2), y, w, h, Blitbuffer.COLOR_GRAY_3, Blitbuffer.COLOR_GRAY_3)
    local pad = Screen:scaleBySize(24)
    local inner_w = w - 2 * m - 2 * pad
    local scratch = Blitbuffer.new(inner_w, h, bb:getType())
    scratch:fill(WHITE)
    local used = self:paintDetails(scratch, 0, 0, inner_w, BLACK, GRAY, LIGHT, WHITE)
    local panel_h = used + 2 * pad
    local px, py = x + m, y + h - m - panel_h
    local r = Screen:scaleBySize(CONFIG.corner_radius)
    bb:paintRoundedRect(px, py, w - 2 * m, panel_h, WHITE, r)
    bb:blitFrom(scratch, px + pad, py + pad, 0, 0, inner_w, used)
    bb:paintBorder(px, py, w - 2 * m, panel_h, Screen:scaleBySize(1), BLACK, r)
    scratch:free()
end

-- White text on black, cover on top
function BookCard:paintNightLayout(bb, x, y)
    local w, h = self.width, self.height
    local m = Screen:scaleBySize(36)
    bb:paintRect(x, y, w, h, BLACK)
    local cover_h = math.floor(h * 0.56)
    self:paintCover(bb, x + math.floor(w / 2), y + m * 2, w - 4 * m, cover_h, BLACK, WHITE)
    self:paintDetails(bb, x + m, y + m * 3 + cover_h, w - 2 * m, WHITE, Blitbuffer.COLOR_GRAY_B,
        Blitbuffer.COLOR_GRAY_4, BLACK)
end

-- Draws the chosen layout
function BookCard:paintTo(bb, x, y)
    self.dimen = Geom:new { x = x, y = y, w = self.width, h = self.height }
    if self.layout == "poster" then
        self:paintPosterLayout(bb, x, y)
    elseif self.layout == "night" then
        self:paintNightLayout(bb, x, y)
    else
        self:paintCardLayout(bb, x, y)
    end
end

-- Frees the cover image
function BookCard:free()
    if self.cover then
        self.cover:free()
        self.cover = nil
    end
end
BookCard.onCloseWidget = BookCard.free

-- Swaps the wallpaper for the book card when sleeping inside a book
local orig_setup = Screensaver.setup
Screensaver.setup = function(self, event, event_message)
    orig_setup(self, event, event_message)
    self._book_card = nil
    local ui = self.ui
    if not (opt("enabled") and ui and ui.document) then return end
    if not (self.screensaver_type == "random_image" or self.screensaver_type == "cover") then return end
    if ui.doc_settings and ui.doc_settings:isTrue("exclude_screensaver") then return end
    local ok, info = pcall(collectInfo, ui)
    local cover = ok and ui.bookinfo and ui.bookinfo:getCoverImage(ui.document)
    if not cover then
        if not ok then logger.warn("sleep-screen:", info) end
        return
    end
    if self.image then self.image:free() end
    self.image, self.image_file = cover, nil
    self.screensaver_type = "cover"
    self._book_card = info
end

-- Builds the book card where the wallpaper image would be built
local orig_show = Screensaver.show
Screensaver.show = function(self)
    if not self._book_card then return orig_show(self) end
    local info = self._book_card
    local orig_new = ImageWidget.new
    ImageWidget.new = function(cls, settings)
        ImageWidget.new = orig_new
        if cls ~= ImageWidget then return orig_new(cls, settings) end
        local card = BookCard:new {
            info = info,
            cover = settings.image,
            layout = opt("layout"),
            width = settings.width,
            height = settings.height,
        }
        self.image = nil
        return card
    end
    local ok, err = pcall(orig_show, self)
    ImageWidget.new = orig_new
    if not ok then logger.warn("sleep-screen:", err) end
end

-- Forgets the card when the sleep screen closes
local orig_cleanup = Screensaver.cleanup
Screensaver.cleanup = function(self, ...)
    self._book_card = nil
    return orig_cleanup(self, ...)
end

-- Submenu "Book card while reading"
local function cardMenu()
    local layout_items = {}
    for __, l in ipairs(LAYOUTS) do
        table.insert(layout_items, {
            text = l[1],
            radio = true,
            checked_func = function() return opt("layout") == l[2] end,
            callback = function() setOpt("layout", l[2]) end,
        })
    end
    return {
        text = "Book card while reading",
        sub_item_table = {
            {
                text = "Show the book card when sleeping in a book",
                checked_func = function() return opt("enabled") end,
                callback = function() setOpt("enabled", not opt("enabled")) end,
                separator = true,
            },
            {
                text_func = function()
                    for __, l in ipairs(LAYOUTS) do
                        if l[2] == opt("layout") then return T("Layout: %1", l[1]) end
                    end
                    return "Layout"
                end,
                enabled_func = function() return opt("enabled") end,
                sub_item_table = layout_items,
            },
            {
                text = "Show reading streak",
                enabled_func = function() return opt("enabled") end,
                checked_func = function() return opt("streak") end,
                callback = function() setOpt("streak", not opt("streak")) end,
            },
        },
    }
end

-- Menu item with the given text, searched through every tab and submenu
local function findItem(items, wanted)
    for __, it in ipairs(items or {}) do
        if it.text == wanted then return it end
        local found = findItem(it.sub_item_table, wanted)
        if found then return found end
    end
end

-- Adds the submenu to Sleep screen, in the reader and in the file manager menus
for __, path in ipairs({ "apps/reader/modules/readermenu", "apps/filemanager/filemanagermenu" }) do
    local Menu = require(path)
    local orig = Menu.setUpdateItemTable
    Menu.setUpdateItemTable = function(self, ...)
        local result = orig(self, ...)
        for __, tab in ipairs(self.tab_item_table or {}) do
            local item = findItem(tab, _("Sleep screen"))
            if item and item.sub_item_table then
                table.insert(item.sub_item_table, 2, cardMenu())
                break
            end
        end
        return result
    end
end
