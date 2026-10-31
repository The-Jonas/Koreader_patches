--[[
2-cover-grid.lua — Project: Title Cover Grid covers

Goal: a clean, uniform bookshelf where every cover has the same shape and reading
information shows up as small badges on top of the cover.

What it does:
  - Gives every cover the same aspect ratio (2:3 by default): books, folder
    thumbnails and the generated covers of books without an image. Covers that
    are too far from that ratio are centered on a gray background instead of
    being distorted.
  - Rounds the corners of covers and folder thumbnails.
  - Replaces the Project: Title indicators (progress bar, trophy, pause, series
    number) with its own badges, each one configurable from the menu:
      progress            percentage badge (with a flame), XP bar, both, or a ring
      finished / on hold  trophy or award medal, achievement stamp, bookmark
                          ribbon, FINISHED / ON HOLD banner, small check or dog-ear
      series, pages, collection star, icons and badge size
    Four presets (Classic, Medals, Quest, Rings) set several options at once.
  - Marks books in progress that were not opened for a number of days: the
    progress badge switches to an hourglass (the book status is not changed).
  - Optional: fades the covers of finished books.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. In Project: Title, choose the "Cover Grid" display mode.
  3. Adjust everything in Project: Title settings → Cover badges.
  4. Edit the CONFIG table below for aspect ratio, corners and default values.
  Since this patch redraws the covers, avoid combining it with other patches
  that also change Cover Grid covers.

Requires: Project: Title 3.8+.
Inspired by SeriousHornet's cover patches (github.com/SeriousHornet/KOReader.patches).
Icons from Tabler Icons (tabler.io/icons), MIT License, © Paweł Kuna.
]]

local CONFIG = {
    aspect_ratio = 2 / 3,      -- cover width / height
    max_distortion = 35,       -- max % of distortion accepted before centering instead of stretching
    corner_radius = 10,        -- corner radius (before DPI scaling)
    border_width = 1,          -- cover outline thickness
    hide_pt_overlays = true,   -- hide Project: Title progress bar and icons
    fade_amount = 0.5,         -- fade strength for finished covers (0 to 1)
    -- Defaults for the options in Project: Title settings → Cover badges
    defaults = {
        progress = "badge",    -- "badge", "bar", "bar_badge", "ring" or "none"
        status = "medal",      -- finished / on hold mark: "medal", "award", "stamp", "ribbon",
                               -- "banner", "check", "dogear" or "none"
        icons = true,          -- icons inside badges (flame, hourglass, book)
        size = "medium",       -- badge size: "small", "medium" or "large"
        series = true,         -- series number on the top left
        pages = true,          -- page count on books not opened yet
        collection = true,     -- star on books that are in a collection
        fade_finished = false, -- fade covers of finished books
        idle_days = 7,         -- days without opening before the hourglass shows (0 = off)
    },
}

-- Presets offered in the menu; each one only sets the options it lists
local PRESETS = {
    { "Classic", { progress = "badge", status = "dogear", icons = false } },
    { "Medals",  { progress = "badge", status = "medal", icons = true } },
    { "Quest",   { progress = "bar_badge", status = "medal", icons = true } },
    { "Rings",   { progress = "ring", status = "medal", icons = true } },
}

local SIZES = {
    small  = { font = 12, medal = 26, ring = 34 },
    medium = { font = 14, medal = 30, ring = 42 },
    large  = { font = 17, medal = 36, ring = 50 },
}

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ReadCollection = require("readcollection")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local userpatch = require("userpatch")
local util = require("util")
local T = require("ffi/util").template

-- Value of an option chosen in the menu, or its default from CONFIG
local function opt(key)
    local saved = G_reader_settings:readSetting("cover_grid") or {}
    if saved[key] == nil then return CONFIG.defaults[key] end
    return saved[key]
end

-- Saves an option chosen in the menu
local function setOpt(key, value)
    local saved = G_reader_settings:readSetting("cover_grid") or {}
    saved[key] = value
    G_reader_settings:saveSetting("cover_grid", saved)
end

-- Size table (font, medal, ring) for the chosen badge size
local function sizes()
    return SIZES[opt("size")] or SIZES.medium
end

-- Time the book was last closed, taken from its metadata file (nil if never opened)
local function lastReadTime(filepath)
    local sidecar = DocSettings:findSidecarFile(filepath)
    return sidecar and lfs.attributes(sidecar, "modification")
end

-- Largest box with the configured aspect ratio that fits in max_w × max_h
local function fitBox(max_w, max_h)
    local ratio = CONFIG.aspect_ratio
    if max_w / max_h > ratio then
        return math.floor(max_h * ratio), math.floor(max_h)
    end
    return math.floor(max_w), math.floor(max_w / ratio)
end

-- Fixed-size w × h cover widget: stretches the image or, past the distortion limit, centers it on gray
local function buildCoverBox(cover_bb, w, h)
    local iw, ih = cover_bb:getWidth(), cover_bb:getHeight()
    local distortion = math.abs((iw / ih) / (w / h) - 1) * 100
    if distortion <= CONFIG.max_distortion then
        return FrameContainer:new {
            width = w, height = h, margin = 0, padding = 0, bordersize = 0,
            ImageWidget:new { image = cover_bb, width = w, height = h },
        }
    end
    return FrameContainer:new {
        width = w, height = h, margin = 0, padding = 0, bordersize = 0,
        background = Blitbuffer.COLOR_GRAY_E,
        CenterContainer:new {
            dimen = Geom:new { w = w, h = h },
            ImageWidget:new { image = cover_bb, width = w, height = h, scale_factor = 0 },
        },
    }
end

-- Clears the corners of an already painted rectangle and draws a rounded outline
local function roundRect(bb, d)
    local r = math.min(Screen:scaleBySize(CONFIG.corner_radius), math.floor(math.min(d.w, d.h) / 2))
    local bg = Blitbuffer.COLOR_WHITE
    for i = 0, r - 1 do
        local dy = r - i - 0.5
        local cut = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        if cut > 0 then
            bb:paintRect(d.x, d.y + i, cut, 1, bg)
            bb:paintRect(d.x + d.w - cut, d.y + i, cut, 1, bg)
            bb:paintRect(d.x, d.y + d.h - 1 - i, cut, 1, bg)
            bb:paintRect(d.x + d.w - cut, d.y + d.h - 1 - i, cut, 1, bg)
        end
    end
    if CONFIG.border_width > 0 then
        bb:paintBorder(d.x, d.y, d.w, d.h, CONFIG.border_width, Blitbuffer.COLOR_DARK_GRAY, r)
    end
end

-- Icon shapes from Tabler Icons (https://tabler.io/icons), MIT License, © Paweł Kuna
local ICONS = {
    trophy = { "M17 3a1 1 0 0 1 .993 .883l.007 .117v2.17a3 3 0 1 1 0 5.659v.171a6.002 6.002 0 0 1 -5 5.917v2.083h3a1 1 0 0 1 .117 1.993l-.117 .007h-8a1 1 0 0 1 -.117 -1.993l.117 -.007h3v-2.083a6.002 6.002 0 0 1 -4.996 -5.692l-.004 -.225v-.171a3 3 0 0 1 -3.996 -2.653l-.003 -.176l.005 -.176a3 3 0 0 1 3.995 -2.654l-.001 -2.17a1 1 0 0 1 1 -1h10zm-12 5a1 1 0 1 0 0 2a1 1 0 0 0 0 -2m14 0a1 1 0 1 0 0 2a1 1 0 0 0 0 -2" },
    pause = {
        "M9 4h-2a2 2 0 0 0 -2 2v12a2 2 0 0 0 2 2h2a2 2 0 0 0 2 -2v-12a2 2 0 0 0 -2 -2z",
        "M17 4h-2a2 2 0 0 0 -2 2v12a2 2 0 0 0 2 2h2a2 2 0 0 0 2 -2v-12a2 2 0 0 0 -2 -2z",
    },
    book = { "M21.5 5.134a1 1 0 0 1 .493 .748l.007 .118v13a1 1 0 0 1 -1.5 .866a8 8 0 0 0 -7.5 -.266v-15.174a10 10 0 0 1 8.5 .708m-10.5 -.707l.001 15.174a8 8 0 0 0 -7.234 .117l-.327 .18l-.103 .044l-.049 .016l-.11 .026l-.061 .01l-.117 .006h-.042l-.11 -.012l-.077 -.014l-.108 -.032l-.126 -.056l-.095 -.056l-.089 -.067l-.06 -.056l-.073 -.082l-.064 -.089l-.022 -.036l-.032 -.06l-.044 -.103l-.016 -.049l-.026 -.11l-.01 -.061l-.004 -.049l-.002 -13.068a1 1 0 0 1 .5 -.866a10 10 0 0 1 8.5 -.707" },
    hourglass = { "M17 2a2 2 0 0 1 1.995 1.85l.005 .15v2a6.996 6.996 0 0 1 -3.393 6a6.994 6.994 0 0 1 3.388 5.728l.005 .272v2a2 2 0 0 1 -1.85 1.995l-.15 .005h-10a2 2 0 0 1 -1.995 -1.85l-.005 -.15v-2a6.996 6.996 0 0 1 3.393 -6a6.994 6.994 0 0 1 -3.388 -5.728l-.005 -.272v-2a2 2 0 0 1 1.85 -1.995l.15 -.005h10z" },
    award = {
        "M19.496 13.983l1.966 3.406a1.001 1.001 0 0 1 -.705 1.488l-.113 .011l-.112 -.001l-2.933 -.19l-1.303 2.636a1.001 1.001 0 0 1 -1.608 .26l-.082 -.094l-.072 -.11l-1.968 -3.407a8.994 8.994 0 0 0 6.93 -3.999z",
        "M11.43 17.982l-1.966 3.408a1.001 1.001 0 0 1 -1.622 .157l-.076 -.1l-.064 -.114l-1.304 -2.635l-2.931 .19a1.001 1.001 0 0 1 -1.022 -1.29l.04 -.107l.05 -.1l1.968 -3.409a8.994 8.994 0 0 0 6.927 4.001z",
        "M12 2l.24 .004a7 7 0 0 1 6.76 6.996l-.003 .193l-.007 .192l-.018 .245l-.026 .242l-.024 .178a6.985 6.985 0 0 1 -.317 1.268l-.116 .308l-.153 .348a7.001 7.001 0 0 1 -12.688 -.028l-.13 -.297l-.052 -.133l-.08 -.217l-.095 -.294a6.96 6.96 0 0 1 -.093 -.344l-.06 -.271l-.049 -.271l-.02 -.139l-.039 -.323l-.024 -.365l-.006 -.292a7 7 0 0 1 6.76 -6.996l.24 -.004z",
    },
    check = { "M20.707 6.293a1 1 0 0 1 0 1.414l-10 10a1 1 0 0 1 -1.414 0l-5 -5a1 1 0 0 1 1.414 -1.414l4.293 4.293l9.293 -9.293a1 1 0 0 1 1.414 0" },
    rosette = { "M12.01 2.011a3.2 3.2 0 0 1 2.113 .797l.154 .145l.698 .698a1.2 1.2 0 0 0 .71 .341l.135 .008h1a3.2 3.2 0 0 1 3.195 3.018l.005 .182v1c0 .27 .092 .533 .258 .743l.09 .1l.697 .698a3.2 3.2 0 0 1 .147 4.382l-.145 .154l-.698 .698a1.2 1.2 0 0 0 -.341 .71l-.008 .135v1a3.2 3.2 0 0 1 -3.018 3.195l-.182 .005h-1a1.2 1.2 0 0 0 -.743 .258l-.1 .09l-.698 .697a3.2 3.2 0 0 1 -4.382 .147l-.154 -.145l-.698 -.698a1.2 1.2 0 0 0 -.71 -.341l-.135 -.008h-1a3.2 3.2 0 0 1 -3.195 -3.018l-.005 -.182v-1a1.2 1.2 0 0 0 -.258 -.743l-.09 -.1l-.697 -.698a3.2 3.2 0 0 1 -.147 -4.382l.145 -.154l.698 -.698a1.2 1.2 0 0 0 .341 -.71l.008 -.135v-1l.005 -.182a3.2 3.2 0 0 1 3.013 -3.013l.182 -.005h1a1.2 1.2 0 0 0 .743 -.258l.1 -.09l.698 -.697a3.2 3.2 0 0 1 2.269 -.944z" },
    bookmark = { "M14 2a5 5 0 0 1 5 5v14a1 1 0 0 1 -1.555 .832l-5.445 -3.63l-5.444 3.63a1 1 0 0 1 -1.55 -.72l-.006 -.112v-14a5 5 0 0 1 5 -5h4z" },
    flame = { "M10 2c0 -.88 1.056 -1.331 1.692 -.722c1.958 1.876 3.096 5.995 1.75 9.12l-.08 .174l.012 .003c.625 .133 1.203 -.43 2.303 -2.173l.14 -.224a1 1 0 0 1 1.582 -.153c1.334 1.435 2.601 4.377 2.601 6.27c0 4.265 -3.591 7.705 -8 7.705s-8 -3.44 -8 -7.706c0 -2.252 1.022 -4.716 2.632 -6.301l.605 -.589c.241 -.236 .434 -.43 .618 -.624c1.43 -1.512 2.145 -2.924 2.145 -4.78" },
}

-- Writes an icon as an SVG file in the given color (once) and returns its path
local icon_dir = DataStorage:getDataDir() .. "/cache/cover-grid-icons"
local function iconFile(name, color)
    local path = string.format("%s/%s-%s.svg", icon_dir, name, color:sub(2))
    if not util.fileExists(path) then
        util.makePath(icon_dir)
        local paths = {}
        for _, d in ipairs(ICONS[name]) do
            table.insert(paths, string.format('<path fill="%s" d="%s"/>', color, d))
        end
        local f = io.open(path, "w")
        if not f then return nil end
        f:write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">', table.concat(paths), "</svg>")
        f:close()
    end
    return path
end

-- Builds an image widget for an icon at the given size and color
local function makeIcon(name, color, size)
    local file = iconFile(name, color)
    if not file then return nil end
    return ImageWidget:new { file = file, width = size, height = size, alpha = true }
end

-- Builds a rounded badge with text and an optional leading icon
local function makeBadge(text, fg, bg, icon)
    local font_size = sizes().font
    local label = TextWidget:new {
        text = text,
        face = Font:getFace("cfont", font_size),
        bold = true,
        fgcolor = fg,
    }
    local content = label
    if icon then
        local fg_hex = fg == Blitbuffer.COLOR_WHITE and "#FFFFFF" or "#000000"
        local image = makeIcon(icon, fg_hex, label:getSize().h - Screen:scaleBySize(4))
        if image then
            content = HorizontalGroup:new { align = "center", image, HorizontalSpan:new { width = Screen:scaleBySize(3) }, label }
        end
    end
    return FrameContainer:new {
        radius = Screen:scaleBySize(8),
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_BLACK,
        background = bg,
        margin = 0,
        padding = Screen:scaleBySize(2),
        padding_left = Screen:scaleBySize(6),
        padding_right = Screen:scaleBySize(6),
        content,
    }
end

-- Draws a round medal with an icon; dark = black medal with white icon, otherwise white with black outline
local function drawMedal(bb, x, y, size, icon, dark)
    local r = math.floor(size / 2)
    local cx, cy = x + r, y + r
    if dark then
        bb:paintCircle(cx, cy, r + Screen:scaleBySize(2), Blitbuffer.COLOR_WHITE)
        bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK)
    else
        bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_WHITE)
        bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK, Screen:scaleBySize(2))
    end
    local icon_size = math.floor(size * 0.55)
    local image = makeIcon(icon, dark and "#FFFFFF" or "#000000", icon_size)
    if image then
        image:paintTo(bb, cx - math.floor(icon_size / 2), cy - math.floor(icon_size / 2))
        image:free()
    end
end

-- Paints an icon shape at (x, y), optionally over a slightly larger copy in another color as an outline
local function paintShape(bb, name, x, y, size, fill_hex, outline_hex, outline)
    if outline and outline > 0 then
        local o = makeIcon(name, outline_hex, size + 2 * outline)
        if o then o:paintTo(bb, x - outline, y - outline); o:free() end
    end
    local f = makeIcon(name, fill_hex, size)
    if f then f:paintTo(bb, x, y); f:free() end
end

-- Draws an achievement seal (rosette) with a check or pause in the middle
local function drawStamp(bb, x, y, size, done)
    local halo = Screen:scaleBySize(2)
    paintShape(bb, "rosette", x, y, size, done and "#000000" or "#FFFFFF", done and "#FFFFFF" or "#000000", halo)
    local inner = math.floor(size * 0.45)
    paintShape(bb, done and "check" or "pause", x + math.floor((size - inner) / 2), y + math.floor((size - inner) / 2),
        inner, done and "#FFFFFF" or "#000000")
end

-- Draws a bookmark ribbon hanging from the top edge, with its right side at right_x
local function drawRibbon(bb, d, right_x, size, done)
    local x = right_x - math.floor(size * 19 / 24)
    local y = d.y - math.floor(size * 2 / 24)
    local halo = Screen:scaleBySize(2)
    paintShape(bb, "bookmark", x, y, size, done and "#000000" or "#FFFFFF", done and "#FFFFFF" or "#000000", halo)
    local inner = math.floor(size * 0.36)
    paintShape(bb, done and "check" or "pause", x + math.floor((size - inner) / 2), y + math.floor(size * 0.24),
        inner, done and "#FFFFFF" or "#000000")
end

-- Draws the XP bar along the bottom of the cover; fill goes from 0 to 1
local function drawXpBar(bb, d, fill, fill_color)
    local inset = Screen:scaleBySize(6)
    local h = Screen:scaleBySize(10)
    local x, y, w = d.x + inset, d.y + d.h - h - inset, d.w - 2 * inset
    local r = math.floor(h / 2)
    local halo = Screen:scaleBySize(2)
    bb:paintRoundedRect(x - halo, y - halo, w + 2 * halo, h + 2 * halo, Blitbuffer.COLOR_WHITE, r + halo)
    bb:paintRoundedRect(x, y, w, h, Blitbuffer.COLOR_WHITE, r)
    local fw = math.floor(w * math.max(0, math.min(1, fill)))
    if fw > 0 then
        bb:paintRoundedRect(x, y, math.max(fw, h), h, fill_color, r)
    end
    bb:paintBorder(x, y, w, h, Size.border.thin, Blitbuffer.COLOR_BLACK, r)
    return y
end

-- Draws a progress ring with the percentage inside; fill goes from 0 to 1, clockwise from the top
local function drawRing(bb, x, y, size, fill, text, fill_color)
    local r = math.floor(size / 2)
    local cx, cy = x + r, y + r
    local thickness = math.max(3, math.floor(size / 7))
    bb:paintCircle(cx, cy, r + Screen:scaleBySize(2), Blitbuffer.COLOR_WHITE)
    bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_GRAY_D, thickness)
    local mid = r - thickness / 2
    local dot = math.ceil(thickness / 2)
    local steps = math.max(1, math.floor(2 * math.pi * mid * math.max(0, math.min(1, fill))))
    for i = 0, steps do
        local a = -math.pi / 2 + (i / (2 * math.pi * mid)) * 2 * math.pi
        local px, py = cx + math.cos(a) * mid, cy + math.sin(a) * mid
        bb:paintCircle(math.floor(px + 0.5), math.floor(py + 0.5), dot, fill_color)
    end
    local label = TextWidget:new {
        text = text,
        face = Font:getFace("cfont", math.max(9, math.floor(sizes().font * 0.8))),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local ls = label:getSize()
    label:paintTo(bb, cx - math.floor(ls.w / 2), cy - math.floor(ls.h / 2))
    label:free()
end

-- Draws a dog-ear with a black outline on the bottom right corner of the cover
local function drawDogear(bb, d, color)
    local s = math.floor(math.min(d.w, d.h) / 7)
    local x0, y0 = d.x + d.w - s, d.y + d.h - s
    for i = 0, s - 1 do
        bb:paintRect(x0 + s - i - 1, y0 + i, i + 1, 1, Blitbuffer.COLOR_WHITE)
        bb:paintRect(x0, y0 + i, s - i - 1, 1, color)
        bb:paintRect(x0 + s - i - 1, y0 + i, 1, 1, Blitbuffer.COLOR_BLACK)
    end
    local line = Screen:scaleBySize(1)
    bb:paintRect(x0, y0, s, line, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x0, y0, line, s, Blitbuffer.COLOR_BLACK)
end

-- Draws the collection star inside a black circle
local function drawCollectionStar(bb, x, y)
    local r = Screen:scaleBySize(11)
    bb:paintCircle(x + r, y + r, r, Blitbuffer.COLOR_BLACK)
    local size = Screen:scaleBySize(16)
    local star = IconWidget:new { icon = "star.white", width = size, height = size, alpha = true }
    star:paintTo(bb, x + r - math.floor(size / 2), y + r - math.floor(size / 2))
    star:free()
    return 2 * r
end

-- Draws every enabled badge over the cover d of a book item
local function drawBadges(item, bb, d)
    local inset = Screen:scaleBySize(6)
    local bookinfo = require("bookinfomanager"):getBookInfo(item.filepath, false)
    local opened = item.been_opened or item.menu.name == "history" or item.menu.name == "collections"
    local next_left_y = d.y + inset

    if opt("series") and bookinfo and bookinfo.series and bookinfo.series_index then
        local badge = makeBadge("#" .. bookinfo.series_index, Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE)
        badge:paintTo(bb, d.x + inset, next_left_y)
        next_left_y = next_left_y + badge:getSize().h + inset
        badge:free()
    end

    if opt("collection") and item.menu.name ~= "collections"
            and ReadCollection:isFileInCollections(item.filepath) then
        drawCollectionStar(bb, d.x + inset, next_left_y)
    end

    local progress, status, icons = opt("progress"), opt("status"), opt("icons")
    local sz = sizes()
    local medal_size = Screen:scaleBySize(sz.medal)
    local in_progress = opened and item.percent_finished and item.status ~= "complete"
    local on_hold = item.status == "abandoned"
    local days = opt("idle_days")
    local idle = in_progress and not on_hold and days > 0 and item._cg_last_read
        and os.time() - item._cg_last_read > days * 86400
    local has_bar = progress == "bar" or progress == "bar_badge"
    local top_right_used = false
    local top_right_left = d.x + d.w - inset
    local bottom_y = d.y + d.h - inset

    if in_progress and progress ~= "none" then
        local text = string.format("%d%%", math.floor(item.percent_finished * 100))
        local dim = on_hold or idle
        if has_bar then
            local bar_y = drawXpBar(bb, d, item.percent_finished, dim and Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_BLACK)
            bottom_y = bar_y - Screen:scaleBySize(3)
            if progress == "bar_badge" then
                local badge = makeBadge(text, Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE, icons and idle and "hourglass" or nil)
                badge:paintTo(bb, d.x + d.w - badge:getSize().w - inset, bar_y - badge:getSize().h - Screen:scaleBySize(3))
                bottom_y = bar_y - badge:getSize().h - 2 * Screen:scaleBySize(3)
                badge:free()
            end
        elseif progress == "ring" then
            local ring = Screen:scaleBySize(sz.ring)
            drawRing(bb, d.x + d.w - ring - inset, d.y + inset, ring, item.percent_finished, text,
                dim and Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_BLACK)
            top_right_used = true
            top_right_left = d.x + d.w - ring - inset
        else
            local icon
            if icons and idle then
                icon = "hourglass"
            elseif icons and not on_hold then
                icon = "flame"
            end
            local fg = idle and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            local bg = idle and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            local badge = makeBadge(text, fg, bg, icon)
            badge:paintTo(bb, d.x + d.w - badge:getSize().w - inset, d.y + inset)
            top_right_left = d.x + d.w - badge:getSize().w - inset
            badge:free()
            top_right_used = true
        end
    end

    if opt("pages") and not opened and item.status ~= "complete" and bookinfo and bookinfo.pages then
        local badge
        if icons then
            badge = makeBadge(tostring(bookinfo.pages), Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE, "book")
        else
            badge = makeBadge(bookinfo.pages .. " p.", Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_GRAY_3)
        end
        badge:paintTo(bb, d.x + inset, d.y + d.h - badge:getSize().h - inset)
        badge:free()
    end

    if status ~= "none" and (item.status == "complete" or on_hold) then
        local done = item.status == "complete"
        if has_bar and done then
            bottom_y = drawXpBar(bb, d, 1, Blitbuffer.COLOR_BLACK) - Screen:scaleBySize(3)
        end
        if status == "dogear" then
            drawDogear(bb, d, done and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)
        elseif status == "banner" then
            local badge = done and makeBadge("FINISHED", Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK, icons and "check" or nil)
                or makeBadge("ON HOLD", Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE, icons and "pause" or nil)
            local bs = badge:getSize()
            badge:paintTo(bb, d.x + math.floor((d.w - bs.w) / 2), bottom_y - bs.h)
            badge:free()
        elseif status == "ribbon" then
            local size = math.floor(medal_size * 1.4)
            local right_x = top_right_used and top_right_left - inset or d.x + d.w - inset
            drawRibbon(bb, d, right_x, size, done)
        else
            local size = status == "check" and math.floor(medal_size * 0.75)
                or status == "stamp" and math.floor(medal_size * 1.2) or medal_size
            local at_top = has_bar or not top_right_used
            local x = d.x + d.w - size - inset
            local y = at_top and d.y + inset or bottom_y - size
            if status == "stamp" then
                drawStamp(bb, x, y, size, done)
            else
                local icon = done and (status == "award" and "award" or status == "check" and "check" or "trophy") or "pause"
                drawMedal(bb, x, y, size, icon, done)
            end
        end
    end
end

-- Applies every change to MosaicMenuItem and to the Project: Title folder thumbnail functions
local function patchCoverGrid(plugin)
    local MosaicMenu = require("mosaicmenu")
    local ptutil = require("ptutil")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem then
        logger.warn("cover-grid: MosaicMenuItem not found")
        return
    end
    -- KOReader runs plugin patches on every plugin instantiation: apply only once
    if MosaicMenuItem._cover_grid_patched then return end
    MosaicMenuItem._cover_grid_patched = true
    local FakeCover = userpatch.getUpValue(MosaicMenuItem.update, "FakeCover")

    -- Item whose update() is running; collects the thumbnails built for its folder
    local building_item

    -- Folder thumbnails with a uniform size
    ptutil.build_cover_images = function(db_res, max_w, max_h)
        local covers = {}
        if not db_res then return covers end
        local BookInfoManager = require("bookinfomanager")
        local w, h = fitBox(ptutil.get_thumbnail_size(max_w, max_h))
        local dirs, names = db_res[1], db_res[2]
        for i, name in ipairs(names) do
            local path = dirs[i] .. name
            if util.fileExists(path) then
                local bookinfo = BookInfoManager:getBookInfo(path, true)
                if bookinfo and bookinfo.cover_bb then
                    local box = buildCoverBox(bookinfo.cover_bb, w, h)
                    table.insert(covers, box)
                    if building_item then table.insert(building_item._cg_thumbs, box) end
                end
                if #covers == 4 then break end
            end
        end
        return covers
    end

    -- Empty slots of the folder grid also get rounded corners
    local orig_create_blank_cover = ptutil.create_blank_cover
    ptutil.create_blank_cover = function(...)
        local blank = orig_create_blank_cover(...)
        blank.radius = nil
        blank.bordersize = 0
        if building_item then table.insert(building_item._cg_thumbs, blank) end
        return blank
    end

    -- Generated cover (book without image) with the same aspect ratio as the others
    if FakeCover then
        local orig_fake_init = FakeCover.init
        FakeCover.init = function(self)
            if rawget(self, "bottom_right_compensate") ~= nil and self.width and self.height then
                self.width, self.height = fitBox(self.width / 0.8, self.height)
            end
            orig_fake_init(self)
        end
    end

    -- Rebuilds the book cover with a uniform size and keeps the references used by paintTo
    local orig_update = MosaicMenuItem.update
    MosaicMenuItem.update = function(self, ...)
        self._cg_thumbs = {}
        self._cg_cover = nil
        building_item = self
        orig_update(self, ...)
        building_item = nil
        if ptutil.isPathChooser(self) or self.is_directory then return end
        self._cg_last_read = lastReadTime(self.filepath)

        local center = self._underline_container[1]
        local inner = center and center[1]
        if not inner then return end
        local old_image = inner[1]
        if self._has_cover_image and old_image and old_image.image then
            local border = Size.border.thin
            local w, h = fitBox(self.width - 2 * border, self.height - 2 * border)
            local box = buildCoverBox(old_image.image, w, h)
            box.dim = self.file_deleted
            center[1] = box
            self._cg_cover = box
        else
            self._cg_cover = inner
        end
    end

    -- Paints the cover, rounds its corners and draws the badges
    local orig_paintTo = MosaicMenuItem.paintTo
    MosaicMenuItem.paintTo = function(self, bb, x, y)
        if CONFIG.hide_pt_overlays then
            InputContainer.paintTo(self, bb, x, y)
        else
            orig_paintTo(self, bb, x, y)
        end

        for _, thumb in ipairs(self._cg_thumbs or {}) do
            if thumb.dimen then roundRect(bb, thumb.dimen) end
        end

        local cover = self._cg_cover
        if self.is_directory or not cover or not cover.dimen then return end
        local d = cover.dimen
        if opt("fade_finished") and self.status == "complete" then
            bb:lightenRect(d.x, d.y, d.w, d.h, CONFIG.fade_amount)
        end
        roundRect(bb, d)
        if self.bookinfo_found then
            drawBadges(self, bb, d)
        end
    end

    -- Adds the "Cover badges" submenu to the Project: Title settings menu
    local orig_addToMainMenu = plugin.addToMainMenu
    plugin.addToMainMenu = function(pt, menu_items)
        orig_addToMainMenu(pt, menu_items)
        local pt_menu = menu_items.filemanager_display_mode
        if not pt_menu or not pt_menu.sub_item_table then return end

        -- Redraws the file browser after an option changes
        local function refresh()
            local fc = pt.ui and pt.ui.file_chooser
            if fc then fc:updateItems(1, true) end
        end

        -- Builds a submenu of radio items for one option
        local function choiceMenu(title, key, choices)
            local items = {}
            for _, c in ipairs(choices) do
                table.insert(items, {
                    text = c[1],
                    radio = true,
                    checked_func = function() return opt(key) == c[2] end,
                    callback = function() setOpt(key, c[2]); refresh() end,
                })
            end
            return {
                text_func = function()
                    for _, c in ipairs(choices) do
                        if opt(key) == c[2] then return T("%1: %2", title, c[1]) end
                    end
                    return title
                end,
                sub_item_table = items,
            }
        end

        -- Builds a checkbox item for one option
        local function toggle(title, key)
            return {
                text = title,
                checked_func = function() return opt(key) end,
                callback = function() setOpt(key, not opt(key)); refresh() end,
            }
        end

        local preset_items = {}
        for _, p in ipairs(PRESETS) do
            table.insert(preset_items, {
                text = p[1],
                callback = function(touchmenu_instance)
                    for k, v in pairs(p[2]) do setOpt(k, v) end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    refresh()
                end,
            })
        end

        local items = {
            { text = "Apply a preset", sub_item_table = preset_items, separator = true },
            choiceMenu("Progress", "progress", {
                { "badge", "badge" }, { "XP bar", "bar" }, { "XP bar and badge", "bar_badge" },
                { "ring", "ring" }, { "hidden", "none" },
            }),
            choiceMenu("Finished / on hold", "status", {
                { "medal", "medal" }, { "award", "award" }, { "stamp", "stamp" }, { "ribbon", "ribbon" },
                { "banner", "banner" }, { "check", "check" }, { "dog-ear", "dogear" }, { "hidden", "none" },
            }),
            choiceMenu("Badge size", "size", {
                { "small", "small" }, { "medium", "medium" }, { "large", "large" },
            }),
            toggle("Icons inside badges", "icons"),
            toggle("Series number", "series"),
            toggle("Page count on new books", "pages"),
            toggle("Collection star", "collection"),
            toggle("Fade finished covers", "fade_finished"),
            {
                text_func = function()
                    local days = opt("idle_days")
                    return days > 0 and T("Idle after: %1 days", days) or "Idle after: off"
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UIManager:show(SpinWidget:new {
                        title_text = "Idle after (days)",
                        info_text = "Books in progress not opened for this many days show an hourglass. 0 turns it off.",
                        value = opt("idle_days"),
                        value_min = 0,
                        value_max = 365,
                        value_step = 1,
                        value_hold_step = 7,
                        default_value = CONFIG.defaults.idle_days,
                        ok_always_enabled = true,
                        callback = function(spin)
                            setOpt("idle_days", spin.value)
                            touchmenu_instance:updateItems()
                            refresh()
                        end,
                    })
                end,
            },
        }
        items[4].separator = true
        items[9].separator = true
        table.insert(pt_menu.sub_item_table, 1, {
            text = "Cover badges",
            sub_item_table = items,
            separator = true,
        })
    end
end

userpatch.registerPatchPluginFunc("projecttitle", patchCoverGrid)
