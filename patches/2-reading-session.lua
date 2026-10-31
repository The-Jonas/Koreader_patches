--[[
2-reading-session.lua — session summary, daily goal with streak, and a recap when coming back

Goal: make every reading session feel like progress — see what you just read,
keep a daily reading streak going, and get back into a book you left aside for
a while without hunting for where you were.

What it does:
  - Session summary: when you close a book, a short message shows the time
    read, pages read, how the percentage moved and the chapters you finished.
    Pages read count from the page where you opened the book: that page is
    zero, so going forward two pages and back two to check something counts as
    nothing, and going back before it shows zero. A jump (table of contents,
    link, go to page) moves the starting point along with you, so only pages
    turned one by one count, wherever they are. Finished chapters work the
    same way. Only page turns count (taps, swipes, keys, scrolling), so
    changing the font or the layout doesn't count either; scroll mode and the
    two-page mode work too. The summary
    only shows after a minimum of pages and/or minutes, chosen from presets or
    set by hand.
  - Daily goal and streak: set a goal in pages or minutes per day. The summary
    shows today's total against the goal and how many days in a row you hit it.
    Totals come from the Reading statistics plugin, so they count every book.
  - "Where was I?": when you open a book you have not opened for a number of
    days, a recap shows how long it has been, the chapter you were in, how much
    of it is left and your last highlights and notes in that book.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. Keep the Reading statistics plugin enabled (needed for the daily goal and
     streak; the summary and the recap work without it).
  3. While reading: menu → Tools → Reading session, to set the goal and turn
     each part on or off.
]]

local CONFIG = {
    -- Defaults for the options in Tools → Reading session
    defaults = {
        summary = true,      -- show the session summary when closing a book
        recap = true,        -- show the recap when opening a book after a while
        recap_days = 7,      -- days without opening a book before the recap shows
        goal_type = "pages", -- "pages" or "minutes"
        goal = 30,           -- daily goal, in pages or minutes
        summary_pages = 5,   -- pages read (net) before the summary shows
        summary_minutes = 0, -- minutes read before the summary shows
    },
    -- Ready-made minimums for the summary: {pages, minutes}
    summary_presets = { { 1, 0 }, { 5, 0 }, { 10, 0 }, { 5, 5 }, { 10, 10 }, { 0, 15 } },
    max_page_secs = 120,     -- time on a single page counted at most (same idea as Reading statistics)
    recap_highlights = 3,    -- how many recent highlights / notes the recap lists
}

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local ReaderUI = require("apps/reader/readerui")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template

-- Value of an option chosen in the menu, or its default from CONFIG
local function opt(key)
    local saved = G_reader_settings:readSetting("reading_session") or {}
    if saved[key] == nil then return CONFIG.defaults[key] end
    return saved[key]
end

-- Saves an option chosen in the menu
local function setOpt(key, value)
    local saved = G_reader_settings:readSetting("reading_session") or {}
    saved[key] = value
    G_reader_settings:saveSetting("reading_session", saved)
end

-- Formats seconds as "1 h 05 min" or "12 min"
local function formatDuration(secs)
    local mins = math.floor(secs / 60 + 0.5)
    if mins >= 60 then
        return string.format("%d h %02d min", math.floor(mins / 60), mins % 60)
    end
    return string.format("%d min", mins)
end

-- "1 page" / "3 pages"
local function plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
end

-- "5 pages and 5 min", "10 pages", "15 min" or "every session"
local function minimumText(pages, minutes)
    if pages > 0 and minutes > 0 then return T("%1 and %2 min", plural(pages, "page"), minutes) end
    if pages > 0 then return plural(pages, "page") end
    if minutes > 0 then return T("%1 min", minutes) end
    return "every session"
end

-- Fraction of the book read up to the current page
local function progress(ui)
    local total = ui.document:getPageCount()
    if not total or total == 0 then return 0 end
    return ui:getCurrentPage() / total
end

-- Pages and seconds read per day ("YYYY-MM-DD" → {pages, secs}) from the Reading statistics database
local function dailyTotals()
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if not util.fileExists(db) then return nil end
    local ok, result = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db)
        local res = conn:exec([[
            SELECT date(start_time, 'unixepoch', 'localtime'), count(*), sum(duration)
            FROM page_stat_data
            WHERE start_time > strftime('%s', 'now', '-400 days')
            GROUP BY 1;
        ]])
        conn:close()
        local days = {}
        if res then
            for i = 1, #res[1] do
                days[res[1][i]] = { pages = tonumber(res[2][i]) or 0, secs = tonumber(res[3][i]) or 0 }
            end
        end
        return days
    end)
    if not ok then
        logger.warn("reading-session: could not read statistics:", result)
        return nil
    end
    return result
end

-- Today's progress toward the goal and the current streak of days that met it
local function goalStatus()
    local days = dailyTotals()
    if not days then return nil end
    local goal, by_minutes = opt("goal"), opt("goal_type") == "minutes"
    local function value(day)
        local d = days[day]
        if not d then return 0 end
        return by_minutes and math.floor(d.secs / 60) or d.pages
    end
    local now = os.time()
    local today = value(os.date("%Y-%m-%d", now))
    local streak, k = 0, today >= goal and 0 or 1
    while value(os.date("%Y-%m-%d", now - k * 86400)) >= goal do
        streak = streak + 1
        k = k + 1
    end
    return { today = today, goal = goal, unit = by_minutes and "min" or "pages", done = today >= goal, streak = streak }
end

-- One line with today's goal progress and the streak, or nil without statistics
local function goalLine()
    local g = goalStatus()
    if not g then return nil end
    local line = T("Daily goal: %1 / %2 %3", g.today, g.goal, g.unit) .. (g.done and " — done!" or "")
    if g.streak > 0 then
        line = line .. "\n" .. T("Streak: %1 in a row", plural(g.streak, "day"))
    end
    return line
end

-- First page of every top-level chapter, in order
local function chapterStarts(ui)
    local ticks = ui.toc and ui.toc:getTocTicks(1) or {}
    local starts = {}
    for _i, page in ipairs(ticks) do
        if #starts == 0 or page > starts[#starts] then table.insert(starts, page) end
    end
    return starts
end

local ReadingSession = WidgetContainer:extend {
    name = "reading_session",
}

-- Starts tracking the session
function ReadingSession:init()
    self.start_time = os.time()
    self.last_turn = self.start_time
    self.read_secs = 0
    self.page_count = 0
    self.chapter_count = 0
    self.ui.menu:registerToMainMenu(self)
end

-- Records where the session started and shows the recap if the book was left aside
function ReadingSession:onReaderReady()
    self.start_page = self.ui:getCurrentPage()
    self.last_page = self.start_page
    self.start_percent = progress(self.ui)
    local days = opt("recap_days")
    if opt("recap") and self.last_closed and self.start_percent > 0 and days > 0
            and os.time() - self.last_closed > days * 86400 then
        UIManager:scheduleIn(0.5, function() self:showRecap() end)
    end
end

-- Page numbers shown at once: 2 in the two-page mode of EPUBs when each side has its own number
local function visibleNumbers(ui)
    local doc = ui.document
    return doc and doc.getVisiblePageNumberCount and doc:getVisiblePageNumberCount() or 1
end

-- Number of top-level chapter starts in (lo, hi]
local function chapterStartsBetween(ui, lo, hi)
    local n = 0
    for _i, s in ipairs(chapterStarts(ui)) do
        if s > lo and s <= hi then n = n + 1 end
    end
    return n
end

-- Adds the time spent on the previous page; while a page is being turned, moving forward counts the
-- pages and moving back takes them off, so the count is how far past the opening page you are; any
-- other move (jumps, font or layout changes) only moves the starting point along with you;
-- chapters entered by turning count the same way
function ReadingSession:onPageUpdate(pageno)
    local now = os.time()
    self.read_secs = self.read_secs + math.min(now - self.last_turn, CONFIG.max_page_secs)
    self.last_turn = now
    if not pageno then return end
    if self.turning and self.last_page and pageno ~= self.last_page then
        local step = pageno - self.last_page
        local extra = visibleNumbers(self.ui) - 1
        local chapters = chapterStartsBetween(self.ui, math.min(pageno, self.last_page) + extra,
            math.max(pageno, self.last_page) + extra)
        self.page_count = self.page_count + step
        self.chapter_count = self.chapter_count + (step > 0 and chapters or -chapters)
    end
    self.last_page = pageno
end

-- Scroll mode reports positions instead of pages; a new page at the top counts like a turn
function ReadingSession:onPosUpdate(_pos, pageno)
    if pageno and pageno ~= self.last_page then self:onPageUpdate(pageno) end
end

-- Marks the page turns of the reader (taps, swipes, keys, scrolling) so only they count as reading
function ReadingSession:watchTurns()
    local mover = self.ui.rolling or self.ui.paging
    if not mover then return end
    for _i, name in ipairs({ "onGotoViewRel", "onPan", "onPanRelease", "onPanning" }) do
        local orig = mover[name]
        if orig then
            mover[name] = function(...)
                self.turning = true
                local ok, result = pcall(orig, ...)
                self.turning = false
                if not ok then error(result, 0) end
                return result
            end
        end
    end
end

-- Builds the "Where was I?" text: time away, current chapter, pages left and last highlights
function ReadingSession:showRecap()
    local ui = self.ui
    local page = ui:getCurrentPage()
    local away = math.floor((os.time() - self.last_closed) / 86400)
    local lines = { T("Welcome back! Last read %1 ago.", plural(away, "day")), "" }

    local chapter = ui.toc and ui.toc:getTocTitleByPage(page)
    local total = ui.document:getPageCount()
    local next_start
    for _i, s in ipairs(chapterStarts(ui)) do
        if s > page then next_start = s break end
    end
    local left = (next_start or total + 1) - page
    table.insert(lines, T("You are at %1%", math.floor(self.start_percent * 100)))
    if chapter and chapter ~= "" then
        table.insert(lines, T("Chapter: %1 (%2 left)", chapter, plural(left, "page")))
    end

    local annotations = ui.annotation and ui.annotation.annotations or {}
    local recent = {}
    for _i, a in ipairs(annotations) do
        if a.text and a.text ~= "" then table.insert(recent, a) end
    end
    table.sort(recent, function(a, b) return (a.datetime or "") > (b.datetime or "") end)
    if #recent > 0 then
        table.insert(lines, "")
        table.insert(lines, "Your last highlights:")
        for i = 1, math.min(CONFIG.recap_highlights, #recent) do
            local a = recent[i]
            local text = util.cleanupSelectedText(a.text)
            if #text > 140 then text = text:sub(1, 137) .. "…" end
            local line = "• “" .. text .. "”"
            if a.note and a.note ~= "" then line = line .. "\n  Note: " .. a.note end
            table.insert(lines, line)
        end
    end
    UIManager:show(InfoMessage:new { text = table.concat(lines, "\n"), show_icon = false })
end

-- Collects the session numbers while the document is still open and shows the summary afterwards
function ReadingSession:onCloseDocument()
    if not opt("summary") then return end
    self:onPageUpdate(nil)
    local pages = math.max(0, self.page_count)
    if pages < math.max(1, opt("summary_pages")) then return end
    if self.read_secs < opt("summary_minutes") * 60 then return end
    local ui = self.ui
    local end_percent = progress(ui)
    -- Where the session started once jumps are taken out, so the percentage moves with them too
    local total = ui.document:getPageCount()
    local from_percent = total > 0 and (self.last_page - self.page_count) / total or self.start_percent
    local data = {
        secs = self.read_secs,
        pages = pages,
        from = math.floor(from_percent * 100),
        to = math.floor(end_percent * 100),
        chapters = math.max(0, self.chapter_count),
    }
    UIManager:scheduleIn(0.5, function() self.showSummary(data) end)
end

-- Shows the session summary (after the statistics of this session are saved)
function ReadingSession.showSummary(data)
    local lines = {
        "Session summary",
        formatDuration(data.secs) .. " · " .. plural(data.pages, "page"),
        T("%1% → %2% (+%3%)", data.from, data.to, math.max(0, data.to - data.from)),
    }
    if data.chapters > 0 then
        table.insert(lines, T("Chapters finished: %1", data.chapters))
    end
    local goal = goalLine()
    if goal then
        table.insert(lines, "")
        table.insert(lines, goal)
    end
    UIManager:show(InfoMessage:new { text = table.concat(lines, "\n"), timeout = 8, show_icon = false })
end

-- Opens a number picker for one of the summary minimums
local function askMinimum(key, title, max, touchmenu)
    UIManager:show(SpinWidget:new {
        title_text = title,
        value = opt(key),
        value_min = 0,
        value_max = max,
        value_step = 1,
        value_hold_step = 5,
        default_value = CONFIG.defaults[key],
        ok_always_enabled = true,
        callback = function(spin)
            setOpt(key, spin.value)
            touchmenu:updateItems()
        end,
    })
end

-- Submenu with the summary minimum presets and the two values to set by hand
local function summaryMinimumMenu()
    local items = {}
    for _i, p in ipairs(CONFIG.summary_presets) do
        table.insert(items, {
            text = minimumText(p[1], p[2]),
            radio = true,
            checked_func = function() return opt("summary_pages") == p[1] and opt("summary_minutes") == p[2] end,
            callback = function()
                setOpt("summary_pages", p[1])
                setOpt("summary_minutes", p[2])
            end,
        })
    end
    items[#items].separator = true
    table.insert(items, {
        text_func = function() return T("Minimum pages: %1", opt("summary_pages")) end,
        keep_menu_open = true,
        callback = function(touchmenu) askMinimum("summary_pages", "Minimum pages", 200, touchmenu) end,
    })
    table.insert(items, {
        text_func = function() return T("Minimum minutes: %1", opt("summary_minutes")) end,
        keep_menu_open = true,
        callback = function(touchmenu) askMinimum("summary_minutes", "Minimum minutes", 120, touchmenu) end,
        separator = true,
    })
    table.insert(items, {
        text = "Pages count net: turning back takes one off",
        enabled_func = function() return false end,
    })
    return items
end

-- Adds Tools → Reading session
function ReadingSession:addToMainMenu(menu_items)
    menu_items.reading_session = {
        text = "Reading session",
        sub_item_table = {
            {
                text_func = function()
                    local g = goalStatus()
                    if not g then return "Daily goal needs Reading statistics" end
                    return T("Today: %1 / %2 %3 · streak: %4", g.today, g.goal, g.unit, plural(g.streak, "day"))
                end,
                enabled_func = function() return false end,
                separator = true,
            },
            {
                text_func = function()
                    return T("Daily goal: %1 %2", opt("goal"), opt("goal_type") == "minutes" and "min" or "pages")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new {
                        title_text = "Daily goal",
                        value = opt("goal"),
                        value_min = 1,
                        value_max = 1000,
                        value_step = 5,
                        value_hold_step = 25,
                        default_value = CONFIG.defaults.goal,
                        ok_always_enabled = true,
                        callback = function(spin)
                            setOpt("goal", spin.value)
                            touchmenu_instance:updateItems()
                        end,
                    })
                end,
            },
            {
                text = "Goal in pages",
                radio = true,
                checked_func = function() return opt("goal_type") == "pages" end,
                callback = function() setOpt("goal_type", "pages") end,
            },
            {
                text = "Goal in minutes",
                radio = true,
                checked_func = function() return opt("goal_type") == "minutes" end,
                callback = function() setOpt("goal_type", "minutes") end,
                separator = true,
            },
            {
                text = "Summary when closing a book",
                checked_func = function() return opt("summary") end,
                callback = function() setOpt("summary", not opt("summary")) end,
            },
            {
                text_func = function()
                    return "Show it after: " .. minimumText(opt("summary_pages"), opt("summary_minutes"))
                end,
                enabled_func = function() return opt("summary") end,
                sub_item_table_func = summaryMinimumMenu,
            },
            {
                text = "Recap when coming back to a book",
                checked_func = function() return opt("recap") end,
                callback = function() setOpt("recap", not opt("recap")) end,
            },
            {
                text_func = function() return T("Recap after: %1", plural(opt("recap_days"), "day")) end,
                enabled_func = function() return opt("recap") end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new {
                        title_text = "Recap after (days)",
                        value = opt("recap_days"),
                        value_min = 1,
                        value_max = 365,
                        value_step = 1,
                        value_hold_step = 7,
                        default_value = CONFIG.defaults.recap_days,
                        ok_always_enabled = true,
                        callback = function(spin)
                            setOpt("recap_days", spin.value)
                            touchmenu_instance:updateItems()
                        end,
                    })
                end,
            },
        },
    }
end

-- Puts "Reading session" right after Reading statistics in the Tools tab
local order = require("ui/elements/reader_menu_order")
if order.tools and not util.arrayContains(order.tools, "reading_session") then
    local pos = #order.tools
    for i, id in ipairs(order.tools) do
        if id == "statistics" then pos = i break end
    end
    table.insert(order.tools, pos + 1, "reading_session")
end

-- Time the book's settings were last saved, read before opening writes them again
local function lastSaved(file)
    local sidecar = file and DocSettings:findSidecarFile(file)
    return sidecar and lfs.attributes(sidecar, "modification")
end

-- Registers the session tracker in every opened book
local orig_init = ReaderUI.init
ReaderUI.init = function(self, ...)
    local last_closed = lastSaved(self.document and self.document.file)
    orig_init(self, ...)
    local session = ReadingSession:new { ui = self, last_closed = last_closed }
    self:registerModule("reading_session", session)
    session:watchTurns()
    session:onReaderReady()
end
