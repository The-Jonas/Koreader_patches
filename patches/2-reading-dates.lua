--[[
2-reading-dates.lua — start and finish date of every book

Goal: know when each book was started and finished without writing it down,
to build a reading log or history.

What it does:
  Stores in the book metadata (.sdr folder, inside ["summary"]):
    started_on  = date the book was first opened (YYYY-MM-DD)
    finished_on = date the book was marked as "Finished"

Rules:
  - started_on is only stored when the book had no status yet
    (a real first opening, or the first opening after "Reset").
  - finished_on is stored when the status becomes "complete", no matter how
    (end of book, book status screen, file manager menu, multiple selection).
    If the status leaves "complete", the date is removed.
  - "Reset" in the file manager clears the whole summary, so both dates go
    with it — that is how to undo an accidental opening.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. The dates show up in "Book information" (from the book menu while reading,
     or by long-pressing the book in the file manager), right above "Rating".
     "—" means no date was recorded.
]]

local DocSettings = require("docsettings")
local ReaderUI = require("apps/reader/readerui")
local logger = require("logger")

-- Today's date in the same format KOReader uses for summary.modified
local function today()
    return os.date("%Y-%m-%d", os.time())
end

-- Wraps ReaderUI:init to find out whether the book already had a status when opened
-- and, if it didn't, stores started_on after KOReader marks it as "reading"
local orig_init = ReaderUI.init
ReaderUI.init = function(self, ...)
    local orig_open = DocSettings.open
    local had_status = true
    DocSettings.open = function(ds_class, path)
        DocSettings.open = orig_open
        local ds = orig_open(ds_class, path)
        local summary = ds:readSetting("summary")
        had_status = (summary ~= nil and summary.status ~= nil)
        return ds
    end
    local ok, err = pcall(orig_init, self, ...)
    DocSettings.open = orig_open
    if not ok then error(err, 0) end

    local summary = self.doc_settings and self.doc_settings:readSetting("summary")
    if not had_status and summary and summary.status == "reading" and not summary.started_on then
        summary.started_on = today()
        logger.dbg("reading-dates: started_on =", summary.started_on)
    end
end

-- Wraps DocSettings:flush to keep finished_on in sync with the status when metadata is written.
-- Our own bookkeeping runs inside pcall: if it ever breaks, the real flush below still happens,
-- so a bug here can never cost a page position or a highlight.
local orig_flush = DocSettings.flush
DocSettings.flush = function(self, data, ...)
    local ok, err = pcall(function()
        local d = data or self.data
        local summary = d and d.summary
        if type(summary) == "table" then
            if summary.status == "complete" then
                if not summary.finished_on then
                    summary.finished_on = summary.modified or today()
                end
            elseif summary.finished_on then
                summary.finished_on = nil
            end
        end
    end)
    if not ok then
        logger.warn("reading-dates: finished_on bookkeeping failed, saving anyway:", err)
    end
    return orig_flush(self, data, ...)
end

local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local KeyValuePage = require("ui/widget/keyvaluepage")
local _ = require("gettext")

-- Reads the summary from either a DocSettings object or a file path
local function getSummary(doc_settings_or_file)
    if type(doc_settings_or_file) == "table" then
        return doc_settings_or_file:readSetting("summary")
    end
    if DocSettings:hasSidecarFile(doc_settings_or_file) then
        return DocSettings:open(doc_settings_or_file):readSetting("summary")
    end
end

-- Wraps BookInfo:show to insert "Started" and "Finished" right before the "Rating" row
local orig_show = BookInfo.show
BookInfo.show = function(self, doc_settings_or_file, ...)
    local summary = getSummary(doc_settings_or_file) or {}
    local orig_new = KeyValuePage.new
    KeyValuePage.new = function(kvp_class, o)
        KeyValuePage.new = orig_new
        if o and o.kv_pairs then
            local rating_label = _("Rating:")
            local pos = #o.kv_pairs + 1
            for i, kv in ipairs(o.kv_pairs) do
                if kv[1] == rating_label then pos = i break end
            end
            table.insert(o.kv_pairs, pos, { _("Started:"), summary.started_on or "—" })
            table.insert(o.kv_pairs, pos + 1, { _("Finished:"), summary.finished_on or "—" })
        end
        return orig_new(kvp_class, o)
    end
    local ok, err = pcall(orig_show, self, doc_settings_or_file, ...)
    KeyValuePage.new = orig_new
    if not ok then error(err, 0) end
end
