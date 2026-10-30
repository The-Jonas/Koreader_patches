--[[
2-physical-pages.lua — page numbers that match the printed edition

Goal: make page 120 on the reader be page 120 of the physical book, so you can
quote passages, follow book clubs and track progress with the same page count
as the printed edition.

What it does:
  - Tunes KOReader's stable page numbers so that the book's total page count
    matches the printed edition. The patch works out how many characters fit on
    each page to reach that total.
  - The printed page count can come from two sources:
      automatic: Open Library lookup by the book's ISBN or, without an ISBN, by
                 title and author (needs Wi-Fi)
      manual:    you type the page count of your edition
  - The value is saved per book and applied again every time the book is opened.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. With an EPUB open: menu → navigation tab → Settings → Stable page numbers
     → Printed edition pages.
  3. Choose "Look up on Open Library" or "Set manually".

Books that already ship the publisher's page numbers are left untouched unless
you set a value manually.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local ReaderPageMap = require("apps/reader/modules/readerpagemap")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template

local SETTING_TARGET = "physical_pages_target"
local SETTING_SOURCE = "physical_pages_source"
local SETTING_LEGACY = "yanllsama_physical_pages"
local MIN_CHARS_PER_PAGE = 200
local MAX_ITERATIONS = 4

-- Performs a GET and returns the response body, or nil and an error message
local function httpGet(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(10, 30)
    local code = socket.skip(1, http.request {
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = "KOReader physical-pages patch" },
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        return nil, "HTTP " .. tostring(code)
    end
    return table.concat(sink)
end

-- Extracts an ISBN-13 or ISBN-10 from the book identifiers field
local function findIsbn(identifiers)
    if not identifiers then return nil end
    local clean = identifiers:gsub("[%s%-]", "")
    return clean:match("97[89]%d%d%d%d%d%d%d%d%d%d") or clean:match("%f[%d]%d%d%d%d%d%d%d%d%d[%dXx]%f[^%dXx]")
end

-- Queries Open Library and returns the page count and where it came from
local function lookupOpenLibrary(props)
    local json = require("json")
    local escape = require("socket.url").escape

    local isbn = findIsbn(props.identifiers)
    if isbn then
        local body = httpGet("https://openlibrary.org/isbn/" .. isbn .. ".json")
        local ok, data = pcall(json.decode, body or "")
        if ok and type(data) == "table" and tonumber(data.number_of_pages) then
            return tonumber(data.number_of_pages), "ISBN " .. isbn
        end
    end

    local title = props.title
    if not title or title == "" then return nil end
    local author = props.authors and props.authors:match("^[^\n]+") or ""
    local url = "https://openlibrary.org/search.json?limit=1&fields=number_of_pages_median,title"
        .. "&title=" .. escape(title)
        .. (author ~= "" and ("&author=" .. escape(author)) or "")
    local body, err = httpGet(url)
    if not body then return nil, err end
    local ok, data = pcall(json.decode, body)
    if ok and type(data) == "table" and data.docs and data.docs[1] then
        local pages = tonumber(data.docs[1].number_of_pages_median)
        if pages then
            return pages, T("title search (%1)", data.docs[1].title or title)
        end
    end
    return nil, "book not found"
end

-- Total pages of the current synthetic page map
function ReaderPageMap:_physicalCurrentCount()
    local _, _, count = self.ui.document:getPageMapCurrentPageLabel()
    return tonumber(count) or 0
end

-- Adjusts characters per page until the total matches target_pages and enables page labels
function ReaderPageMap:applyPhysicalPages(target_pages)
    local doc = self.ui.document
    local cpp = self.chars_per_synthetic_page or doc:getSyntheticPageMapCharsPerPage()
    if not cpp or cpp <= 0 then
        cpp = self.chars_per_synthetic_page_default
        doc:buildSyntheticPageMap(cpp)
    end
    for _ = 1, MAX_ITERATIONS do
        local count = self:_physicalCurrentCount()
        if count == target_pages or count == 0 then break end
        local new_cpp = math.max(MIN_CHARS_PER_PAGE, math.floor(cpp * count / target_pages + 0.5))
        if new_cpp == cpp then break end
        cpp = new_cpp
        doc:buildSyntheticPageMap(cpp)
    end

    if not self.has_pagemap then
        self.has_pagemap = true
        self:resetLayout()
        self.view:registerViewModule("pagemap", self)
    end
    self.chars_per_synthetic_page = cpp
    self.page_labels_cache = nil
    self.use_page_labels = true
    self:updateVisibleLabels()
    local settings = self.ui.doc_settings
    settings:saveSetting("pagemap_chars_per_synthetic_page", cpp)
    settings:saveSetting("pagemap_use_page_labels", true)
    settings:saveSetting("pagemap_doc_pages", self:_physicalCurrentCount())
    UIManager:setDirty(self.view.dialog, "partial")
    UIManager:broadcastEvent(Event:new("UsePageLabelsUpdated"))
    return self:_physicalCurrentCount(), cpp
end

-- Saves the target page count, applies it and shows the result
function ReaderPageMap:setPhysicalPages(pages, source, touchmenu_instance)
    local settings = self.ui.doc_settings
    settings:saveSetting(SETTING_TARGET, pages)
    settings:saveSetting(SETTING_SOURCE, source)
    local count, cpp = self:applyPhysicalPages(pages)
    UIManager:show(InfoMessage:new {
        text = T("Page numbers adjusted: %1 pages (%2 characters per page).\nSource: %3", count, cpp, source),
        timeout = 4,
    })
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

-- Looks up the page count on Open Library and asks for confirmation before applying
function ReaderPageMap:lookupPhysicalPages(touchmenu_instance)
    NetworkMgr:runWhenOnline(function()
        local searching = InfoMessage:new { text = "Searching Open Library…" }
        UIManager:show(searching)
        UIManager:forceRePaint()
        local ok, pages, source = pcall(lookupOpenLibrary, self.ui.doc_props or {})
        UIManager:close(searching)
        if not ok then
            logger.warn("physical-pages:", pages)
            pages, source = nil, "lookup error"
        end
        if not pages then
            UIManager:show(InfoMessage:new {
                text = T("Could not get the page count (%1).\nUse \"Set manually\".", source or "?"),
            })
            return
        end
        UIManager:show(ConfirmBox:new {
            text = T("Printed edition with %1 pages.\nSource: %2\n\nApply to this book?", pages, source),
            ok_text = "Apply",
            ok_callback = function()
                self:setPhysicalPages(pages, "Open Library — " .. source, touchmenu_instance)
            end,
        })
    end)
end

-- Opens a number picker to enter the edition's page count
function ReaderPageMap:showPhysicalPagesSpin(touchmenu_instance)
    local current = self.ui.doc_settings:readSetting(SETTING_TARGET)
        or (self.has_pagemap and self:_physicalCurrentCount()) or 300
    UIManager:show(SpinWidget:new {
        title_text = "Printed edition pages",
        info_text = "Total pages of the physical book (you may leave out indexes and appendices).",
        value = current,
        value_min = 10,
        value_max = 9999,
        value_step = 1,
        value_hold_step = 50,
        ok_always_enabled = true,
        callback = function(spin)
            self:setPhysicalPages(spin.value, "manual", touchmenu_instance)
        end,
    })
end

-- Removes the target page count and goes back to the default characters per page
function ReaderPageMap:clearPhysicalPages(touchmenu_instance)
    local settings = self.ui.doc_settings
    settings:delSetting(SETTING_TARGET)
    settings:delSetting(SETTING_SOURCE)
    local cpp = G_reader_settings:readSetting("pagemap_chars_per_synthetic_page") or self.chars_per_synthetic_page_default
    self.ui.document:buildSyntheticPageMap(cpp)
    self.chars_per_synthetic_page = cpp
    self.page_labels_cache = nil
    self:updateVisibleLabels()
    settings:saveSetting("pagemap_chars_per_synthetic_page", cpp)
    settings:saveSetting("pagemap_doc_pages", self:_physicalCurrentCount())
    UIManager:setDirty(self.view.dialog, "partial")
    UIManager:broadcastEvent(Event:new("UsePageLabelsUpdated"))
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

-- Adds the "Printed edition pages" submenu to the stable page numbers menu
local orig_addToMainMenu = ReaderPageMap.addToMainMenu
ReaderPageMap.addToMainMenu = function(self, menu_items)
    orig_addToMainMenu(self, menu_items)
    local page_map = menu_items.page_map
    if not page_map or not page_map.sub_item_table then return end
    table.insert(page_map.sub_item_table, 1, {
        text_func = function()
            local target = self.ui.doc_settings:readSetting(SETTING_TARGET)
            return target and T("Printed edition pages: %1", target) or "Printed edition pages"
        end,
        separator = true,
        sub_item_table_func = function()
            return {
                {
                    text_func = function()
                        local source = self.ui.doc_settings:readSetting(SETTING_SOURCE)
                        return source and T("Source: %1", source) or "No value set for this book"
                    end,
                    enabled_func = function() return false end,
                    separator = true,
                },
                {
                    text = "Look up on Open Library",
                    keep_menu_open = true,
                    callback = function(touchmenu_instance) self:lookupPhysicalPages(touchmenu_instance) end,
                },
                {
                    text = "Set manually",
                    keep_menu_open = true,
                    callback = function(touchmenu_instance) self:showPhysicalPagesSpin(touchmenu_instance) end,
                },
                {
                    text = "Remove and restore default",
                    keep_menu_open = true,
                    enabled_func = function()
                        return self.ui.doc_settings:readSetting(SETTING_TARGET) ~= nil
                    end,
                    callback = function(touchmenu_instance) self:clearPhysicalPages(touchmenu_instance) end,
                },
            }
        end,
    })
end

-- Reapplies the saved target when the book opens (also reads the value saved by the "applyPerfectSync" Statistics fork)
local orig_postInit = ReaderPageMap._postInit
ReaderPageMap._postInit = function(self)
    orig_postInit(self)
    local settings = self.ui.doc_settings
    local legacy = settings:readSetting(SETTING_LEGACY)
    if legacy and not settings:readSetting(SETTING_TARGET) then
        settings:saveSetting(SETTING_TARGET, legacy)
        settings:saveSetting(SETTING_SOURCE, "manual (imported)")
    end
    local target = settings:readSetting(SETTING_TARGET)
    if target and (not self.has_pagemap or self:_physicalCurrentCount() ~= target) then
        self:applyPhysicalPages(target)
    end
end

-- Only uses page labels while a document is open
local orig_wantsPageLabels = ReaderPageMap.wantsPageLabels
ReaderPageMap.wantsPageLabels = function(self)
    if not self.ui or not self.ui.document then return false end
    return orig_wantsPageLabels(self)
end
