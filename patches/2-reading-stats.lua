--[[
2-reading-stats.lua — one clear screen for your reading statistics

Goal: see how a book, the week and the year are going at a glance, with every
number labelled in words, and the same daily goal and streak used by the other
reading patches.

What it does:
  Opens a full-screen page with three tabs (swipe left/right or tap a tab):
    Book  progress with chapter marks, time read and time left (chapter and
          book), reading speed, days spent on the book, start date and an
          estimate of when you will finish at your recent pace
    Week  today against the daily goal, the week day by day with the goal line,
          this week against last week, current and best streak, and a button to
          KOReader's calendar
    Year  month by month in hours, pages or days, totals for the year, books
          finished, and the books read in a month when you tap it
  The daily goal and the streak are the ones of 2-reading-session.lua (a goal in
  pages or minutes per day); without that patch, 30 pages a day is used.
  Data comes from the Reading statistics plugin, which must be enabled.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. Open it from menu → Tools → Reading stats, or assign the "Reading stats"
     action to a gesture (Settings → Taps and gestures → Gesture manager).
  3. Tap ✕, swipe down or press Back to close.
]]

local CONFIG = {
    pace_days = 14,   -- days of recent reading used for the finish estimate
    default_goal = 30, -- daily goal when 2-reading-session.lua has none saved
}

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local MUTED = Blitbuffer.Color8(0x66)
local BAR = Blitbuffer.Color8(0x99)
local TRACK = Blitbuffer.Color8(0xE5)
local DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local WEEKDAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

-- Pixels for a size given at 160 dpi
local function px(v) return Screen:scaleBySize(v) end

-- Formats seconds as "1 h 05 min" or "12 min"
local function formatDuration(secs)
    local mins = math.max(0, math.floor((secs or 0) / 60 + 0.5))
    if mins >= 60 then
        return string.format("%d h %02d min", math.floor(mins / 60), mins % 60)
    end
    return string.format("%d min", mins)
end

-- "1 page" / "3 pages"
local function plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
end

-- "YYYY-MM-DD" for a time, and the time at noon of a "YYYY-MM-DD" day
local function dayKey(t) return os.date("%Y-%m-%d", t) end
local function noon(y, m, d) return os.time { year = y, month = m, day = d, hour = 12 } end

-- Daily goal of 2-reading-session.lua: value and unit ("pages" or "minutes")
local function dailyGoal()
    local s = G_reader_settings:readSetting("reading_session") or {}
    return s.goal or CONFIG.default_goal, s.goal_type == "minutes" and "minutes" or "pages"
end

-- Runs a query on the statistics database and returns its columns, or nil
local function query(sql)
    if not util.fileExists(DB_PATH) then return end
    local ok, res = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DB_PATH)
        local r = conn:exec(sql)
        conn:close()
        return r
    end)
    if not ok then
        logger.warn("reading-stats:", res)
        return
    end
    return res
end

-- Pages and seconds of every day with reading ("YYYY-MM-DD" → {pages, secs})
local function allDays()
    local days = {}
    local res = query([[
        SELECT date(start_time, 'unixepoch', 'localtime'), count(*), sum(duration)
        FROM page_stat_data GROUP BY 1;
    ]])
    if res then
        for i = 1, #res[1] do
            days[res[1][i]] = { pages = tonumber(res[2][i]) or 0, secs = tonumber(res[3][i]) or 0 }
        end
    end
    return days
end

-- Value of a day in the goal unit
local function dayValue(days, key, unit)
    local d = days[key]
    if not d then return 0 end
    return unit == "minutes" and math.floor(d.secs / 60) or d.pages
end

-- Current streak (ending today or yesterday) and best streak of days that met the goal
local function streaks(days, goal, unit)
    local now = os.time()
    local k = dayValue(days, dayKey(now), unit) >= goal and 0 or 1
    local current = 0
    while dayValue(days, dayKey(now - k * 86400), unit) >= goal do
        current = current + 1
        k = k + 1
    end
    local keys = {}
    for key in pairs(days) do
        if dayValue(days, key, unit) >= goal then table.insert(keys, key) end
    end
    table.sort(keys)
    local best, run, prev = 0, 0, nil
    for __, key in ipairs(keys) do
        local y, m, d = key:match("(%d+)-(%d+)-(%d+)")
        local t = noon(tonumber(y), tonumber(m), tonumber(d))
        run = (prev and dayKey(prev + 86400) == key) and run + 1 or 1
        best = math.max(best, run)
        prev = t
    end
    return current, math.max(best, current)
end

-- Numbers for the Book tab, or nil when no book is open or statistics are off
local function bookData(ui)
    local stats = ui and ui.statistics
    if not (ui and ui.document and stats and stats.id_curr_book) then return end
    pcall(stats.insertDB, stats)
    local id = tonumber(stats.id_curr_book)
    local res = query(string.format([[
        SELECT sum(duration), count(DISTINCT page), count(DISTINCT date(start_time, 'unixepoch', 'localtime')),
               min(start_time)
        FROM page_stat WHERE id_book = %d;
    ]], id))
    local recent = query(string.format([[
        SELECT count(DISTINCT page) FROM page_stat WHERE id_book = %d AND start_time > %d;
    ]], id, os.time() - CONFIG.pace_days * 86400))
    local page = ui:getCurrentPage()
    local total = ui.document:getPageCount()
    local d = {
        title = ui.doc_props and ui.doc_props.display_title or "",
        author = ui.doc_props and ui.doc_props.authors and ui.doc_props.authors:gsub("\n", ", ") or nil,
        page = page,
        total = total,
        percent = total > 0 and page / total or 0,
        secs = res and tonumber(res[1][1]) or 0,
        pages_read = res and tonumber(res[2][1]) or 0,
        days = res and tonumber(res[3][1]) or 0,
        first = res and tonumber(res[4][1]),
        recent_pages = recent and tonumber(recent[1][1]) or 0,
        avg = stats.avg_time,
        ticks = {},
    }
    if ui.toc then
        for __, p in ipairs(ui.toc:getTocTicks(1) or {}) do
            if p > 1 and p <= total then table.insert(d.ticks, (p - 1) / total) end
        end
        d.chapter_left = ui.toc:getChapterPagesLeft(page, true)
    end
    d.chapters = #d.ticks + 1
    d.chapters_done = 0
    for __, t in ipairs(d.ticks) do
        if t <= (page - 1) / total then d.chapters_done = d.chapters_done + 1 end
    end
    d.highlights, d.notes = 0, 0
    for __, a in ipairs(ui.annotation and ui.annotation.annotations or {}) do
        if a.drawer then d.highlights = d.highlights + 1 end
        if a.note and a.note ~= "" then d.notes = d.notes + 1 end
    end
    local summary = ui.doc_settings and ui.doc_settings:readSetting("summary") or {}
    d.started = summary.started_on
    return d
end

-- Books finished per month of a year, from the reading history ("MM" → list of titles)
local function finishedInYear(year)
    local ReadHistory = require("readhistory")
    local DocSettings = require("docsettings")
    local by_month, count = {}, 0
    for __, item in ipairs(ReadHistory.hist or {}) do
        if item.file and DocSettings:hasSidecarFile(item.file) then
            local ok, ds = pcall(DocSettings.open, DocSettings, item.file)
            local summary = ok and ds:readSetting("summary")
            if summary and summary.status == "complete" then
                local date = summary.finished_on or summary.modified
                if date and date:sub(1, 4) == tostring(year) then
                    local m = date:sub(6, 7)
                    local props = ds:readSetting("doc_props") or {}
                    by_month[m] = by_month[m] or {}
                    table.insert(by_month[m], props.title or item.text)
                    count = count + 1
                end
            end
        end
    end
    return by_month, count
end

-- Hours, pages and days per month of a year
local function yearData(year)
    local from, to = os.time { year = year, month = 1, day = 1, hour = 0 }, os.time { year = year + 1, month = 1, day = 1, hour = 0 }
    local res = query(string.format([[
        SELECT strftime('%%m', start_time, 'unixepoch', 'localtime'), count(*), sum(duration),
               count(DISTINCT date(start_time, 'unixepoch', 'localtime'))
        FROM page_stat_data WHERE start_time >= %d AND start_time < %d GROUP BY 1;
    ]], from, to))
    local months = {}
    for m = 1, 12 do months[m] = { pages = 0, secs = 0, days = 0 } end
    if res then
        for i = 1, #res[1] do
            local m = tonumber(res[1][i])
            months[m] = { pages = tonumber(res[2][i]) or 0, secs = tonumber(res[3][i]) or 0, days = tonumber(res[4][i]) or 0 }
        end
    end
    local first = query("SELECT min(start_time) FROM page_stat_data;")
    local first_year = first and tonumber(first[1][1]) and tonumber(os.date("%Y", tonumber(first[1][1])))
    return months, first_year or year
end

-- Books read in a month, with time spent on each
local function monthBooks(year, month)
    local from = os.time { year = year, month = month, day = 1, hour = 0 }
    local to = month == 12 and os.time { year = year + 1, month = 1, day = 1, hour = 0 }
        or os.time { year = year, month = month + 1, day = 1, hour = 0 }
    local res = query(string.format([[
        SELECT book.title, sum(duration), count(*) FROM page_stat_data
        JOIN book ON book.id = id_book WHERE start_time >= %d AND start_time < %d
        GROUP BY id_book ORDER BY 2 DESC;
    ]], from, to))
    local list = {}
    if res then
        for i = 1, #res[1] do
            table.insert(list, { title = res[1][i], secs = tonumber(res[2][i]) or 0, pages = tonumber(res[3][i]) or 0 })
        end
    end
    return list
end

---------------------------------------------------------------- drawing helpers

-- Single line of text at (x, y); align inside width w; returns its width and height
local function drawText(bb, str, x, y, size, opts)
    opts = opts or {}
    local tw = TextWidget:new {
        text = str,
        face = Font:getFace(opts.bold and "tfont" or "cfont", size),
        bold = opts.bold,
        fgcolor = opts.color or BLACK,
        max_width = opts.w,
    }
    local s = tw:getSize()
    local tx = x
    if opts.w and opts.align == "center" then tx = x + math.floor((opts.w - s.w) / 2)
    elseif opts.w and opts.align == "right" then tx = x + opts.w - s.w end
    if opts.bg then bb:paintRect(tx - px(2), y, s.w + px(4), s.h, opts.bg) end
    tw:paintTo(bb, tx, y)
    tw:free()
    return s.w, s.h
end

-- Wrapped text block of width w; returns its height
local function drawBlock(bb, str, x, y, w, size, opts)
    opts = opts or {}
    local tb = TextBoxWidget:new {
        text = str,
        face = Font:getFace(opts.bold and "tfont" or "cfont", size),
        bold = opts.bold,
        width = w,
        alignment = opts.align or "left",
        fgcolor = opts.color or BLACK,
    }
    if opts.lines and tb:getSize().h > tb.line_height_px * opts.lines then
        local h = tb.line_height_px * opts.lines
        tb:free()
        tb = TextBoxWidget:new {
            text = str, face = Font:getFace(opts.bold and "tfont" or "cfont", size), bold = opts.bold,
            width = w, alignment = opts.align or "left", fgcolor = opts.color or BLACK,
            height = h, height_adjust = true, height_overflow_show_ellipsis = true,
        }
    end
    local h = tb:getSize().h
    tb:paintTo(bb, x, y)
    tb:free()
    return h
end

-- Section title in small gray capitals with a line under it; returns its height
local function drawSection(bb, title, x, y, w)
    local _, h = drawText(bb, title:upper(), x, y, 14, { color = MUTED, bold = true })
    bb:paintRect(x, y + h + px(4), w, px(1), TRACK)
    return h + px(14)
end

-- Big value with a label under it; returns its height
local function drawCell(bb, value, label, x, y, w)
    local _, vh = drawText(bb, value, x, y, 26, { bold = true, w = w })
    local _, lh = drawText(bb, label, x, y + vh, 15, { color = MUTED, w = w })
    return vh + lh
end

-- Two cells side by side; returns the row height
local function drawRow(bb, x, y, w, a, b)
    local half = math.floor((w - px(16)) / 2)
    local h1 = drawCell(bb, a[1], a[2], x, y, half)
    local h2 = b and drawCell(bb, b[1], b[2], x + half + px(16), y, half) or 0
    return math.max(h1, h2) + px(16)
end

-- Rounded progress bar with white notches at chapter starts
local function drawProgress(bb, x, y, w, h, fraction, ticks)
    local r = math.floor(h / 2)
    bb:paintRoundedRect(x, y, w, h, TRACK, r)
    local fw = math.floor(w * math.max(0, math.min(1, fraction)))
    if fw > 0 then bb:paintRoundedRect(x, y, math.max(fw, h), h, BLACK, r) end
    if ticks and #ticks <= 60 then
        for __, t in ipairs(ticks) do
            local tx = x + math.floor(w * t)
            bb:paintRect(tx, y, math.max(1, px(1.5)), h, tx < x + fw and TRACK or WHITE)
        end
    end
end

-- Vertical bar chart; values above the bars, labels under them; returns the bars' rectangles
local function drawBars(bb, x, y, w, h, bars, opts)
    opts = opts or {}
    local n = #bars
    local gap = px(8)
    local bw = math.floor((w - gap * (n - 1)) / n)
    local label_h = px(28)
    local value_h = px(24)
    local chart_h = h - label_h - value_h
    local top = opts.goal or 0
    for __, b in ipairs(bars) do top = math.max(top, b.value) end
    if top <= 0 then top = 1 end
    local base = y + value_h + chart_h
    if opts.goal and opts.goal > 0 then
        local gy = base - math.floor(chart_h * opts.goal / top)
        local dash = px(6)
        for gx = x, x + w - dash, dash * 2 do bb:paintRect(gx, gy, dash, px(1.5), BLACK) end
        if opts.goal_text then
            drawText(bb, opts.goal_text, x, gy - px(20), 12, { w = w, align = "right", color = BLACK })
        end
    end
    local rects = {}
    for i, b in ipairs(bars) do
        local bx = x + (i - 1) * (bw + gap)
        local bh = math.floor(chart_h * b.value / top)
        bb:paintRect(bx, base - px(2), bw, px(2), TRACK)
        if bh > 0 then
            bb:paintRoundedRect(bx, base - bh, bw, bh, b.strong and BLACK or BAR, math.min(px(4), math.floor(bw / 2)))
        end
        if b.value_text and b.value > 0 then
            drawText(bb, b.value_text, bx - gap, base - bh - value_h, 13, { w = bw + 2 * gap, align = "center", color = MUTED, bg = WHITE })
        end
        drawText(bb, b.label, bx - gap, base + px(6), 14, { w = bw + 2 * gap, align = "center", bold = b.current, color = b.current and BLACK or MUTED })
        table.insert(rects, Geom:new { x = bx, y = y, w = bw, h = h })
    end
    return rects
end

-- Rounded button with centered text; returns its rectangle
local function drawButton(bb, label, x, y, w, h, filled)
    local r = math.floor(h / 2)
    bb:paintRoundedRect(x, y, w, h, filled and BLACK or WHITE, r)
    bb:paintBorder(x, y, w, h, px(1.5), BLACK, r)
    local probe = TextWidget:new { text = label, face = Font:getFace("tfont", 16), bold = true }
    local th = probe:getSize().h
    probe:free()
    drawText(bb, label, x, y + math.floor((h - th) / 2), 16, { w = w, align = "center", bold = true, color = filled and WHITE or BLACK })
    return Geom:new { x = x, y = y, w = w, h = h }
end

---------------------------------------------------------------- the screen

local StatsScreen = InputContainer:extend {
    ui = nil,
    tab = nil,
    year = nil,
    metric = "secs",
    covers_fullscreen = true,
}

-- Builds the screen, collects the data and sets up touch and keys
function StatsScreen:init()
    self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.tabs = {}
    self.book = bookData(self.ui)
    if self.book then table.insert(self.tabs, "Book") end
    table.insert(self.tabs, "Week")
    table.insert(self.tabs, "Year")
    self.tab = self.tab or self.tabs[1]
    self.year = tonumber(os.date("%Y"))
    self.days = allDays()
    self.hits = {}
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new { ges = "tap", range = self.dimen } },
            Swipe = { GestureRange:new { ges = "swipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextTab = { { Device.input.group.PgFwd } },
            PrevTab = { { Device.input.group.PgBack } },
        }
    end
end

-- The screen covers the whole display
function StatsScreen:getSize() return self.dimen end

-- Remembers an area that runs fn when tapped
function StatsScreen:addHit(rect, fn) table.insert(self.hits, { rect = rect, fn = fn }) end

-- Draws the tab bar and the current tab
function StatsScreen:paintTo(bb, x, y)
    self.hits = {}
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, WHITE)
    local m = px(20)
    local bar_h = px(40)
    local close_w = bar_h
    local tab_w = math.floor((w - 2 * m - close_w - px(12) - px(8) * (#self.tabs - 1)) / #self.tabs)
    for i, name in ipairs(self.tabs) do
        local rect = drawButton(bb, name, x + m + (i - 1) * (tab_w + px(8)), y + m, tab_w, bar_h, name == self.tab)
        self:addHit(rect, function() self:switchTo(name) end)
    end
    local cx, cy = x + w - m - close_w, y + m
    bb:paintBorder(cx, cy, close_w, bar_h, px(1.5), BLACK, math.floor(bar_h / 2))
    drawText(bb, "✕", cx, cy + px(6), 18, { w = close_w, align = "center", bold = true })
    self:addHit(Geom:new { x = cx, y = cy, w = close_w, h = bar_h }, function() self:onClose() end)
    local top = y + m + bar_h + px(24)
    local body = Geom:new { x = x + m, y = top, w = w - 2 * m, h = h - (top - y) - m }
    if self.tab == "Book" then self:paintBook(bb, body)
    elseif self.tab == "Week" then self:paintWeek(bb, body)
    else self:paintYear(bb, body) end
end

-- Book tab: progress, time, pace and finish estimate
function StatsScreen:paintBook(bb, r)
    local d = self.book
    local x, y, w = r.x, r.y, r.w
    y = y + drawBlock(bb, d.title, x, y, w, 24, { bold = true, lines = 2 })
    if d.author then y = y + drawBlock(bb, d.author, x, y, w, 16, { color = MUTED, lines = 1 }) end
    y = y + px(18)
    drawProgress(bb, x, y, w, px(14), d.percent, d.ticks)
    y = y + px(22)
    drawText(bb, string.format("%d%% read", math.floor(d.percent * 100)), x, y, 16, { bold = true })
    drawText(bb, T("page %1 of %2", d.page, d.total), x, y, 16, { w = w, align = "right", color = MUTED })
    y = y + px(40)

    local avg = d.avg and d.avg == d.avg and d.avg > 0 and d.avg or nil
    local left = math.max(0, d.total - d.page)
    y = y + drawSection(bb, "Time", x, y, w)
    y = y + drawRow(bb, x, y, w,
        { formatDuration(d.secs), "read so far" },
        { avg and formatDuration(left * avg) or "—", "left in this book" })
    y = y + drawRow(bb, x, y, w,
        { (avg and d.chapter_left) and formatDuration((d.chapter_left + 1) * avg) or "—", "left in this chapter" },
        { avg and tostring(math.floor(3600 / avg + 0.5)) or "—", "pages per hour" })

    y = y + px(12)
    y = y + drawSection(bb, "Pace", x, y, w)
    local pace = d.recent_pages / CONFIG.pace_days
    local pace_note = T("pages a day, last %1 days", CONFIG.pace_days)
    if pace <= 0 and d.first and d.pages_read > 0 then
        pace = d.pages_read / math.max(1, math.ceil((os.time() - d.first) / 86400))
        pace_note = "pages a day since you started"
    end
    local finish = "—"
    if pace > 0 and left > 0 then
        local days_left = math.ceil(left / pace)
        finish = days_left <= 1 and "Tomorrow" or os.date("%b %d", os.time() + days_left * 86400)
        if days_left > 365 then finish = "Over a year" end
    elseif left == 0 then
        finish = "Done!"
    end
    y = y + drawRow(bb, x, y, w,
        { finish, "estimated finish" },
        { pace > 0 and string.format(pace >= 10 and "%d" or "%.1f", pace) or "—", pace_note })
    local started = d.started
    if not started and d.first then started = os.date("%Y-%m-%d", d.first) end
    if started then
        local yy, mm, dd = started:match("(%d+)-(%d+)-(%d+)")
        started = yy and string.format("%s %d", MONTHS[tonumber(mm)], tonumber(dd)) or started
    end
    y = y + drawRow(bb, x, y, w,
        { tostring(d.days), d.days == 1 and "day reading it" or "days reading it" },
        { started or "—", "started" })

    y = y + px(12)
    y = y + drawSection(bb, "Book", x, y, w)
    drawRow(bb, x, y, w,
        { T("%1 of %2", d.chapters_done, d.chapters), "chapters finished" },
        { T("%1 · %2", d.highlights, d.notes), "highlights · notes" })
end

-- Week tab: today against the goal, the week in bars, comparison and streaks
function StatsScreen:paintWeek(bb, r)
    local x, y, w = r.x, r.y, r.w
    local goal, unit = dailyGoal()
    local now = os.time()
    local today_key = dayKey(now)
    local today = dayValue(self.days, today_key, unit)
    local today_secs = self.days[today_key] and self.days[today_key].secs or 0
    local short = unit == "minutes" and "min" or "pages"

    y = y + drawSection(bb, "Today", x, y, w)
    local _, vh = drawText(bb, T("%1 / %2 %3", today, goal, short), x, y, 30, { bold = true })
    local status = today >= goal and "Goal reached!" or T("%1 %2 to go", goal - today, short)
    drawText(bb, status, x, y + px(8), 17, { w = w, align = "right", bold = today >= goal })
    y = y + vh + px(8)
    drawProgress(bb, x, y, w, px(12), today / goal)
    y = y + px(20)
    drawText(bb, unit == "minutes" and T("%1 read today", plural(self.days[today_key] and self.days[today_key].pages or 0, "page"))
        or T("%1 read today", formatDuration(today_secs)), x, y, 15, { color = MUTED })
    y = y + px(40)

    y = y + drawSection(bb, "This week", x, y, w)
    local t = os.date("*t", now)
    local monday = noon(t.year, t.month, t.day) - ((t.wday + 5) % 7) * 86400
    local bars, week_secs, last_secs, met = {}, 0, 0, 0
    for i = 0, 6 do
        local day = monday + i * 86400
        local key = dayKey(day)
        local v = dayValue(self.days, key, unit)
        if day <= now + 43200 then
            week_secs = week_secs + (self.days[key] and self.days[key].secs or 0)
            if v >= goal then met = met + 1 end
        end
        local lkey = dayKey(day - 7 * 86400)
        last_secs = last_secs + (self.days[lkey] and self.days[lkey].secs or 0)
        table.insert(bars, { value = v, value_text = tostring(v), label = WEEKDAYS[i + 1],
            strong = v >= goal, current = key == today_key })
    end
    drawBars(bb, x, y, w, px(190), bars, { goal = goal, goal_text = T("goal %1", goal) })
    y = y + px(206)
    local diff = week_secs - last_secs
    local diff_text = (diff >= 0 and "+" or "−") .. formatDuration(math.abs(diff))
    y = y + drawRow(bb, x, y, w,
        { formatDuration(week_secs), "read this week" },
        { diff_text, "compared with last week" })
    local current, best = streaks(self.days, goal, unit)
    y = y + drawRow(bb, x, y, w,
        { plural(current, "day"), "current streak" },
        { plural(best, "day"), "best streak" })
    y = y + drawRow(bb, x, y, w, { T("%1 of 7", met), "days with the goal met" })
    local stats = self.ui and self.ui.statistics
    if stats and stats.onShowCalendarView then
        local bw = px(200)
        local rect = drawButton(bb, "Calendar", x, y, bw, px(40), false)
        self:addHit(rect, function() stats:onShowCalendarView() end)
    end
end

-- Month totals and finished books of the shown year, computed once per year
function StatsScreen:yearCache()
    if not self.year_cache or self.year_cache.year ~= self.year then
        local months, first_year = yearData(self.year)
        local finished, finished_count = finishedInYear(self.year)
        self.year_cache = { year = self.year, months = months, first = first_year,
            finished = finished, finished_count = finished_count }
    end
    return self.year_cache
end

-- Year tab: months in bars with a choice of measure, totals and books finished
function StatsScreen:paintYear(bb, r)
    local x, y, w = r.x, r.y, r.w
    local c = self:yearCache()
    local bh = px(40)
    local arrow_w = px(56)
    if self.year > c.first then
        local rect = drawButton(bb, "‹", x, y, arrow_w, bh, false)
        self:addHit(rect, function() self.year = self.year - 1 self:refresh() end)
    end
    drawText(bb, tostring(self.year), x, y + px(4), 24, { w = w, align = "center", bold = true })
    if self.year < tonumber(os.date("%Y")) then
        local rect = drawButton(bb, "›", x + w - arrow_w, y, arrow_w, bh, false)
        self:addHit(rect, function() self.year = self.year + 1 self:refresh() end)
    end
    y = y + bh + px(20)

    local secs, pages, days = 0, 0, 0
    for m = 1, 12 do
        secs, pages, days = secs + c.months[m].secs, pages + c.months[m].pages, days + c.months[m].days
    end
    y = y + drawRow(bb, x, y, w, { formatDuration(secs), "read this year" }, { tostring(c.finished_count), c.finished_count == 1 and "book finished" or "books finished" })
    y = y + drawRow(bb, x, y, w, { tostring(pages), "pages turned" }, { tostring(days), "days with reading" })

    y = y + px(4)
    y = y + drawSection(bb, "Month by month", x, y, w)
    local metrics = { { "Hours", "secs" }, { "Pages", "pages" }, { "Days", "days" } }
    local mw = math.floor((w - px(16)) / 3)
    for i, mt in ipairs(metrics) do
        local rect = drawButton(bb, mt[1], x + (i - 1) * (mw + px(8)), y, mw, px(36), self.metric == mt[2])
        self:addHit(rect, function() self.metric = mt[2] self:refresh() end)
    end
    y = y + px(52)
    local bars = {}
    local this_month = self.year == tonumber(os.date("%Y")) and tonumber(os.date("%m")) or nil
    for m = 1, 12 do
        local v = c.months[m][self.metric]
        local text
        if self.metric == "secs" then
            v = math.floor(v / 360) / 10
            text = v >= 10 and string.format("%d", v) or (v > 0 and string.format("%.1f", v) or "")
        else
            text = tostring(v)
        end
        local n_finished = c.finished[string.format("%02d", m)]
        table.insert(bars, { value = v, value_text = text, label = MONTHS[m]:sub(1, 1) .. (n_finished and "✓" or ""),
            strong = m == this_month, current = m == this_month })
    end
    local rects = drawBars(bb, x, y, w, px(210), bars)
    for m, rect in ipairs(rects) do
        self:addHit(rect, function() self:showMonth(m) end)
    end
    y = y + px(222)
    drawText(bb, "✓ month with a book finished · tap a month to see its books", x, y, 14, { color = MUTED, w = w })
end

-- Lists the books read in a month, with time spent and the ones finished
function StatsScreen:showMonth(m)
    local list = monthBooks(self.year, m)
    local finished = {}
    for __, title in ipairs(self:yearCache().finished[string.format("%02d", m)] or {}) do finished[title] = true end
    local kv = {}
    for __, b in ipairs(list) do
        table.insert(kv, { (finished[b.title] and "✓ " or "") .. b.title,
            formatDuration(b.secs) .. " · " .. plural(b.pages, "page") })
    end
    for title in pairs(finished) do
        local seen = false
        for __, b in ipairs(list) do if b.title == title then seen = true end end
        if not seen then table.insert(kv, { "✓ " .. title, "finished" }) end
    end
    if #kv == 0 then kv = { { "No reading this month", "" } } end
    local KeyValuePage = require("ui/widget/keyvaluepage")
    UIManager:show(KeyValuePage:new {
        title = T("%1 %2", MONTHS[m], self.year),
        kv_pairs = kv,
    })
end

-- Redraws the screen
function StatsScreen:refresh()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- Shows another tab
function StatsScreen:switchTo(name)
    if name == self.tab then return end
    self.tab = name
    UIManager:setDirty(self, function() return "partial", self.dimen end)
end

-- Moves to the next or previous tab
function StatsScreen:moveTab(step)
    for i, name in ipairs(self.tabs) do
        if name == self.tab then
            local j = i + step
            if j >= 1 and j <= #self.tabs then self:switchTo(self.tabs[j]) end
            return
        end
    end
end

-- Runs the action of the tapped area
function StatsScreen:onTap(_, ges)
    local p = ges.pos
    for __, hit in ipairs(self.hits) do
        local rc = hit.rect
        if p.x >= rc.x and p.x < rc.x + rc.w and p.y >= rc.y and p.y < rc.y + rc.h then
            hit.fn()
            return true
        end
    end
    return true
end

-- Swipe left/right changes the tab, swipe down closes
function StatsScreen:onSwipe(_, ges)
    if ges.direction == "west" then self:moveTab(1)
    elseif ges.direction == "east" then self:moveTab(-1)
    elseif ges.direction == "south" then self:onClose() end
    return true
end

function StatsScreen:onNextTab() self:moveTab(1) return true end
function StatsScreen:onPrevTab() self:moveTab(-1) return true end

-- Closes the screen
function StatsScreen:onClose()
    UIManager:close(self, "flashui")
    return true
end

-- Repaints what was under the screen
function StatsScreen:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

---------------------------------------------------------------- opening it

-- Opens the statistics screen from the reader or the file manager
local function showStats(ui)
    if not util.fileExists(DB_PATH) then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new { text = "Reading statistics has no data yet. Enable it in Tools → Reading statistics." })
        return true
    end
    UIManager:show(StatsScreen:new { ui = ui }, "full")
    return true
end

Dispatcher:registerAction("reading_stats", {
    category = "none",
    event = "ShowReadingStats",
    title = "Reading stats",
    general = true,
})

ReaderUI.onShowReadingStats = showStats
FileManager.onShowReadingStats = showStats

-- Adds Tools → Reading stats right after Reading statistics, in both menus
for __, m in ipairs({
    { "apps/filemanager/filemanagermenu", "ui/elements/filemanager_menu_order" },
    { "apps/reader/modules/readermenu", "ui/elements/reader_menu_order" },
}) do
    local Menu, order = require(m[1]), require(m[2])
    for __, list in pairs(order) do
        if type(list) == "table" and util.arrayContains(list, "statistics")
                and not util.arrayContains(list, "reading_stats") then
            for i, id in ipairs(list) do
                if id == "statistics" then table.insert(list, i + 1, "reading_stats") break end
            end
        end
    end
    local orig = Menu.setUpdateItemTable
    Menu.setUpdateItemTable = function(self, ...)
        self.menu_items.reading_stats = {
            text = "Reading stats",
            callback = function() showStats(self.ui) end,
        }
        return orig(self, ...)
    end
end
