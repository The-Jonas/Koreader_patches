--[[
2-highlights.lua — highlight colors, style meanings, pickers and filter shortcuts

Goal: tell highlights apart at a glance and find each kind again later, even on a
grayscale e-ink screen.

What it does:
  - The MEANING of a highlight lives in its style (styles come from
    2-highlight-styles.lua): Box means Important, Wavy means Confusing, Quotes means
    Smart Quote, and so on. Style buttons read "Important · Box" — meaning first,
    style name after — and the styles that have a meaning come first in the list.
  - Colors are just colors, by name. Each one is tuned to land on its own gray level
    of a 16-level e-ink screen (from Black, level 0, to Yellow, level 14), so no two
    look alike on a grayscale Kindle; the hue is kept, so they stay recognizable on
    color screens and in exports. Gray is reserved for 2-vocabulary-highlights.lua,
    which watches for it to send words to the Vocabulary builder.
  - The dark colors (Black, Maroon, Blue, Purple) get white text: on their buttons in
    the color picker, and — with 2-highlight-styles.lua — on the page too.
  - The color and style pickers are laid out in a grid (4 colors / 2 styles per row),
    so the whole list fits on the screen without scrolling.
  - Everything is renamable from the Kindle itself, no file editing or restart: menu →
    Tools → More tools → Highlight labels → Colors / Styles. Pick one, type a new name
    (or clear it to go back to the default) and the pickers update right away.
  - Three gesture actions (Settings → Taps and gestures → Gesture manager → pick a
    gesture → Reader), each opening the highlight list with the filter already shown:
      Filter highlights by style
      Filter highlights by color
      Filter highlights by style and color

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader (fully: patches are only
     read when KOReader starts). Renames from the menu need no restart.
  2. Colors, their tones, style meanings and grid columns are in CONFIG below.
     The color key (red, orange…) is what each highlight stores: don't remove a key that
     highlights already use; its name and tone can be changed freely.
  3. A default color for new highlights is native: menu → Typeset → Highlights →
     Highlight color — tap to pick it for this book, hold to make it the default.
]]

local CONFIG = {
    -- Ordered from darkest to lightest. Each tone was picked so its gray value
    -- (KOReader's formula: 0.299 R + 0.587 G + 0.114 B) lands right on one of the
    -- 16 e-ink levels: 0x00, 0x11, 0x22... The four darkest get white text.
    colors = {
        { key = "black",  hex = "#000000" }, -- level 0
        { key = "maroon", hex = "#750000" }, -- level 2
        { key = "blue",   hex = "#004ADF" }, -- level 4
        { key = "purple", hex = "#AF26F4" }, -- level 6
        { key = "red",    hex = "#FF5848" }, -- level 8
        { key = "orange", hex = "#FF8204" }, -- level 9
        { key = "green",  hex = "#50E080" }, -- level 10
        { key = "cyan",   hex = "#3BEFFF" }, -- level 11
        { key = "gray",   hex = "#CCCCCC" }, -- level 12, Vocabulary (2-vocabulary-highlights.lua)
        { key = "olive",  hex = "#DDE8A5" }, -- level 13
        { key = "yellow", hex = "#FFF88F" }, -- level 14
    },
    -- Below this gray value (0-255), text on the color is drawn white instead of black.
    -- 2-highlight-styles.lua uses the same value for highlights on the page.
    dark_level = 0x80,
    -- Every style key we know about, with its plain name and, for some, the meaning it
    -- carries by default. Styles without a meaning show just their name until one is set
    -- from the menu. Styles with a meaning are listed first, in this order.
    -- Os símbolos abaixo foram escolhidos só entre os que o emulador confirmou
    -- desenhar na fonte do leitor (testado com HLTEST=symboltest); emojis coloridos
    -- modernos (🔑💬🌍 etc.) não têm glifo nessa fonte e saem como quadradinhos vazios.
    -- "guide" é só usado pelo guia de marcadores (menu ℹ na escolha de estilos, ou pelo
    -- ☰ da lista de destaques → "Filter by highlight style/color") — não aparece em
    -- nenhum botão, só no texto do guia.
    styles = {
        { key = "lighten_underline", name = "Lighten + underline",  meaning = "★ Important",
          guide = "Informação-chave que você não quer perder de vista ao reler." },
        { key = "lighten",           name = "Lighten",               meaning = "✎ Vocabulary",
          guide = "Palavras e expressões desconhecidas, seus significados ou usos interessantes que você deseja aprender e incorporar ao vocabulário." },
        { key = "marker",            name = "Marker underline",      meaning = "◎ World Building",
          guide = "Detalhes sobre o mundo, lugares, sistemas e regras do universo da história." },
        { key = "double_underline",  name = "Double underline",      meaning = "¶ Lore",
          guide = "História, mitologia ou eventos passados do universo da obra." },
        { key = "stars",             name = "Stars",                 meaning = "⁂ Joke",
          guide = "Piadas, trocadilhos ou momentos de humor." },
        { key = "wavy",              name = "Wavy",                  meaning = "‽ Confusing",
          guide = "Trechos confusos, que você precisa reler ou pesquisar depois." },
        { key = "rounded_box",       name = "Rounded box",           meaning = "❤ Emotional",
          guide = "Momentos que te emocionaram — tristes, felizes ou intensos." },
        { key = "strikeout",         name = "Strikethrough",         meaning = "☢ Disturbing",
          guide = "Trechos perturbadores ou desconfortáveis de alguma forma." },
        { key = "brackets",          name = "Brackets",              meaning = "◈ Entities",
          guide = "Nomes de personagens, lugares ou organizações, pra lembrar quem é quem." },
        { key = "italic",            name = "Italic",                meaning = "↑ Character Development",
          guide = "Momentos de crescimento ou mudança de um personagem." },
        { key = "bold",              name = "Bold",                  meaning = "✪ Character Insight",
          guide = "Algo que revela a personalidade ou a motivação de um personagem." },
        { key = "bold_italic",       name = "Bold + italic",         meaning = "♡ Relatable",
          guide = "Trechos com que você se identificou pessoalmente." },
        { key = "quotes",            name = "Quotes",                meaning = "∴ Philosophical",
          guide = "Reflexões ou ideias filosóficas do texto." },
        { key = "lighten_rounded",   name = "Lighten + rounded box", meaning = "⇄ Plot Twist",
          guide = "Reviravoltas na trama." },
        { key = "dotted",            name = "Dotted",                meaning = "⚖ Moral Dilemma",
          guide = "Situações que apresentam conflitos éticos ou decisões difíceis, nas quais não existe uma resposta moral simples." },
        { key = "dashed",            name = "Dashed",                meaning = "… Thought-provoking",
          guide = "Trechos que te fizeram parar pra pensar." },
        { key = "box",               name = "Box",                   meaning = "§ Smart Quote",
          guide = "Frases ou falas especialmente bem escritas, dignas de guardar." },
        { key = "underscore",        name = "Underline",             meaning = "⚓ Reference",
          guide = "Referências a outras obras, eventos reais ou citações externas." },
        { key = "invert",            name = "Invert",                meaning = "〰 Foreshadowing",
          guide = "Pistas ou indícios de algo que vai acontecer mais à frente." },
        { key = "dashed_box",        name = "Dashed box",            meaning = "✦ Beautiful Writing",
          guide = "Prosa ou escrita especialmente bonita, pela forma mais que pelo conteúdo." },
    },
    -- Pickers as a grid: buttons per row, and dialog width (fraction of the screen width)
    picker_columns = { colors = 4, styles = 2 },
    picker_width = 0.97,
}

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonSelector = require("ui/widget/buttonselector")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local ReaderBookmark = require("apps/reader/modules/readerbookmark")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local ReaderUI = require("apps/reader/readerui")
local RenderText = require("ui/rendertext")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template


for _, c in ipairs(CONFIG.colors) do
    Blitbuffer.HIGHLIGHT_COLORS[c.key] = c.hex
end

------------------------------------------------------------------------
-- Labels: defaults from CONFIG, overridden from the menu
------------------------------------------------------------------------

-- { color = { red = "...", ... }, style = { box = "...", ... } }
local function savedLabels()
    return G_reader_settings:readSetting("highlight_labels") or {}
end

-- Sets (or, with an empty string, clears) one label override and saves it
local function setSavedLabel(kind, key, text)
    local saved = savedLabels()
    saved[kind] = saved[kind] or {}
    saved[kind][key] = (text ~= "") and text or nil
    G_reader_settings:saveSetting("highlight_labels", saved)
end

-- Migração única: o estilo "stars" (hoje Joke) tinha um significado salvo de uma
-- renomeação antiga ("Joke", sem ícone), que sempre tomava a frente do valor padrão
-- do CONFIG — por isso nenhuma troca de ícone feita aqui pra esse marcador aparecia.
-- Remove essa sobra uma única vez; depois disso o CONFIG volta a valer normalmente,
-- a não ser que o usuário renomeie de novo pelo menu.
if not G_reader_settings:isTrue("highlight_labels_stars_migrated_v1") then
    local saved = savedLabels()
    if saved.style and saved.style.stars ~= nil then
        saved.style.stars = nil
        G_reader_settings:saveSetting("highlight_labels", saved)
    end
    G_reader_settings:saveSetting("highlight_labels_stars_migrated_v1", true)
end

local function titleCase(word)
    return word:sub(1, 1):upper() .. word:sub(2)
end

-- The name shown for a color: the saved override, or the color's own name
local function colorLabel(key)
    return (savedLabels().color or {})[key] or titleCase(key)
end

local style_defaults, style_rank = {}, {}
for i, s in ipairs(CONFIG.styles) do
    style_defaults[s.key] = s
    style_rank[s.key] = i
end

-- The meaning saved for a style, or its CONFIG default (nil if it has neither)
local function styleMeaning(key)
    local saved = (savedLabels().style or {})[key]
    if saved then return saved end
    return style_defaults[key] and style_defaults[key].meaning
end

-- "Important · Box" when the style has a meaning, otherwise just "Box"
local function styleButtonLabel(key)
    local name = style_defaults[key] and style_defaults[key].name or key
    local meaning = styleMeaning(key)
    if not meaning then return name end
    return meaning .. " · " .. name
end

------------------------------------------------------------------------
-- Wires the labels into the lists the pickers are built from
------------------------------------------------------------------------

-- The style list is a local table of readerhighlight.lua (2-highlight-styles.lua, which
-- loads first, has already added its styles to it). It's found among the upvalues of
-- ReaderHighlight's functions, by the "underscore" entry only it has.
local function findEntryShape(t)
    if type(t.underscore) == "string" then return "map" end
    for _, e in ipairs(t) do
        if type(e) == "table" then
            if e[2] == "underscore" then return "array_label_key" end
            if e[1] == "underscore" then return "array_key_label" end
        end
    end
end

local function findStyleTable()
    for _, fn in pairs(ReaderHighlight) do
        if type(fn) == "function" then
            local i = 1
            while true do
                local name, val = debug.getupvalue(fn, i)
                if not name then break end
                if type(val) == "table" then
                    local shape = findEntryShape(val)
                    if shape then return val, shape end
                end
                i = i + 1
            end
        end
    end
end

local style_table, style_shape = findStyleTable()
local key_idx = style_shape == "array_key_label" and 1 or 2
local label_idx = style_shape == "array_key_label" and 2 or 1

-- Position of a style in the list: styles with a meaning first (CONFIG order), then the
-- others (CONFIG order), then any style CONFIG doesn't know, as they came
local first_seen = {}
local function styleOrder(key)
    local base = style_rank[key] or (1000 + (first_seen[key] or 0))
    return styleMeaning(key) and base or base + 100
end

-- Rebuilds the color list, relabels every known style and puts the styles in order;
-- called at startup and after every rename, so changes show up right away
local function refreshLabels()
    local highlight_colors = {}
    for _, c in ipairs(CONFIG.colors) do
        table.insert(highlight_colors, { colorLabel(c.key), c.key })
    end
    ReaderHighlight.highlight_colors = highlight_colors

    if style_table and style_shape ~= "map" then
        for i, e in ipairs(style_table) do
            local key = e[key_idx]
            first_seen[key] = first_seen[key] or i
            if style_defaults[key] then
                e[label_idx] = styleButtonLabel(key)
            end
        end
        table.sort(style_table, function(a, b) return styleOrder(a[key_idx]) < styleOrder(b[key_idx]) end)
    end
end
refreshLabels()

------------------------------------------------------------------------
-- Pickers: grid layout, white text on the dark colors
------------------------------------------------------------------------

-- True while a highlight picker builds its buttons (see ButtonDialog.init below)
local building_picker = false

-- Gray value (0-255) of a color, or nil
local function grayOf(color)
    local ok, gray = pcall(function() return color:getColor8().a end)
    return ok and gray or nil
end

-- Button text is always drawn black: on a dark color swatch it turns white
local orig_button_init = Button.init
Button.init = function(self, ...)
    orig_button_init(self, ...)
    if building_picker then self._on_highlight_picker = true end
    if self._on_highlight_picker and self.background and self.text and self.label_widget then
        local gray = grayOf(self.background)
        if gray and gray < CONFIG.dark_level then
            self.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
            if self.label_widget.update then -- two-line TextBoxWidget: redraw with the new color
                self.label_widget:update()
            end
        end
    end
end

-- Mostra o guia com todos os marcadores: significado, estilo e quando usar cada um
local function showMarkerGuide()
    local lines = {}
    for _, s in ipairs(CONFIG.styles) do
        if s.meaning and s.guide then
            table.insert(lines, T("%1 — %2\n%3", styleMeaning(s.key), s.name, s.guide))
        end
    end
    UIManager:show(TextViewer:new{
        title = _("Marker guide"),
        text = table.concat(lines, "\n\n"),
    })
end

-- Regroups the one-button rows of a picker into rows of `columns` buttons; the last row is
-- completed with blank cells so every button keeps the same width
local function arrangeInGrid(dialog, columns)
    local n = #dialog.values
    local rows = {}
    for i = 1, n do
        local r = math.ceil(i / columns)
        rows[r] = rows[r] or {}
        table.insert(rows[r], dialog.buttons[i][1])
    end
    local last = rows[#rows]
    if last and #last < columns then
        last[#last].no_vertical_sep = true
        while #last < columns do
            table.insert(last, { text = "", enabled = false, no_vertical_sep = true, callback = function() end })
        end
    end
    for i = n + 1, #dialog.buttons do -- rows the picker adds after the values, if any
        table.insert(rows, dialog.buttons[i])
    end
    dialog.buttons = rows
end

-- Marks the highlight color and style pickers (wherever they're opened from) as grids
local orig_selector_init = ButtonSelector.init
ButtonSelector.init = function(self, ...)
    local styles = ReaderHighlight.getHighlightStyles and ReaderHighlight.getHighlightStyles()
    if self.bg_colors then
        self._grid_columns = CONFIG.picker_columns.colors
    elseif styles and self.values == styles then
        self._grid_columns = CONFIG.picker_columns.styles
    end
    if self._grid_columns and not self.width then
        self.width_factor = CONFIG.picker_width
    end
    return orig_selector_init(self, ...)
end

-- Button:init() shrinks a button's own font only as much as its own text needs, so in a
-- grid with mixed label lengths (ex.: "Important · Lighten + underline" vs "Joke · Stars")
-- each button ends up with a different size. Equalizes them: finds the smallest size the
-- grid settled on and rebuilds every other button's label at that same size, keeping each
-- button's own box (set beforehand, independent of this) exactly as it was.
local function equalizeButtonFontSizes(buttontable)
    if not buttontable or not buttontable.buttons_layout then return end
    local min_size
    for _, row in ipairs(buttontable.buttons_layout) do
        for _, button in ipairs(row) do
            if button.text and button.text ~= "" and button.label_widget and button.label_widget.face then
                local size = button.label_widget.face.orig_size or button.label_widget.face.size
                if size and (not min_size or size < min_size) then
                    min_size = size
                end
            end
        end
    end
    if not min_size then return end
    for _, row in ipairs(buttontable.buttons_layout) do
        for _, button in ipairs(row) do
            local old = button.label_widget
            if button.text and button.text ~= "" and old and old.face then
                local cur_size = old.face.orig_size or old.face.size
                if cur_size and cur_size > min_size then
                    local box = button.label_container
                    local text = button.checked_func and button:getDisplayText() or button.text
                    local new_widget = TextBoxWidget:new{
                        text = text,
                        lang = button.lang,
                        line_height = 0,
                        alignment = button.align,
                        width = box.dimen.w,
                        height = box.dimen.h,
                        height_adjust = true,
                        height_overflow_show_ellipsis = true,
                        fgcolor = old.fgcolor,
                        bgcolor = button.background,
                        bold = button.text_font_bold,
                        face = Font:getFace(button.text_font_face, min_size),
                    }
                    button.label_widget = new_widget
                    box[1] = new_widget
                    if old.free then old:free(true) end
                end
            end
        end
    end
    return min_size
end

-- Depois do equalizeButtonFontSizes, todos os botões de estilo já desenham no mesmo
-- tamanho de fonte. Esse passo alinha a coluna dos ícones: mede o ícone e o espaço com
-- a MESMA fonte que vai aparecer no botão (RenderText, em tempo de execução — por isso
-- funciona igual em qualquer fonte/tela, sem precisar ajustar na mão pra cada aparelho)
-- e completa cada rótulo com espaços até a largura do maior ícone da grade. Assim o
-- ícone sempre cai na mesma coluna e a palavra do significado começa no mesmo lugar em
-- toda a grade, em vez de "torto" conforme a largura de cada símbolo.
local function alignStyleButtonIcons(buttontable, min_size)
    if not buttontable or not buttontable.buttons_layout or not min_size then return end
    local entries = {}
    local face, space_w, max_icon_w
    for _, row in ipairs(buttontable.buttons_layout) do
        for _, button in ipairs(row) do
            if button.text and button.text ~= "" and button.label_widget then
                local icon, rest = button.text:match("^(%S+)%s(.*)$")
                if icon and rest and rest:find("·", 1, true) then
                    if not face then
                        face = Font:getFace(button.text_font_face, min_size)
                        space_w = RenderText:sizeUtf8Text(0, nil, face, " ", true).x
                    end
                    local icon_w = RenderText:sizeUtf8Text(0, nil, face, icon, true).x
                    if not max_icon_w or icon_w > max_icon_w then max_icon_w = icon_w end
                    table.insert(entries, { button = button, icon = icon, rest = rest, icon_w = icon_w })
                end
            end
        end
    end
    if not max_icon_w or not space_w or space_w <= 0 then return end

    -- Alvo: a largura do maior ícone + 2 espaços de folga. Cada ícone recebe o número
    -- de espaços (arredondado, nunca menos de 2) que mais aproxima seu total dessa
    -- meta — o espaço só anda de 9 em 9px, então não dá pra bater certinho sempre,
    -- mas arredondando pro mais perto o desvio fica pequeno e nenhuma linha fica colada.
    local target = max_icon_w + 2 * space_w
    for _, entry in ipairs(entries) do
        local button = entry.button
        local pad_n = math.max(2, math.floor((target - entry.icon_w) / space_w + 0.5))
        button.text = entry.icon .. string.rep(" ", pad_n) .. entry.rest
        local old = button.label_widget
        local box = button.label_container
        local new_widget = TextBoxWidget:new{
            text = button.checked_func and button:getDisplayText() or button.text,
            lang = button.lang,
            line_height = 0,
            alignment = button.align,
            width = box.dimen.w,
            height = box.dimen.h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            fgcolor = old.fgcolor,
            bgcolor = button.background,
            bold = button.text_font_bold,
            face = face,
        }
        button.label_widget = new_widget
        box[1] = new_widget
        if old.free then old:free(true) end
    end
end

------------------------------------------------------------------------
-- Prévia do estilo no nome dos marcadores (Tools → Highlight labels →
-- "Preview style on names"): cada botão da grade de estilo passa a mostrar, no
-- próprio texto, um gostinho de como aquele estilo fica de verdade. Ativado por
-- padrão; dá pra desligar pelo menu, caso não agrade.
------------------------------------------------------------------------

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local GRAY = Blitbuffer.COLOR_GRAY
local PREVIEW_FILL = Blitbuffer.COLOR_GRAY_D

local function stylePreviewEnabled()
    return G_reader_settings:nilOrTrue("highlight_style_preview")
end

local function psc(n)
    return math.max(1, Screen:scaleBySize(n))
end

-- Funções seguras de desenho (sem ctx nem estado compartilhado entre retângulos),
-- expostas pelo 2-highlight-styles.lua
local style_paint = ReaderHighlight._user_patch_style_paint or {}

-- As três que, no desenho real, dependem de trackRect (abre numa ponta do destaque,
-- fecha na outra, possivelmente numa chamada bem depois) não são reaproveitadas aqui:
-- numa prévia isolada de um botão, a "ponta de fechar" nunca chegaria a sair, e mexer
-- naquele estado compartilhado por fora do fluxo real de desenho da página é arriscado.
-- Cada uma ganha uma versão simplificada e autocontida, só com fins de prévia.
local function previewDashedBorder(bb, x, y, w, h)
    local th, dash, gap = psc(1.5), psc(4), psc(2.5)
    -- folga pros dois lados, senão a borda cai em cima do ícone (esquerda) e da
    -- última letra do nome (direita) — mesma ideia do pad() usado no estilo real.
    local pd = psc(3)
    local bx, bw = x - pd, w + 2 * pd
    local function hline(yy)
        local i = 0
        while i < bw do
            bb:paintRect(bx + i, yy, math.min(dash, bw - i), th, BLACK)
            i = i + dash + gap
        end
    end
    local function vline(xx)
        local i = 0
        while i < h do
            bb:paintRect(xx, y + i, th, math.min(dash, h - i), BLACK)
            i = i + dash + gap
        end
    end
    hline(y); hline(y + h - th); vline(bx); vline(bx + bw - th)
end

local function previewBrackets(bb, x, y, w, h)
    local t, serif = psc(1.5), psc(4)
    -- afasta só o colchete da esquerda do ícone/emote que vem antes dele; o da
    -- direita já tem espaço de sobra até a borda do botão.
    local left_gap = psc(4)
    -- inward > 0: serifa aponta pra dentro do texto (bracket da esquerda, "[");
    -- inward < 0: serifa aponta pra dentro vindo da direita (bracket da direita, "]")
    local function mark(edge, inward)
        bb:paintRect(edge, y, t, h, BLACK)
        local serif_x = inward > 0 and edge or (edge + t - serif)
        bb:paintRect(serif_x, y, serif, t, BLACK)
        bb:paintRect(serif_x, y + h - t, serif, t, BLACK)
    end
    mark(x - left_gap, 1)
    mark(x + w - t, -1)
end

local function previewQuotes(bb, x, y, w, h)
    local t, size = psc(1.5), psc(5)
    -- marquinha simples (duas tracinhos em diagonal) em cada ponta, no lugar das
    -- aspas de verdade (essas usam uma fonte própria — não vale a pena só pra prévia)
    for _, edge in ipairs({ x, x + w - size }) do
        bb:paintRect(edge, y, t, size, GRAY)
        bb:paintRect(edge + size - t, y, t, size, GRAY)
    end
end

local function previewUnderline(bb, x, y, w, h)
    local th = psc(1.5)
    bb:paintRect(x, y + h - th, w, th, BLACK)
end

-- before: desenhado antes do texto (fundo); after: depois (por cima)
-- Essas três calculam a posição a partir de h assumindo a folga abaixo do texto que
-- uma linha de verdade tem na página (entrelinha) — numa caixa de botão, sem essa
-- folga, acabam caindo em cima das próprias letras. Dá uma folga extra só pra elas,
-- empurrando o desenho pra baixo da caixa (no espaço entre as linhas da grade).
local EXTRA_BOTTOM_ROOM = { stars = true, wavy = true, double_underline = true }

local function previewFnsFor(key)
    local fn = style_paint[key]
    if fn then
        if key == "invert" then
            return nil, function(bb, x, y, w, h) fn(bb, x, y, w, h, BLACK, { color = BLACK }) end
        end
        if EXTRA_BOTTOM_ROOM[key] then
            local extra = psc(5)
            return nil, function(bb, x, y, w, h) fn(bb, x, y, w, h + extra, BLACK) end
        end
        return nil, function(bb, x, y, w, h) fn(bb, x, y, w, h, BLACK) end
    end
    -- Clareado: o texto já foi desenhado no próprio buffer interno do widget (fundo
    -- branco opaco), então um "antes" não sobreviveria — em vez disso, multiplica um
    -- tom claro por cima DEPOIS do texto, igual o destaque de verdade faz na página.
    local function tint(bb, x, y, w, h) bb:multiplyRectRGB(x, y, w, h, PREVIEW_FILL) end
    if key == "lighten" then
        return nil, tint
    end
    if key == "lighten_underline" then
        return nil, function(bb, x, y, w, h) tint(bb, x, y, w, h); previewUnderline(bb, x, y, w, h) end
    end
    if key == "lighten_rounded" then
        local border = style_paint.rounded_box
        return nil, function(bb, x, y, w, h)
            tint(bb, x, y, w, h)
            if border then border(bb, x, y, w, h, BLACK) end
        end
    end
    if key == "dashed_box" then return nil, previewDashedBorder end
    if key == "brackets" then return nil, previewBrackets end
    if key == "quotes" then return nil, previewQuotes end
    if key == "underscore" then return nil, previewUnderline end -- "Underline" nativo do KOReader
    return nil, nil
end

-- Troca só o método paintTo da instância (sem precisar recriar o widget): desenha a
-- decoração antes e/ou depois do texto normal. Idempotente — seguro de chamar de novo
-- no mesmo widget (ex.: se o botão for reconstruído mais de uma vez).
local function decoratePreview(widget, key)
    if not widget or widget._style_preview_patched then return end
    local before_fn, after_fn = previewFnsFor(key)
    if not before_fn and not after_fn then return end
    widget._style_preview_patched = true
    local orig_paintTo = widget.paintTo
    widget.paintTo = function(self, bb, x, y)
        if before_fn then
            local size = self:getSize()
            local ok, err = pcall(before_fn, bb, x, y, size.w, size.h)
            if not ok then logger.warn("2-highlights: erro na previa de estilo (fundo)", err) end
        end
        orig_paintTo(self, bb, x, y)
        if after_fn then
            local size = self:getSize()
            local ok, err = pcall(after_fn, bb, x, y, size.w, size.h)
            if not ok then logger.warn("2-highlights: erro na previa de estilo (decoracao)", err) end
        end
    end
end

-- Aplica a prévia a cada botão da grade de estilo que corresponda a uma chave
-- conhecida; chamado depois de equalizeButtonFontSizes, pra pegar o widget final
-- (seja o original do Button, seja o reconstruído pra igualar o tamanho da fonte)
local function applyStylePreviews(buttontable)
    if not stylePreviewEnabled() then return end
    if not buttontable or not buttontable.button_by_id then return end
    for key, button in pairs(buttontable.button_by_id) do
        if style_defaults[key] and button.label_widget then
            decoratePreview(button.label_widget, key)
        end
    end
end

-- Acha a linha de um botão pelo texto exato (usado pra achar onde encaixar o botão do
-- guia nos dois lugares em que ele aparece)
local function findButtonRow(buttons, text)
    for i, row in ipairs(buttons) do
        for _, btn in ipairs(row) do
            if btn.text == text then return i end
        end
    end
end

local function guideButtonRow(dialog)
    return {
        { text = "ℹ " .. _("Marker guide"), callback = function()
            UIManager:close(dialog)
            showMarkerGuide()
        end },
    }
end

-- ButtonSelector.init ends by calling this with its one-button rows: they're regrouped
-- here, right before the buttons are created
local orig_dialog_init = ButtonDialog.init
ButtonDialog.init = function(self, ...)
    if self._grid_columns then
        -- escolha de estilo: acrescenta uma linha inteira pro guia, abaixo da grade
        if self._grid_columns == CONFIG.picker_columns.styles then
            table.insert(self.buttons, guideButtonRow(self))
        end
        if self._grid_columns > 1 and #self.values > self._grid_columns then
            arrangeInGrid(self, self._grid_columns)
        end
        building_picker = true
        local ok, err = pcall(orig_dialog_init, self, ...)
        if ok then
            local ok2, min_size_or_err = pcall(equalizeButtonFontSizes, self.buttontable)
            if not ok2 then
                logger.warn("2-highlights: erro ao igualar tamanho de fonte dos botoes", min_size_or_err)
            end
            if self._grid_columns == CONFIG.picker_columns.styles then
                if ok2 then
                    local ok2b, err2b = pcall(alignStyleButtonIcons, self.buttontable, min_size_or_err)
                    if not ok2b then
                        logger.warn("2-highlights: erro ao alinhar icones dos botoes de estilo", err2b)
                    end
                end
                local ok3, err3 = pcall(applyStylePreviews, self.buttontable)
                if not ok3 then
                    logger.warn("2-highlights: erro ao aplicar previa de estilo", err3)
                end
            end
        end
        building_picker = false
        if not ok then error(err, 0) end
        return
    end
    -- diálogo "Filter by bookmark type" (ícone ☰ no topo da lista de destaques):
    -- acrescenta o acesso ao guia junto dos outros filtros de estilo/cor
    if self.buttons then
        local idx = findButtonRow(self.buttons, _("Filter by highlight color"))
        if idx then
            table.insert(self.buttons, idx + 1, guideButtonRow(self))
        end
    end
    return orig_dialog_init(self, ...)
end

------------------------------------------------------------------------
-- Filtering the highlight list
------------------------------------------------------------------------

-- Removes items whose field differs from value from the open list and refreshes it
local function keepOnly(bookmark, field, value, flag)
    local item_table = bookmark.bookmark_menu[1].item_table
    for i = #item_table, 1, -1 do
        if item_table[i][field] ~= value then
            table.remove(item_table, i)
        end
    end
    bookmark[flag] = value
    bookmark:updateBookmarkList(item_table)
end

-- Shows the color picker and filters the open list; on_done runs afterwards
function ReaderBookmark:pickHighlightColor(on_done)
    UIManager:show(ButtonSelector:new {
        current_value = self.show_color_only,
        values = self.ui.highlight.highlight_colors,
        bg_colors = self.ui.highlight:getHighlightColorList(),
        callback = function(value)
            keepOnly(self, "color", value, "show_color_only")
            if on_done then on_done() end
        end,
    })
end

-- Shows the style picker and filters the open list; on_done runs afterwards
function ReaderBookmark:pickHighlightStyle(on_done)
    UIManager:show(ButtonSelector:new {
        current_value = self.show_drawer_only,
        values = ReaderHighlight.getHighlightStyles(),
        callback = function(value)
            keepOnly(self, "drawer", value, "show_drawer_only")
            if on_done then on_done() end
        end,
    })
end

-- Opens the highlight list and runs the filter picker right after
function ReaderBookmark:openFilteredList(picker)
    self:onShowBookmark()
    UIManager:scheduleIn(0.1, picker)
end

-- The action ids are the ones gestures were bound to before styles carried the meaning:
-- "filter_highlights_category" now filters by style, "filter_highlights_style" by color,
-- so a gesture that used to filter by meaning still does.

-- Gesture action: filter by style
function ReaderBookmark:onFilterHighlightsByCategory()
    self:openFilteredList(function() self:pickHighlightStyle() end)
    return true
end

-- Gesture action: filter by color
function ReaderBookmark:onFilterHighlightsByStyle()
    self:openFilteredList(function() self:pickHighlightColor() end)
    return true
end

-- Gesture action: filter by style, then by color
function ReaderBookmark:onFilterHighlightsByCategoryAndStyle()
    self:openFilteredList(function()
        self:pickHighlightStyle(function() self:pickHighlightColor() end)
    end)
    return true
end

Dispatcher:registerAction("filter_highlights_category", {
    category = "none", event = "FilterHighlightsByCategory",
    title = "Filter highlights by style", reader = true,
})
Dispatcher:registerAction("filter_highlights_style", {
    category = "none", event = "FilterHighlightsByStyle",
    title = "Filter highlights by color", reader = true,
})
Dispatcher:registerAction("filter_highlights_category_style", {
    category = "none", event = "FilterHighlightsByCategoryAndStyle",
    title = "Filter highlights by style and color", reader = true, separator = true,
})

------------------------------------------------------------------------
-- Tools → More tools → Highlight labels: rename colors and style meanings
------------------------------------------------------------------------

-- Opens a text box to rename a color or style; empty text goes back to the default
local function renameDialog(title, current, on_save)
    local dialog
    dialog = InputDialog:new {
        title = title,
        input = current or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            -- Limpa e volta ao padrão de uma vez, sem depender de apagar o campo manualmente
            { text = _("Reset"), callback = function()
                UIManager:close(dialog)
                on_save("")
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                UIManager:close(dialog)
                on_save(dialog:getInputText())
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- One menu entry per color: "Red: <name>"
local function colorMenuItems()
    local items = {}
    for _, c in ipairs(CONFIG.colors) do
        table.insert(items, {
            text_func = function() return T("%1: %2", titleCase(c.key), colorLabel(c.key)) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                renameDialog(T("Name for %1", titleCase(c.key)), colorLabel(c.key), function(text)
                    setSavedLabel("color", c.key, text)
                    refreshLabels()
                    touchmenu_instance:updateItems()
                end)
            end,
        })
    end
    return items
end

-- One menu entry per style: "Box: <meaning>"
local function styleMenuItems()
    local items = {}
    for _, s in ipairs(CONFIG.styles) do
        table.insert(items, {
            text_func = function() return T("%1: %2", s.name, styleMeaning(s.key) or "—") end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                renameDialog(T("Meaning for %1", s.name), styleMeaning(s.key), function(text)
                    setSavedLabel("style", s.key, text)
                    refreshLabels()
                    touchmenu_instance:updateItems()
                end)
            end,
        })
    end
    return items
end

local HighlightLabels = WidgetContainer:extend { name = "highlight_labels" }

-- Registers the menu entry
function HighlightLabels:init()
    self.ui.menu:registerToMainMenu(self)
end

-- Adds Tools → More tools → Highlight labels
function HighlightLabels:addToMainMenu(menu_items)
    menu_items.highlight_labels = {
        text = "Highlight labels",
        sorting_hint = "more_tools",
        sub_item_table = {
            { text = "Colors", sub_item_table_func = colorMenuItems },
            { text = "Styles", sub_item_table_func = styleMenuItems },
            {
                text = "Preview style on names",
                checked_func = stylePreviewEnabled,
                callback = function()
                    G_reader_settings:saveSetting("highlight_style_preview", not stylePreviewEnabled())
                end,
            },
        },
    }
end

-- Registers the module in every opened book
local orig_init = ReaderUI.init
ReaderUI.init = function(self, ...)
    orig_init(self, ...)
    self:registerModule("highlight_labels", HighlightLabels:new { ui = self })
end
