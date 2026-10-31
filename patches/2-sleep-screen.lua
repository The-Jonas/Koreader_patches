--[[
2-sleep-screen.lua — book cover and reading progress on the sleep screen

Goal: when the device sleeps in the middle of a book, the sleep screen shows that
book — a large cover and where you are in the chapter and in the book — instead
of a random picture; outside a book, the random pictures keep rotating as before.

What it does:
  - Inside a book: the sleep screen shows the cover and two blocks of details:
      Chapter  name, progress bar, page in the chapter, percentage, time left
      Book     title, progress bar with chapter marks, page, percentage, time left
    plus a line with the reading streak, today's goal and the time it went to sleep.
  - Three choices with two options each:
      Details   columns (chapter and book side by side, largest cover) or rows
      Theme     light or dark
      Position  details below or above the cover
  - In the file manager: nothing changes, the wallpaper chosen in the sleep screen
    settings is used (for example a random image from a folder).
  - Books marked "Do not show this book cover on sleep screen" and books without a
    cover keep the regular wallpaper.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. Settings → Screen → Sleep screen → Wallpaper: pick "Show random image from
     folder" (or "Show book cover"); the book screen replaces it only while reading.
  3. Settings → Screen → Sleep screen → Book on sleep screen: on/off, details,
     theme, position and the streak line.
  Time left comes from Reading statistics; the streak and goal from
  2-reading-session.lua (any day with reading counts when that patch has no goal).
]]

local CONFIG = {
    defaults = {
        enabled = true,
        arrangement = "columns", -- details in "columns" or in rows ("stacked")
        theme = "light",         -- "light" or "dark"
        position = "below",      -- details "below" or "above" the cover
        streak = true,           -- line with streak, goal and time
    },
    corner_radius = 28,          -- rounded corners of the cover, in pixels at 1236 px wide
}

local CHOICES = {
    arrangement = { { "Columns", "columns" }, { "Rows", "stacked" } },
    theme = { { "Light", "light" }, { "Dark", "dark" } },
    position = { { "Below the cover", "below" }, { "Above the cover", "above" } },
}

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local Screen = require("device").screen
local Screensaver = require("ui/screensaver")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local THEMES = {
    light = { bg = Blitbuffer.COLOR_WHITE, fg = Blitbuffer.COLOR_BLACK, border = Blitbuffer.COLOR_BLACK,
        muted = Blitbuffer.Color8(0x69), track = Blitbuffer.Color8(0xE1) },
    dark = { bg = Blitbuffer.COLOR_BLACK, fg = Blitbuffer.COLOR_WHITE, border = Blitbuffer.COLOR_WHITE,
        muted = Blitbuffer.Color8(0x96), track = Blitbuffer.Color8(0x46) },
}

-- Value of an option chosen in the menu, or its default from CONFIG
local function opt(key)
    local saved = G_reader_settings:readSetting("sleep_screen_book") or {}
    if saved[key] == nil then return CONFIG.defaults[key] end
    return saved[key]
end

-- Saves an option chosen in the menu
local function setOpt(key, value)
    local saved = G_reader_settings:readSetting("sleep_screen_book") or {}
    saved[key] = value
    G_reader_settings:saveSetting("sleep_screen_book", saved)
end

-- Formats seconds as "1 h 05 min" or "12 min"
local function formatDuration(secs)
    local mins = math.max(1, math.floor(secs / 60 + 0.5))
    if mins >= 60 then
        return string.format("%d h %02d min", math.floor(mins / 60), mins % 60)
    end
    return string.format("%d min", mins)
end

-- Streak of days that met the daily goal, plus today's value and the goal
local function streakInfo()
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if not util.fileExists(db) then return end
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
        return
    end
    local session = G_reader_settings:readSetting("reading_session")
    local goal = session and (session.goal or 30) or 1
    local by_minutes = session and session.goal_type == "minutes"
    local function value(day)
        local d = days[day]
        if not d then return 0 end
        return by_minutes and math.floor(d[2] / 60) or d[1]
    end
    local now = os.time()
    local today = value(os.date("%Y-%m-%d", now))
    local k = today >= goal and 0 or 1
    local streak = 0
    while value(os.date("%Y-%m-%d", now - k * 86400)) >= goal do
        streak = streak + 1
        k = k + 1
    end
    return { streak = streak, today = today, goal = session and goal }
end

-- Everything the screen shows about the open book
local function collectInfo(ui)
    local props = ui.doc_props or {}
    local page = ui:getCurrentPage()
    local total = ui.document:getPageCount()
    local info = {
        title = props.display_title or "",
        page = page,
        pages = total,
        percent = total > 0 and page / total or 0,
        ticks = {},
        slept_at = os.date("%H:%M"),
    }
    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        local __, idx, count = ui.pagemap:getCurrentPageLabel(true)
        if idx and count then info.page, info.pages = idx, count end
    end
    local avg = ui.statistics and ui.statistics.avg_time
    if not (avg and avg == avg and avg > 0) then avg = nil end
    if avg then info.book_left = formatDuration(ui.document:getTotalPagesLeft(page) * avg) end
    if ui.toc then
        info.chapter = ui.toc:getTocTitleByPage(page)
        for __, p in ipairs(ui.toc:getTocTicks(1) or {}) do
            if p > 1 and p <= total then table.insert(info.ticks, (p - 1) / total) end
        end
        local done = ui.toc:getChapterPagesDone(page)
        local count = ui.toc:getChapterPageCount(page)
        if done and count and count > 0 then
            info.chapter_page, info.chapter_pages = done + 1, count
        end
        local left = ui.toc:getChapterPagesLeft(page, true)
        if left and avg then info.chapter_left = formatDuration((left + 1) * avg) end
    end
    if opt("streak") then info.streak = streakInfo() end
    return info
end

---------------------------------------------------------------- drawing

local BookScreen = Widget:extend {
    info = nil,
    cover = nil,
    width = 0,
    height = 0,
}

-- Pixels for a size given for a 1236 px wide screen
function BookScreen:px(v)
    return math.floor(v * self.k + 0.5)
end

-- Font face of a given pixel size; style is "regular", "bold" or "italic"
function BookScreen:face(style, size)
    local pt = self:px(size) * 1000 / Screen:scaleBySize(1000)
    if style == "italic" then
        local ok, f = pcall(Font.getFace, Font, "NotoSans-Italic.ttf", pt)
        if ok and f then return f end
    end
    return Font:getFace(style == "bold" and "tfont" or "cfont", pt)
end

-- One line of text at (x, y), cut to width w and aligned inside it
function BookScreen:line(bb, str, x, y, w, size, style, color, align)
    if not str or str == "" then return end
    local tw = TextWidget:new {
        text = str,
        face = self:face(style, size),
        bold = style == "bold",
        fgcolor = color,
        max_width = w,
    }
    local tx = x
    local sw = tw:getSize().w
    if align == "center" then tx = x + math.floor((w - sw) / 2)
    elseif align == "right" then tx = x + w - sw end
    tw:paintTo(bb, tx, y)
    tw:free()
end

-- Rounded progress bar, with notches at the given fractions
function BookScreen:bar(bb, x, y, w, h, fraction, ticks)
    local c = self.colors
    local r = math.floor(h / 2)
    bb:paintRoundedRect(x, y, w, h, c.track, r)
    local fw = math.floor(w * math.max(0, math.min(1, fraction)))
    if fw > 0 then bb:paintRoundedRect(x, y, math.max(fw, h), h, c.fg, r) end
    if ticks and #ticks <= 60 then
        local notch = math.max(2, self:px(3))
        for __, t in ipairs(ticks) do
            local tx = x + math.floor(w * t)
            bb:paintRect(tx, y, notch, h, tx < x + fw and c.track or c.bg)
        end
    end
end

-- Texts and fractions of the chapter and book blocks
function BookScreen:blocks()
    local i = self.info
    local pct = function(f) return string.format("%d%%", math.floor(f * 100)) end
    local chapter = {
        label = "Chapter",
        title = i.chapter or "—",
        fraction = i.chapter_page and i.chapter_page / i.chapter_pages or 0,
        left = i.chapter_page and T("page %1 of %2", i.chapter_page, i.chapter_pages) or "",
        right = i.chapter_page and pct(i.chapter_page / i.chapter_pages) or "",
        note = i.chapter_left and T("%1 left", i.chapter_left) or "",
    }
    local book = {
        label = "Book",
        title = i.title,
        fraction = i.percent,
        ticks = i.ticks,
        left = T("page %1 of %2", i.page, i.pages),
        right = pct(i.percent),
        note = i.book_left and T("%1 left", i.book_left) or "",
    }
    return chapter, book
end

-- Height of the details for the current arrangement
function BookScreen:detailsHeight()
    if opt("arrangement") == "stacked" then
        return self:px((44 + 60 + 30 + 44 + 50) * 2 + 36)
    end
    return self:px(40 + 56 + 28 + 42 + 40)
end

-- Chapter and book side by side, each left-aligned in its column
function BookScreen:paintColumns(bb, x, y, w)
    local c = self.colors
    local gap = self:px(70)
    local col = math.floor((w - gap) / 2)
    local chapter, book = self:blocks()
    for n, b in ipairs({ chapter, book }) do
        local cx, cy = x + (n - 1) * (col + gap), y
        self:line(bb, b.label:upper(), cx, cy, col, 24, "bold", c.muted)
        cy = cy + self:px(40)
        self:line(bb, b.title, cx, cy, col, 36, "bold", c.fg)
        cy = cy + self:px(56)
        self:bar(bb, cx, cy, col, self:px(14), b.fraction, b.ticks)
        cy = cy + self:px(28)
        self:line(bb, b.left, cx, cy, col, 27, "regular", c.muted)
        self:line(bb, b.right, cx, cy, col, 27, "bold", c.fg, "right")
        cy = cy + self:px(42)
        self:line(bb, b.note, cx, cy, col, 27, "italic", c.fg)
    end
    bb:paintRect(x + col + math.floor(gap / 2), y + self:px(6), self:px(2), self:px(194), c.track)
end

-- Chapter above book, centered
function BookScreen:paintStacked(bb, x, y, w)
    local c = self.colors
    local chapter, book = self:blocks()
    for n, b in ipairs({ chapter, book }) do
        self:line(bb, b.label:upper(), x, y, w, 24, "bold", c.muted, "center")
        y = y + self:px(44)
        self:line(bb, b.title, x, y, w, 40, "bold", c.fg, "center")
        y = y + self:px(60)
        self:bar(bb, x, y, w, self:px(16), b.fraction, b.ticks)
        y = y + self:px(30)
        self:line(bb, b.left, x, y, w, 28, "regular", c.muted)
        self:line(bb, b.right, x, y, w, 28, "bold", c.fg, "right")
        y = y + self:px(44)
        self:line(bb, b.note, x, y, w, 28, "italic", c.fg, "center")
        y = y + self:px(50)
        if n == 1 then
            bb:paintRect(x + self:px(120), y + self:px(4), w - self:px(240), self:px(2), c.track)
            y = y + self:px(36)
        end
    end
end

-- Streak and goal on the left, time on the right; the rule sits on the side facing the details
function BookScreen:paintFooter(bb, x, y, w, rule_first)
    local c = self.colors
    local s = self.info.streak
    local left = ""
    if s then
        left = T("%1-day streak", s.streak)
        if s.goal then left = left .. T("  ·  goal %1 / %2", s.today, s.goal) end
    end
    local text_y = rule_first and y + self:px(22) or y
    bb:paintRect(x, rule_first and y or y + self:px(50), w, self:px(2), c.track)
    self:line(bb, left, x, text_y, w, 26, "regular", c.muted)
    self:line(bb, T("slept at %1", self.info.slept_at), x, text_y, w, 26, "regular", c.muted, "right")
end

-- Paints the cover scaled to fit max_w × max_h and centered in that box, with rounded corners
function BookScreen:paintCover(bb, x, y, max_w, max_h)
    local c = self.colors
    local scale = math.min(max_w / self.cover:getWidth(), max_h / self.cover:getHeight())
    local img = ImageWidget:new { image = self.cover, image_disposable = false, scale_factor = scale }
    local size = img:getSize()
    local cx = x + math.floor((max_w - size.w) / 2)
    local cy = y + math.floor((max_h - size.h) / 2)
    img:paintTo(bb, cx, cy)
    img:free()
    local r = self:px(CONFIG.corner_radius)
    for dy = 0, r - 1 do
        local dist = r - dy - 0.5
        local span = r - math.floor(math.sqrt(math.max(0, r * r - dist * dist)) + 0.5)
        if span > 0 then
            bb:paintRect(cx, cy + dy, span, 1, c.bg)
            bb:paintRect(cx + size.w - span, cy + dy, span, 1, c.bg)
            bb:paintRect(cx, cy + size.h - 1 - dy, span, 1, c.bg)
            bb:paintRect(cx + size.w - span, cy + size.h - 1 - dy, span, 1, c.bg)
        end
    end
    bb:paintBorder(cx, cy, size.w, size.h, self:px(2), c.border, r)
end

-- The screen always covers the whole display
function BookScreen:getSize()
    return Geom:new { w = self.width, h = self.height }
end

-- Lays out cover, details and footer for the chosen options
function BookScreen:paintTo(bb, x, y)
    self.dimen = Geom:new { x = x, y = y, w = self.width, h = self.height }
    self.k = self.width / 1236
    self.colors = THEMES[opt("theme")] or THEMES.light
    local w, h = self.width, self.height
    bb:paintRect(x, y, w, h, self.colors.bg)
    local m = self:px(opt("arrangement") == "stacked" and 90 or 80)
    local edge, gap = self:px(60), self:px(50)
    local footer = opt("streak")
    local footer_h = footer and self:px(80) or 0
    local details_h = self:detailsHeight()
    local cover_h = h - 2 * edge - details_h - gap - footer_h
    local paint = opt("arrangement") == "stacked" and self.paintStacked or self.paintColumns
    if opt("position") == "above" then
        if footer then self:paintFooter(bb, x + m, y + edge - self:px(16), w - 2 * m, false) end
        local dy = y + edge + footer_h
        paint(self, bb, x + m, dy, w - 2 * m)
        self:paintCover(bb, x + m, dy + details_h + gap, w - 2 * m, cover_h)
    else
        self:paintCover(bb, x + m, y + edge, w - 2 * m, cover_h)
        paint(self, bb, x + m, y + edge + cover_h + gap, w - 2 * m)
        if footer then self:paintFooter(bb, x + m, y + h - edge - self:px(28), w - 2 * m, true) end
    end
end

-- Frees the cover image
function BookScreen:free()
    if self.cover then
        self.cover:free()
        self.cover = nil
    end
end
BookScreen.onCloseWidget = BookScreen.free

---------------------------------------------------------------- sleep screen hooks

-- Swaps the wallpaper for the book screen when sleeping inside a book
local orig_setup = Screensaver.setup
Screensaver.setup = function(self, event, event_message)
    orig_setup(self, event, event_message)
    self._book_info = nil
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
    self._book_info = info
end

-- Builds the book screen where the wallpaper image would be built
local orig_show = Screensaver.show
Screensaver.show = function(self)
    if not self._book_info then return orig_show(self) end
    local info = self._book_info
    local orig_new = ImageWidget.new
    ImageWidget.new = function(cls, settings)
        ImageWidget.new = orig_new
        if cls ~= ImageWidget then return orig_new(cls, settings) end
        self.image = nil
        return BookScreen:new { info = info, cover = settings.image, width = settings.width, height = settings.height }
    end
    local ok, err = pcall(orig_show, self)
    ImageWidget.new = orig_new
    if not ok then logger.warn("sleep-screen:", err) end
end

-- Forgets the book when the sleep screen closes
local orig_cleanup = Screensaver.cleanup
Screensaver.cleanup = function(self, ...)
    self._book_info = nil
    return orig_cleanup(self, ...)
end

---------------------------------------------------------------- menu

-- Entry showing the current choice of an option, opening its radio list
local function choiceMenu(title, key)
    local items = {}
    for __, choice in ipairs(CHOICES[key]) do
        table.insert(items, {
            text = choice[1],
            radio = true,
            checked_func = function() return opt(key) == choice[2] end,
            callback = function() setOpt(key, choice[2]) end,
        })
    end
    return {
        text_func = function()
            for __, choice in ipairs(CHOICES[key]) do
                if choice[2] == opt(key) then return T("%1: %2", title, choice[1]) end
            end
            return title
        end,
        enabled_func = function() return opt("enabled") end,
        sub_item_table = items,
    }
end

-- Submenu "Book on sleep screen"
local function bookMenu()
    return {
        text = "Book on sleep screen",
        sub_item_table = {
            {
                text = "Show the book when sleeping in it",
                checked_func = function() return opt("enabled") end,
                callback = function() setOpt("enabled", not opt("enabled")) end,
                separator = true,
            },
            choiceMenu("Details", "arrangement"),
            choiceMenu("Theme", "theme"),
            choiceMenu("Position", "position"),
            {
                text = "Show streak, goal and time",
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
                table.insert(item.sub_item_table, 2, bookMenu())
                break
            end
        end
        return result
    end
end
