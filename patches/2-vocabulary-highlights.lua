--[[
2-vocabulary-highlights.lua — sends highlights of one color to the Vocabulary builder

Goal: collect new words while reading with a single highlight, and review them
later with KOReader's Vocabulary builder (flashcards with spaced repetition),
without opening the dictionary for every word.

What it does:
  - When a highlight gets the vocabulary color (gray, reserved for vocabulary
    by 2-highlights.lua), the highlighted word or short expression is
    added to the Vocabulary builder, with the book title and the sentence around
    it as context — the same way a dictionary lookup adds it.
  - Works both when the highlight is created with that color and when an
    existing highlight is changed to it.
  - Highlights longer than a few words are left out, since they are not
    vocabulary. Words already in the Vocabulary builder are not reset.
  - A menu entry adds all the vocabulary highlights of the open book at once,
    useful for books highlighted before installing this patch.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader. The Vocabulary
     builder plugin must be enabled (it is by default).
  2. Highlight a word and give it the gray color. A short message confirms it
     was added.
  3. Options: menu → search tab → Vocabulary from highlights.
  Review the words in menu → search tab → Vocabulary builder.
]]

local CONFIG = {
    color = "gray",       -- highlight color that means "vocabulary"
    max_words = 4,        -- longer highlights are not added
    context_words = 15,   -- words of context kept before and after
}

local Notification = require("ui/widget/notification")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local T = require("ffi/util").template

-- Whether new vocabulary highlights are added automatically
local function autoAdd()
    return G_reader_settings:nilOrTrue("vocabulary_highlights_auto")
end

-- The word or expression to save from a highlight's text, or nil when it is too long
local function wordFromText(text)
    if not text then return end
    local word = util.trim((util.stripPunctuation(util.cleanupSelectedText(text))))
    if word == "" then return end
    local count = 0
    for __ in word:gmatch("%S+") do count = count + 1 end
    if count > CONFIG.max_words then return end
    return word
end

local VocabularyHighlights = WidgetContainer:extend {
    name = "vocabulary_highlights",
}

-- Registers the menu entry
function VocabularyHighlights:init()
    self.ui.menu:registerToMainMenu(self)
end

-- The Vocabulary builder database module loaded by the plugin, or nil when the plugin is off
function VocabularyHighlights:database()
    if not self.ui.vocabbuilder then return end
    local db = package.loaded["db"]
    if type(db) == "table" and db.insertOrUpdate and db.hasWord then return db end
end

-- Adds one highlight to the Vocabulary builder; returns "added", "exists" or nil
function VocabularyHighlights:addItem(item, db)
    local word = wordFromText(item.text)
    if not word or not db then return end
    if db:hasWord(word) then return "exists" end
    local prev_context, next_context
    if item.pos0 and item.pos1 then
        local ok, p, n = pcall(self.ui.document.getSelectedWordContext, self.ui.document,
            item.text, CONFIG.context_words, item.pos0, item.pos1, true)
        if ok then prev_context, next_context = p, n end
    end
    local now = os.time()
    db:insertOrUpdate {
        book_title = self.ui.doc_props and self.ui.doc_props.display_title or "",
        time = now,
        word = word,
        prev_context = prev_context,
        next_context = next_context,
        highlight = item.text ~= word and util.cleanupSelectedText(item.text) or nil,
    }
    return "added", word
end

-- Adds a highlight that was just created with, or changed to, the vocabulary color
function VocabularyHighlights:onAnnotationsModified(items)
    local item = items and items[1]
    if not autoAdd() or not item or not item.drawer or item.color ~= CONFIG.color then return end
    if (items.nb_highlights_added or 0) < 0 or (items.index_modified or 0) < 0 or items[2] then return end
    local status, word = self:addItem(item, self:database())
    if status == "added" then
        Notification:notify(T("Added to Vocabulary builder: %1", word))
    end
end

-- Adds every vocabulary highlight of the open book and reports how many were new
function VocabularyHighlights:addAll()
    local db = self:database()
    local added, existing, skipped = 0, 0, 0
    for __, item in ipairs(self.ui.annotation.annotations) do
        if item.drawer and item.color == CONFIG.color then
            local status = self:addItem(item, db)
            if status == "added" then added = added + 1
            elseif status == "exists" then existing = existing + 1
            else skipped = skipped + 1 end
        end
    end
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new {
        text = T("Added: %1\nAlready there: %2\nToo long to be vocabulary: %3", added, existing, skipped),
    })
end

-- Adds "Vocabulary from highlights" to the search tab, under Vocabulary builder
function VocabularyHighlights:addToMainMenu(menu_items)
    menu_items.vocabulary_highlights = {
        text = "Vocabulary from highlights",
        enabled_func = function() return self.ui.vocabbuilder ~= nil end,
        sub_item_table = {
            {
                text = "Add vocabulary highlights automatically",
                checked_func = autoAdd,
                callback = function()
                    G_reader_settings:saveSetting("vocabulary_highlights_auto", not autoAdd())
                end,
            },
            {
                text = "Add this book's vocabulary highlights now",
                keep_menu_open = true,
                callback = function() self:addAll() end,
            },
        },
    }
end

-- Puts the menu entry right after Vocabulary builder
local order = require("ui/elements/reader_menu_order")
if order.search and not util.arrayContains(order.search, "vocabulary_highlights") then
    local pos = #order.search
    for i, id in ipairs(order.search) do
        if id == "vocabbuilder" then pos = i break end
    end
    table.insert(order.search, pos + 1, "vocabulary_highlights")
end

-- Registers the module in every opened book
local orig_init = ReaderUI.init
ReaderUI.init = function(self, ...)
    orig_init(self, ...)
    self:registerModule("vocabulary_highlights", VocabularyHighlights:new { ui = self })
end
