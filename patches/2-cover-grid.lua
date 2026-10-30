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
    number) with its own badges, in one of three styles:
      classic  text badges, dog-ear for finished / on hold books
      medals   round trophy / pause medals, flame next to the percentage
      quest    XP bar along the bottom of the cover, trophy / pause medals
    Series number ("#2") and a collection star sit on the top left; page count
    shows on books not opened yet.
  - Marks books in progress that were not opened for a number of days: the
    percentage badge switches to an hourglass (the book status is not changed).
  - Optional: fades the covers of finished books.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. In Project: Title, choose the "Cover Grid" display mode.
  3. Pick the badge style and the idle days in
     Project: Title settings → Cover badges.
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
    fade_finished = false,     -- fade covers of finished books
    fade_amount = 0.5,         -- fade strength (0 to 1)
    -- Default badge look (can also be changed in the menu):
    --   "classic"  text badges and a dog-ear for finished / on hold books
    --   "medals"   round icon medals (trophy, pause), flame next to the percentage
    --   "quest"    XP bar along the bottom of the cover plus the status medals
    badge_style = "medals",
    -- Default number of days without opening a book in progress before its
    -- percentage badge shows an hourglass (0 = off; can also be changed in the menu)
    idle_days = 7,
    badge_font_size = 14,
    badges = {
        series = true,
        percent = true,
        pages = true,
        status = true,
        collection = true,
    },
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

-- Badge style chosen in the menu, or the CONFIG default
local function badgeStyle()
    return G_reader_settings:readSetting("cover_grid_badge_style", CONFIG.badge_style)
end

-- Idle days chosen in the menu, or the CONFIG default
local function idleDays()
    return G_reader_settings:readSetting("cover_grid_idle_days", CONFIG.idle_days)
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
    star = { "M8.243 7.34l-6.38 .925l-.113 .023a1 1 0 0 0 -.44 1.684l4.622 4.499l-1.09 6.355l-.013 .11a1 1 0 0 0 1.464 .944l5.706 -3l5.693 3l.1 .046a1 1 0 0 0 1.352 -1.1l-1.091 -6.355l4.624 -4.5l.078 -.085a1 1 0 0 0 -.633 -1.62l-6.38 -.926l-2.852 -5.78a1 1 0 0 0 -1.794 0l-2.853 5.78z" },
    hourglass = { "M17 2a2 2 0 0 1 1.995 1.85l.005 .15v2a6.996 6.996 0 0 1 -3.393 6a6.994 6.994 0 0 1 3.388 5.728l.005 .272v2a2 2 0 0 1 -1.85 1.995l-.15 .005h-10a2 2 0 0 1 -1.995 -1.85l-.005 -.15v-2a6.996 6.996 0 0 1 3.393 -6a6.994 6.994 0 0 1 -3.388 -5.728l-.005 -.272v-2a2 2 0 0 1 1.85 -1.995l.15 -.005h10z" },
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
    local font_size = CONFIG.badge_font_size
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

    if CONFIG.badges.series and bookinfo and bookinfo.series and bookinfo.series_index then
        local badge = makeBadge("#" .. bookinfo.series_index, Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE)
        badge:paintTo(bb, d.x + inset, next_left_y)
        next_left_y = next_left_y + badge:getSize().h + inset
        badge:free()
    end

    if CONFIG.badges.collection and item.menu.name ~= "collections"
            and ReadCollection:isFileInCollections(item.filepath) then
        drawCollectionStar(bb, d.x + inset, next_left_y)
    end

    local style = badgeStyle()
    local in_progress = opened and item.percent_finished and item.status ~= "complete"
    local medal_size = Screen:scaleBySize(30)
    local days = idleDays()
    local idle = in_progress and item.status ~= "abandoned" and days > 0 and item._cg_last_read
        and os.time() - item._cg_last_read > days * 86400

    if CONFIG.badges.percent and in_progress then
        local text = string.format("%d%%", math.floor(item.percent_finished * 100))
        local icon
        if idle then
            icon = "hourglass"
        elseif style == "medals" and item.status ~= "abandoned" then
            icon = "flame"
        end
        local dark = style ~= "quest" and not idle
        local fg = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local bg = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        local badge = makeBadge(text, fg, bg, icon)
        if style == "quest" then
            local fill_color = (item.status == "abandoned" or idle) and Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_BLACK
            local bar_y = drawXpBar(bb, d, item.percent_finished, fill_color)
            badge:paintTo(bb, d.x + d.w - badge:getSize().w - inset, bar_y - badge:getSize().h - Screen:scaleBySize(3))
        else
            badge:paintTo(bb, d.x + d.w - badge:getSize().w - inset, d.y + inset)
        end
        badge:free()
    end

    if CONFIG.badges.pages and not opened and item.status ~= "complete" and bookinfo and bookinfo.pages then
        local badge
        if style == "classic" then
            badge = makeBadge(bookinfo.pages .. " p.", Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_GRAY_3)
        else
            badge = makeBadge(tostring(bookinfo.pages), Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE, "book")
        end
        badge:paintTo(bb, d.x + inset, d.y + d.h - badge:getSize().h - inset)
        badge:free()
    end

    if CONFIG.badges.status and (item.status == "complete" or item.status == "abandoned") then
        if style == "classic" then
            drawDogear(bb, d, item.status == "complete" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)
        else
            if style == "quest" and item.status == "complete" then
                drawXpBar(bb, d, 1, Blitbuffer.COLOR_BLACK)
            end
            local medal_y = style == "quest" and d.y + inset or d.y + d.h - medal_size - inset
            local icon = item.status == "complete" and "trophy" or "pause"
            drawMedal(bb, d.x + d.w - medal_size - inset, medal_y, medal_size, icon, item.status == "complete")
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
        if CONFIG.fade_finished and self.status == "complete" then
            bb:lightenRect(d.x, d.y, d.w, d.h, CONFIG.fade_amount)
        end
        roundRect(bb, d)
        if self.bookinfo_found then
            drawBadges(self, bb, d)
        end
    end

    -- Adds the "Cover badges" submenu (style and idle days) to the Project: Title settings menu
    local orig_addToMainMenu = plugin.addToMainMenu
    plugin.addToMainMenu = function(pt, menu_items)
        orig_addToMainMenu(pt, menu_items)
        local pt_menu = menu_items.filemanager_display_mode
        if not pt_menu or not pt_menu.sub_item_table then return end
        local function refresh()
            local fc = pt.ui and pt.ui.file_chooser
            if fc then fc:updateItems(1, true) end
        end
        local styles = { { "Classic", "classic" }, { "Medals", "medals" }, { "Quest", "quest" } }
        local style_items = {}
        for _, s in ipairs(styles) do
            table.insert(style_items, {
                text = s[1],
                radio = true,
                checked_func = function() return badgeStyle() == s[2] end,
                callback = function()
                    G_reader_settings:saveSetting("cover_grid_badge_style", s[2])
                    refresh()
                end,
            })
        end
        style_items[#style_items].separator = true
        table.insert(style_items, {
            text_func = function()
                local days = idleDays()
                return days > 0 and T("Idle after: %1 days", days) or "Idle after: off"
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new {
                    title_text = "Idle after (days)",
                    info_text = "Books in progress not opened for this many days show an hourglass instead of the usual badge. 0 turns it off.",
                    value = idleDays(),
                    value_min = 0,
                    value_max = 365,
                    value_step = 1,
                    value_hold_step = 7,
                    default_value = CONFIG.idle_days,
                    ok_always_enabled = true,
                    callback = function(spin)
                        G_reader_settings:saveSetting("cover_grid_idle_days", spin.value)
                        touchmenu_instance:updateItems()
                        refresh()
                    end,
                })
            end,
        })
        table.insert(pt_menu.sub_item_table, 1, {
            text = "Cover badges",
            sub_item_table = style_items,
            separator = true,
        })
    end
end

userpatch.registerPatchPluginFunc("projecttitle", patchCoverGrid)
