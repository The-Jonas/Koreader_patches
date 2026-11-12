--[[
    2-highlight-styles.lua
    Patch de usuário para o KOReader: adiciona vários estilos de destaque.

    Instalação: copie este arquivo para  koreader/patches/  e reinicie o KOReader.
    Os estilos aparecem junto dos nativos (menu de estilo do destaque).

    Estilos adicionados:
      wavy              sublinhado ondulado
      double_underline  sublinhado duplo
      dashed            sublinhado tracejado
      dotted            sublinhado pontilhado
      stars             linha de estrelinhas embaixo do texto
      marker            marca-texto grosso embaixo (cinza)
      box               caixa (com folga nas laterais)
      rounded_box       caixa com cantos arredondados (com folga nas laterais)
      brackets          colchetes [ ] só no início e no fim do trecho
      quotes            aspas “ ” cinza, grandes, afastadas do texto (não confunde com as do livro)
      bold              negrito (falso, engrossa o texto já desenhado)
      italic            itálico (falso, inclina o texto já desenhado)
      bold_italic       negrito + itálico
      lighten_underline clareado + sublinhado
      lighten_rounded   clareado + caixa arredondada

    Também:
      invert            inverte o trecho e mantém uma faixa da cor embaixo
      cores escuras     no clareado (e combinações), texto branco sobre a cor
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local ReaderView = require("apps/reader/modules/readerview")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local RenderText = require("ui/rendertext")
local logger = require("logger")

local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY or BLACK
local LIGHT_GRAY = Blitbuffer.COLOR_GRAY or GRAY

local NONE_DRAWER = "__patch_none__" -- usado só para o original desenhar a marca de nota

local function sc(n)
    return math.max(1, Screen:scaleBySize(n))
end

-- espaço extra lateral (caixa, colchetes, aspas)
local function pad()
    return sc(3)
end

-- folga lateral só das aspas
local function quotePad()
    return sc(1.5)
end

-- Rastreador de grupos: o destaque chega em retângulos (um por linha).
-- Retângulos consecutivos formam um grupo; o desenho de "abertura" sai no
-- primeiro e o de "fechamento" é feito no fim do paintTo, no último retângulo.
local group = { last = nil }

local function flushGroup()
    local p = group.last
    group.last = nil
    if p and p.close then p.close(p) end
end

-- retorna true se este retângulo inicia um novo grupo
local function trackRect(bb, x, y, w, h, close, color)
    local p = group.last
    local continues = false
    if p and p.bb == bb and p.close == close then
        local same_line = math.abs(y - p.y) < p.h * 0.5 and x >= p.x
        local next_line = y > p.y and (y - p.y) <= p.h * 2 and x < p.x + p.w
        continues = same_line or next_line
    end
    if not continues then flushGroup() end
    group.last = { bb = bb, x = x, y = y, w = w, h = h, close = close, color = color }
    return not continues
end

-- A cor chega aqui já convertida pelo núcleo (readerview.lua transforma o nome salvo
-- em cor do Blitbuffer antes de chamar drawHighlightRect), então é usada como veio.
local function strokeColor(color)
    return color or BLACK
end

-- Cores escuras (preto, marrom, azul, roxo do 2-highlights.lua): o clareado normal
-- multiplica a cor sobre a página e o texto preto some no fundo escuro. Nelas o fundo
-- vira a cor e o texto fica branco. Mesmo limite do 2-highlights.lua (dark_level), que
-- também deixa branco o texto dos botões dessas cores.
local DARK_LEVEL = 0x80

local function isDark(color)
    if not color then return false end
    local ok, gray = pcall(function() return color:getColor8().a end)
    return ok and gray < DARK_LEVEL
end

------------------------------------------------------------------------
-- Estilos
------------------------------------------------------------------------
local styles = {}
local order = {} -- { {label, key}, ... }

local function add(key, label, fn)
    styles[key] = fn
    table.insert(order, { label, key })
end

local function underline(bb, x, y, w, h, c)
    local th = sc(1)
    bb:paintRect(x, y + h - th, w, th, c)
end

local function roundedBox(bb, x, y, w, h, c)
    local p = pad()
    x, w = x - p, w + 2 * p
    local r = math.min(sc(5), math.floor(math.min(w, h) / 2))
    bb:paintBorder(x, y, w, h, sc(1), c, r, true)
end

-- Clareado com cor escura: multiplica pelo inverso da cor e inverte o retângulo.
-- Resultado = 255 - pixel × (255 - cor) / 255: fundo branco vira a cor, texto preto
-- vira branco (e as bordas suavizadas continuam suaves). Mesmo retângulo do núcleo.
local function darkLighten(bb, rect, color)
    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    local pct = G_reader_settings:readSetting("highlight_height_pct")
    if pct ~= nil then
        h = math.floor(h * pct / 100)
        y = y + math.ceil((rect.h - h) / 2)
    end
    bb:multiplyRectRGB(x, y, w, h, color:invert())
    bb:invertRect(x, y, w, h)
end

-- true se o clareado deste destaque deve sair com texto branco
-- (no modo noturno por software a página já está invertida: fica o desenho do núcleo)
local function useDarkLighten(bb, color)
    return isDark(color) and bb:getInverse() ~= 1
end

local function lightenOrig(ctx)
    if useDarkLighten(ctx.bb, ctx.color) then
        darkLighten(ctx.bb, ctx.rect, ctx.color)
    else
        ctx.orig(ctx.view, ctx.bb, ctx._x, ctx._y, ctx.rect, "lighten", ctx.color, false)
    end
end

-- ondulado
add("wavy", "Wavy", function(bb, x, y, w, h, c)
    local th = sc(1)
    local amp = sc(1.5)
    local period = sc(7)
    local base = y + h - amp - th
    local prev
    for i = 0, w - 1 do
        local yy = base + math.floor(amp * math.sin(2 * math.pi * i / period) + 0.5)
        local top = prev and math.min(prev, yy) or yy
        local hh = (prev and math.abs(prev - yy) or 0) + th
        bb:paintRect(x + i, top, 1, hh, c)
        prev = yy
    end
end)

-- sublinhado duplo
add("double_underline", "Double underline", function(bb, x, y, w, h, c)
    local th, gap = sc(1), sc(2)
    bb:paintRect(x, y + h - th, w, th, c)
    bb:paintRect(x, y + h - th * 2 - gap, w, th, c)
end)

-- tracejado
add("dashed", "Dashed", function(bb, x, y, w, h, c)
    local th, dash, gap = sc(1), sc(6), sc(4)
    local i = 0
    while i < w do
        bb:paintRect(x + i, y + h - th, math.min(dash, w - i), th, c)
        i = i + dash + gap
    end
end)

-- pontilhado
add("dotted", "Dotted", function(bb, x, y, w, h, c)
    local d, gap = sc(1.5), sc(2.5)
    local i = 0
    while i < w do
        bb:paintRect(x + i, y + h - d, math.min(d, w - i), d, c)
        i = i + d + gap
    end
end)

-- invertido, mas com uma faixa colorida embaixo: o nativo "invert" ignora a cor por completo
-- (só inverte os pixels), então a categoria some visualmente mesmo continuando salva. Registrar
-- a chave "invert" aqui assume o lugar do original e mantém a categoria visível.
add("invert", "Invert", function(bb, x, y, w, h, c)
    bb:invertRect(x, y, w, h)
    local t = sc(3)
    bb:paintRect(x, y + h - t, w, t, c)
end)

-- marca-texto grosso embaixo
add("marker", "Marker underline", function(bb, x, y, w, h, c)
    local t = sc(4)
    local color = (c ~= BLACK) and c or LIGHT_GRAY
    bb:paintRect(x, y + h - t, w, t, color)
end)

-- caixa
add("box", "Box", function(bb, x, y, w, h, c)
    local p = pad()
    bb:paintBorder(x - p, y, w + 2 * p, h, sc(1), c)
end)

-- caixa arredondada
add("rounded_box", "Rounded box", function(bb, x, y, w, h, c)
    roundedBox(bb, x, y, w, h, c)
end)

-- colchetes (só no início e no fim do trecho marcado)
local function bracketClose(p)
    local t, serif = sc(1), sc(4)
    local edge = p.x + p.w + pad()
    p.bb:paintRect(edge - t, p.y, t, p.h, p.color)
    p.bb:paintRect(edge - serif, p.y, serif, t, p.color)
    p.bb:paintRect(edge - serif, p.y + p.h - t, serif, t, p.color)
end

add("brackets", "Brackets", function(bb, x, y, w, h, c)
    if trackRect(bb, x, y, w, h, bracketClose, c) then
        local t, serif = sc(1), sc(4)
        local lx = x - pad()
        bb:paintRect(lx, y, t, h, c)
        bb:paintRect(lx, y, serif, t, c)
        bb:paintRect(lx, y + h - t, serif, t, c)
    end
end)

-- pontilhado de estrelinhas
local STAR = {
    "...#...",
    "...#...",
    "#######",
    ".#####.",
    "..###..",
    ".##.##.",
    ".#...#.",
}

local function drawStar(bb, x, y, cell, c)
    for r, row in ipairs(STAR) do
        for col = 1, #row do
            if row:sub(col, col) == "#" then
                bb:paintRect(x + (col - 1) * cell, y + (r - 1) * cell, cell, cell, c)
            end
        end
    end
end

add("stars", "Stars", function(bb, x, y, w, h, c)
    local cell = math.max(1, math.floor(sc(6) / #STAR + 0.5))
    local size = cell * #STAR
    local gap = sc(3)
    local count = math.floor((w + gap) / (size + gap))
    if count < 1 then
        if w >= size then count = 1 else return end
    end
    local total = count * size + (count - 1) * gap
    local start = x + math.floor((w - total) / 2)
    local top = y + h - size
    for i = 0, count - 1 do
        drawStar(bb, start + i * (size + gap), top, cell, c)
    end
end)

-- negrito / itálico (falsos: manipulam os pixels do texto já desenhado)
local function clipRegion(bb, x, y, w, h)
    local x0, y0 = math.max(0, x), math.max(0, y)
    local x1, y1 = math.min(bb:getWidth(), x + w), math.min(bb:getHeight(), y + h)
    return x0, y0, x1 - x0, y1 - y0
end

local function fauxBold(bb, x, y, w, h)
    local x0, y0, cw, ch = clipRegion(bb, x, y, w, h)
    if cw <= 2 or ch <= 0 then return end
    local copy = Blitbuffer.new(cw, ch, bb:getType())
    copy:blitFrom(bb, 0, 0, x0, y0, cw, ch)
    for j = 0, ch - 1 do
        for i = 1, cw - 1 do
            local src = copy:getPixel(i - 1, j)
            local dst = bb:getPixel(x0 + i, y0 + j)
            if src:getColor8().a < dst:getColor8().a then
                bb:setPixel(x0 + i, y0 + j, src)
            end
        end
    end
    copy:free()
end

local function fauxItalic(bb, x, y, w, h)
    local x0, y0, cw, ch = clipRegion(bb, x, y, w, h)
    if cw <= 2 or ch <= 0 then return end
    local copy = Blitbuffer.new(cw, ch, bb:getType())
    copy:blitFrom(bb, 0, 0, x0, y0, cw, ch)
    bb:paintRect(x0, y0, cw, ch, WHITE)
    local slope = 0.2
    local pivot = ch * 0.72 -- aproximadamente a linha de base
    for j = 0, ch - 1 do
        local shift = math.floor((pivot - j) * slope + 0.5)
        if shift >= 0 then
            if cw - shift > 0 then
                bb:blitFrom(copy, x0 + shift, y0 + j, 0, j, cw - shift, 1)
            end
        else
            if cw + shift > 0 then
                bb:blitFrom(copy, x0, y0 + j, -shift, j, cw + shift, 1)
            end
        end
    end
    copy:free()
end

add("bold", "Bold", function(bb, x, y, w, h)
    fauxBold(bb, x, y, w, h)
end)

add("italic", "Italic", function(bb, x, y, w, h)
    fauxItalic(bb, x, y, w, h)
end)

add("bold_italic", "Bold + italic", function(bb, x, y, w, h)
    fauxItalic(bb, x, y, w, h)
    fauxBold(bb, x, y, w, h)
end)

-- combinações com clareado
add("lighten_underline", "Lighten + underline", function(bb, x, y, w, h, c, ctx)
    lightenOrig(ctx)
    underline(bb, x, y, w, h, c)
end)

add("lighten_rounded", "Lighten + rounded box", function(bb, x, y, w, h, c, ctx)
    lightenOrig(ctx)
    roundedBox(bb, x, y, w, h, c)
end)

------------------------------------------------------------------------
-- Aspas ao redor
-- O destaque chega em retângulos (um por linha). Agrupamos os retângulos
-- consecutivos: a aspa de abertura sai no primeiro e a de fechamento é
-- desenhada no fim do paintTo, no último retângulo do grupo.
------------------------------------------------------------------------
local OPEN, CLOSE = "\u{201C}", "\u{201D}"
local face_cache = {}

local function quoteFace(h)
    local dp = math.max(10, math.floor(h / math.max(1, Screen:scaleBySize(1)) * 1.2))
    if not face_cache[dp] then
        face_cache[dp] = Font:getFace("cfont", dp)
    end
    return face_cache[dp]
end

local function glyphWidth(face, text)
    local ok, size = pcall(RenderText.sizeUtf8Text, RenderText, 0, Screen:getWidth(), face, text, true, true)
    if ok and size and size.x then return size.x end
    return face.size or 12
end

local function drawGlyph(bb, text, x, baseline, face)
    pcall(RenderText.renderUtf8Text, RenderText, bb, math.max(0, x), baseline, face, text, true, true, GRAY)
end

local function quoteClose(p)
    local face = quoteFace(p.h)
    drawGlyph(p.bb, CLOSE, p.x + p.w + quotePad(), p.y + math.floor(p.h * 0.75), face)
end

add("quotes", "Quotes", function(bb, x, y, w, h)
    if trackRect(bb, x, y, w, h, quoteClose) then
        local face = quoteFace(h)
        local qw = glyphWidth(face, OPEN)
        drawGlyph(bb, OPEN, x - qw - quotePad(), y + math.floor(h * 0.75), face)
    end
end)

------------------------------------------------------------------------
-- Ganchos no ReaderView
------------------------------------------------------------------------
local orig_drawHighlightRect = ReaderView.drawHighlightRect

ReaderView.drawHighlightRect = function(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
    if drawer == "lighten" and useDarkLighten(bb, color) then
        darkLighten(bb, rect, color)
        if draw_note_mark then
            pcall(orig_drawHighlightRect, self, bb, _x, _y, rect, NONE_DRAWER, color, draw_note_mark)
        end
        return
    end
    local fn = styles[drawer]
    if not fn then
        return orig_drawHighlightRect(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
    end
    local x, y, w, h = (_x or 0) + rect.x, (_y or 0) + rect.y, rect.w, rect.h
    local ctx = {
        view = self, bb = bb, _x = _x, _y = _y, rect = rect, color = color,
        orig = orig_drawHighlightRect,
    }
    local ok, err = pcall(fn, bb, x, y, w, h, strokeColor(color), ctx)
    if not ok then
        logger.warn("2-highlight-styles: erro ao desenhar estilo", drawer, err)
    end
    if draw_note_mark then
        -- deixa o original desenhar apenas a marca de nota
        pcall(orig_drawHighlightRect, self, bb, _x, _y, rect, NONE_DRAWER, color, draw_note_mark)
    end
end

local orig_paintTo = ReaderView.paintTo
ReaderView.paintTo = function(self, bb, x, y)
    group.last = nil
    local ret = orig_paintTo(self, bb, x, y)
    flushGroup()
    return ret
end

------------------------------------------------------------------------
-- Registro dos estilos no menu do ReaderHighlight
-- A lista de estilos é uma tabela local do módulo; localizamos ela pelos
-- upvalues das funções (procurando a que contém "underscore").
------------------------------------------------------------------------
local function findEntryShape(t)
    -- retorna "array_label_key", "array_key_label" ou "map"
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

local function exists(t, shape, key)
    if shape == "map" then return t[key] ~= nil end
    for _, e in ipairs(t) do
        if type(e) == "table" and (e[2] == key or e[1] == key) then return true end
    end
    return false
end

local style_table, shape = findStyleTable()
if style_table then
    for _, item in ipairs(order) do
        local label, key = item[1], item[2]
        if not exists(style_table, shape, key) then
            if shape == "map" then
                style_table[key] = label
            elseif shape == "array_label_key" then
                table.insert(style_table, { label, key })
            else
                table.insert(style_table, { key, label })
            end
        end
    end
else
    logger.warn("2-highlight-styles: tabela de estilos do ReaderHighlight não encontrada; estilos novos só funcionam se já estiverem salvos")
end
