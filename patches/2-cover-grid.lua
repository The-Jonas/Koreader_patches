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
    number) with its own badges:
      top left      series number ("#2")
      top right     percentage read (books in progress)
      bottom left   page count (books not opened yet)
      bottom right  dog-ear (finished / abandoned)
      below series  star, if the book is in a collection
  - Optional: fades the covers of finished books.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. In Project: Title, choose the "Cover Grid" display mode.
  3. Edit the CONFIG table below to change aspect ratio, corners and badges.
  Since this patch redraws the covers, avoid combining it with other patches
  that also change Cover Grid covers.

Requires: Project: Title 3.8+.
Inspired by SeriousHornet's cover patches (github.com/SeriousHornet/KOReader.patches).
]]

local CONFIG = {
    aspect_ratio = 2 / 3,      -- cover width / height
    max_distortion = 35,       -- max % of distortion accepted before centering instead of stretching
    corner_radius = 10,        -- corner radius (before DPI scaling)
    border_width = 1,          -- cover outline thickness
    hide_pt_overlays = true,   -- hide Project: Title progress bar and icons
    fade_finished = false,     -- fade covers of finished books
    fade_amount = 0.5,         -- fade strength (0 to 1)
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
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ReadCollection = require("readcollection")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Screen = require("device").screen
local logger = require("logger")
local userpatch = require("userpatch")
local util = require("util")

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

-- Builds a rounded text badge
local function makeBadge(text, fg, bg)
    return FrameContainer:new {
        radius = Screen:scaleBySize(8),
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_BLACK,
        background = bg,
        margin = 0,
        padding = Screen:scaleBySize(2),
        padding_left = Screen:scaleBySize(6),
        padding_right = Screen:scaleBySize(6),
        TextWidget:new {
            text = text,
            face = Font:getFace("cfont", CONFIG.badge_font_size),
            bold = true,
            fgcolor = fg,
        },
    }
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

    if CONFIG.badges.percent and opened and item.percent_finished and item.status ~= "complete" then
        local text = string.format("%d%%", math.floor(item.percent_finished * 100))
        local badge = makeBadge(text, Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK)
        badge:paintTo(bb, d.x + d.w - badge:getSize().w - inset, d.y + inset)
        badge:free()
    end

    if CONFIG.badges.pages and not opened and item.status ~= "complete" and bookinfo and bookinfo.pages then
        local badge = makeBadge(bookinfo.pages .. " p.", Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_GRAY_3)
        badge:paintTo(bb, d.x + inset, d.y + d.h - badge:getSize().h - inset)
        badge:free()
    end

    if CONFIG.badges.status then
        if item.status == "complete" then
            drawDogear(bb, d, Blitbuffer.COLOR_BLACK)
        elseif item.status == "abandoned" then
            drawDogear(bb, d, Blitbuffer.COLOR_WHITE)
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
end

userpatch.registerPatchPluginFunc("projecttitle", patchCoverGrid)
