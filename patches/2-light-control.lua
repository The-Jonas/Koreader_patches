--[[
2-light-control.lua — easier brightness and warmth: visible slider, absolute edge swipes, presets

Goal: change the frontlight and its warmth without guessing — see the level while
adjusting, put the finger where you want the level to be, and jump to a saved
light setup with one tap.

What it does:
  - Edge swipes become absolute: swiping along the left edge (brightness) or the
    right edge (warmth) sets the level to where the finger stops — top of the
    screen is the maximum, bottom the minimum — instead of nudging it a few steps.
  - A large slider appears on that edge with the current level. Tap or drag on it
    to fine-tune; it closes by itself after a few seconds or with a tap elsewhere.
  - Light presets (brightness + warmth together), applied with one tap from
    Settings → Light presets or from the light panel. Four come ready (Day,
    Evening, Night, Dark); the current light can be saved as a new one, and
    holding a preset lets you change its values, rename it or remove it.
  - "Light panel" gesture action: both sliders side by side plus the presets.
  - Automatic presets: a schedule of times, each starting a preset that lasts
    until the next time (one preset per time, so they never overlap). The preset
    is applied when its time arrives or when the device wakes up in a new period;
    changing the light by hand keeps your choice until the next time on the
    schedule. Optionally the light blends into the next preset gradually.

Usage:
  1. Copy this file to koreader/patches/ and restart KOReader.
  2. Swipe up or down along the left edge (brightness) or the right edge (warmth),
     KOReader's default light gestures. To use other gestures, assign the usual
     "Increase/Decrease frontlight brightness/warmth" actions to them.
  3. Presets and options (absolute swipes, slider on/off, how long it stays):
     Settings → Light presets. The schedule is in Light presets → Automatic presets. To open the light panel with a
     gesture, assign "Light panel" in Taps and gestures → Gesture manager.
]]

local CONFIG = {
    absolute_swipes = true, -- edge swipes set the level where the finger stops
    show_slider = true,     -- show the slider after a light gesture
    slider_seconds = 3,     -- seconds without touching before the slider closes
    auto = false,           -- follow the schedule below
    gradual = false,        -- blend into the next preset instead of switching at once
    gradual_minutes = 30,   -- how long the blend takes, ending at the scheduled time
    -- Schedule: from each time on, until the next one, that preset applies
    schedule = {
        { time = "07:00", preset = "Day" },
        { time = "18:00", preset = "Evening" },
        { time = "22:00", preset = "Night" },
    },
    -- Presets ready on first use: brightness and warmth in percent
    presets = {
        { name = "Day", brightness = 60, warmth = 0 },
        { name = "Evening", brightness = 35, warmth = 50 },
        { name = "Night", brightness = 12, warmth = 90 },
        { name = "Dark", brightness = 3, warmth = 100 },
    },
}

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

if not Device:hasFrontlight() then return end

local Screen = Device.screen
local DeviceListener = require("device/devicelistener")
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local MUTED, TRACK = Blitbuffer.Color8(0x66), Blitbuffer.Color8(0xDD)

local editPreset

-- Saved options, presets and schedule, falling back to CONFIG
local function store()
    local s = G_reader_settings:readSetting("light_control") or {}
    if s.presets == nil then s.presets = util.tableDeepCopy(CONFIG.presets) end
    if s.absolute_swipes == nil then s.absolute_swipes = CONFIG.absolute_swipes end
    if s.show_slider == nil then s.show_slider = CONFIG.show_slider end
    if s.slider_seconds == nil then s.slider_seconds = CONFIG.slider_seconds end
    if s.schedule == nil then s.schedule = util.tableDeepCopy(CONFIG.schedule) end
    if s.auto == nil then s.auto = CONFIG.auto end
    if s.gradual == nil then s.gradual = CONFIG.gradual end
    if s.gradual_minutes == nil then s.gradual_minutes = CONFIG.gradual_minutes end
    return s
end

-- Writes options and presets back to the settings
local function save(s)
    G_reader_settings:saveSetting("light_control", s)
end

---------------------------------------------------------------- light levels

local powerd = Device:getPowerDevice()
local has_warmth = Device:hasNaturalLight()

-- Brightness as a fraction from 0 (off) to 1
local function getBrightness()
    if not powerd:isFrontlightOn() then return 0 end
    return powerd:frontlightIntensity() / powerd.fl_max
end

-- Sets brightness from a fraction; 0 turns the light off
local function setBrightness(f)
    local level = math.floor(math.max(0, math.min(1, f)) * powerd.fl_max + 0.5)
    if level <= 0 then
        powerd:turnOffFrontlight()
    else
        if not powerd:isFrontlightOn() then powerd:turnOnFrontlight() end
        powerd:setIntensity(level)
    end
    powerd:updateResumeFrontlightState()
end

-- Warmth as a fraction from 0 (cold) to 1 (warmest)
local function getWarmth()
    return powerd:frontlightWarmth() / 100
end

-- Sets warmth from a fraction, in the device's own steps
local function setWarmth(f)
    local native = math.floor(math.max(0, math.min(1, f)) * powerd.fl_warmth_max + 0.5)
    powerd:setWarmth(powerd:fromNativeWarmth(native))
end

-- "12 / 24" in the device's own steps
local function levelText(kind)
    if kind == "warmth" then
        return T("%1 / %2", powerd:toNativeWarmth(powerd:frontlightWarmth()), powerd.fl_warmth_max)
    end
    if not powerd:isFrontlightOn() then return "Off" end
    return T("%1 / %2", powerd:frontlightIntensity(), powerd.fl_max)
end

-- Applies a preset (brightness and warmth in percent)
local function applyPreset(p)
    setBrightness(p.brightness / 100)
    if has_warmth then setWarmth(p.warmth / 100) end
end

---------------------------------------------------------------- drawing helpers

-- Pixels for a size given at 160 dpi
local function px(v) return Screen:scaleBySize(v) end

-- One line of text centered in width w (or left-aligned without w)
local function drawText(bb, str, x, y, size, opts)
    opts = opts or {}
    local tw = TextWidget:new { text = str, face = Font:getFace(opts.bold and "tfont" or "cfont", size),
        bold = opts.bold, fgcolor = opts.color or BLACK, max_width = opts.w }
    local s = tw:getSize()
    tw:paintTo(bb, opts.w and x + math.floor((opts.w - s.w) / 2) or x, y)
    tw:free()
    return s.h
end

-- Vertical slider: rounded track filled from the bottom, with a knob at the level
local function drawSlider(bb, x, y, w, h, fraction)
    local r = math.floor(w / 2)
    bb:paintRoundedRect(x, y, w, h, TRACK, r)
    local fh = math.floor(h * math.max(0, math.min(1, fraction)))
    if fh > 0 then bb:paintRoundedRect(x, y + h - math.max(fh, w), w, math.max(fh, w), BLACK, r) end
    bb:paintBorder(x, y, w, h, px(1.5), BLACK, r)
    local ky = y + h - fh
    bb:paintRoundedRect(x - px(6), ky - px(5), w + px(12), px(10), WHITE, px(5))
    bb:paintBorder(x - px(6), ky - px(5), w + px(12), px(10), px(2), BLACK, px(5))
end

-- Fraction for a touch at height ty on a slider spanning y..y+h
local function fractionAt(ty, y, h)
    return math.max(0, math.min(1, (y + h - ty) / h))
end

---------------------------------------------------------------- edge slider

local EdgeSlider = InputContainer:extend {
    kind = "brightness", -- or "warmth"
}

-- Covers the screen to catch touches; only the panel on one edge is drawn
function EdgeSlider:init()
    self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local pw = math.floor(self.dimen.w * 0.2)
    self.panel = Geom:new { x = self.kind == "warmth" and self.dimen.w - pw - px(10) or px(10),
        y = math.floor(self.dimen.h * 0.1), w = pw, h = math.floor(self.dimen.h * 0.8) }
    self.track = Geom:new { x = self.panel.x + math.floor((pw - px(34)) / 2), y = self.panel.y + px(90),
        w = px(34), h = self.panel.h - px(130) }
    self.ges_events = {
        Touch = { GestureRange:new { ges = "tap", range = self.dimen } },
        Pan = { GestureRange:new { ges = "pan", range = self.dimen } },
        Swipe = { GestureRange:new { ges = "swipe", range = self.dimen } },
    }
    self:keepOpen()
end

-- Restarts the countdown that closes the slider
function EdgeSlider:keepOpen()
    if self.close_task then UIManager:unschedule(self.close_task) end
    self.close_task = function() self:close() end
    UIManager:scheduleIn(store().slider_seconds, self.close_task)
end

-- Draws the panel with title, level and slider
function EdgeSlider:paintTo(bb)
    local p = self.panel
    bb:paintRoundedRect(p.x, p.y, p.w, p.h, WHITE, px(14))
    bb:paintBorder(p.x, p.y, p.w, p.h, px(2), BLACK, px(14))
    local warmth = self.kind == "warmth"
    drawText(bb, warmth and "Warmth" or "Brightness", p.x, p.y + px(14), 13, { w = p.w, color = MUTED, bold = true })
    drawText(bb, levelText(self.kind), p.x, p.y + px(40), 20, { w = p.w, bold = true })
    local t = self.track
    drawSlider(bb, t.x, t.y, t.w, t.h, warmth and getWarmth() or getBrightness())
    drawText(bb, warmth and "warm" or "max", p.x, t.y - px(22), 11, { w = p.w, color = MUTED })
    drawText(bb, warmth and "cold" or "off", p.x, t.y + t.h + px(8), 11, { w = p.w, color = MUTED })
end

-- Sets the level from a touch inside the panel
function EdgeSlider:setFrom(pos)
    local f = fractionAt(pos.y, self.track.y, self.track.h)
    if self.kind == "warmth" then setWarmth(f) else setBrightness(f) end
    UIManager:setDirty(self, function() return "fast", self.panel end)
    self:keepOpen()
end

-- Whether a touch falls inside the panel
function EdgeSlider:inPanel(pos)
    local p = self.panel
    return pos.x >= p.x and pos.x < p.x + p.w and pos.y >= p.y and pos.y < p.y + p.h
end

-- Tap on the panel sets the level, elsewhere closes
function EdgeSlider:onTouch(_, ges)
    if self:inPanel(ges.pos) then self:setFrom(ges.pos) else self:close() end
    return true
end

-- Dragging on the panel follows the finger
function EdgeSlider:onPan(_, ges)
    if self:inPanel(ges.pos) then self:setFrom(ges.pos) end
    return true
end
EdgeSlider.onSwipe = EdgeSlider.onPan

-- Closes the slider and repaints what was under it
function EdgeSlider:close()
    if self.close_task then UIManager:unschedule(self.close_task) end
    UIManager:close(self, "ui", self.panel)
end

local current_slider

-- Shows the slider for brightness or warmth, reusing one already open
local function showSlider(kind)
    if current_slider and current_slider.kind == kind and UIManager:isWidgetShown(current_slider) then
        UIManager:setDirty(current_slider, function() return "fast", current_slider.panel end)
        current_slider:keepOpen()
        return
    end
    if current_slider then current_slider:close() end
    current_slider = EdgeSlider:new { kind = kind }
    UIManager:show(current_slider, "fast", current_slider.panel)
end

---------------------------------------------------------------- light panel

local LightPanel = InputContainer:extend {}

-- Centered card with both sliders and the presets
function LightPanel:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local w = math.floor(sw * 0.84)
    local h = math.floor(sh * 0.62)
    self.dimen = Geom:new { x = 0, y = 0, w = sw, h = sh }
    self.card = Geom:new { x = math.floor((sw - w) / 2), y = math.floor((sh - h) / 2), w = w, h = h }
    self.ges_events = {
        Touch = { GestureRange:new { ges = "tap", range = self.dimen } },
        Pan = { GestureRange:new { ges = "pan", range = self.dimen } },
    }
end

-- Draws the card, remembering where each slider and button is
function LightPanel:paintTo(bb)
    local c = self.card
    self.hits = {}
    bb:paintRoundedRect(c.x, c.y, c.w, c.h, WHITE, px(16))
    bb:paintBorder(c.x, c.y, c.w, c.h, px(2), BLACK, px(16))
    drawText(bb, "Light", c.x + px(20), c.y + px(16), 20, { bold = true })
    local cx, cy = c.x + c.w - px(56), c.y + px(12)
    drawText(bb, "✕", cx, cy + px(4), 18, { w = px(40), bold = true })
    table.insert(self.hits, { rect = Geom:new { x = cx, y = cy, w = px(40), h = px(40) }, fn = function() self:close() end })

    local cols = has_warmth and 2 or 1
    local slider_h = math.floor(c.h * 0.48)
    local top = c.y + px(70)
    for i = 1, cols do
        local kind = i == 1 and "brightness" or "warmth"
        local colx = c.x + math.floor(c.w * (i - 0.5) / cols)
        drawText(bb, kind == "warmth" and "Warmth" or "Brightness", colx - px(80), top, 13, { w = px(160), color = MUTED, bold = true })
        drawText(bb, levelText(kind), colx - px(80), top + px(24), 18, { w = px(160), bold = true })
        local track = Geom:new { x = colx - px(20), y = top + px(66), w = px(40), h = slider_h }
        drawSlider(bb, track.x, track.y, track.w, track.h, kind == "warmth" and getWarmth() or getBrightness())
        local zone = Geom:new { x = colx - px(60), y = track.y - px(10), w = px(120), h = track.h + px(20) }
        table.insert(self.hits, { rect = zone, drag = true, fn = function(pos)
            local f = fractionAt(pos.y, track.y, track.h)
            if kind == "warmth" then setWarmth(f) else setBrightness(f) end
            self:refresh()
        end })
    end

    local presets = store().presets
    local by = top + px(66) + slider_h + px(28)
    local n = math.min(#presets, 4)
    local gap = px(10)
    local bw = math.floor((c.w - px(40) - gap * (n - 1)) / n)
    for i = 1, n do
        local p = presets[i]
        local bx = c.x + px(20) + (i - 1) * (bw + gap)
        local rect = Geom:new { x = bx, y = by, w = bw, h = px(52) }
        bb:paintRoundedRect(bx, by, bw, rect.h, WHITE, px(10))
        bb:paintBorder(bx, by, bw, rect.h, px(1.5), BLACK, px(10))
        drawText(bb, p.name, bx, by + px(5), 15, { w = bw, bold = true })
        drawText(bb, has_warmth and T("%1% · %2%", p.brightness, p.warmth) or T("%1%", p.brightness),
            bx, by + px(28), 11, { w = bw, color = MUTED })
        table.insert(self.hits, { rect = rect, fn = function() applyPreset(p) self:refresh() end })
    end
end

-- Redraws the card quickly
function LightPanel:refresh()
    UIManager:setDirty(self, function() return "fast", self.card end)
end

-- Runs the control under a touch; outside the card closes
function LightPanel:onTouch(_, ges)
    local pos = ges.pos
    for __, h in ipairs(self.hits or {}) do
        local r = h.rect
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then
            h.fn(pos)
            return true
        end
    end
    local c = self.card
    if not (pos.x >= c.x and pos.x < c.x + c.w and pos.y >= c.y and pos.y < c.y + c.h) then self:close() end
    return true
end

-- Dragging on a slider follows the finger
function LightPanel:onPan(_, ges)
    for __, h in ipairs(self.hits or {}) do
        local r = h.rect
        if h.drag and ges.pos.x >= r.x and ges.pos.x < r.x + r.w and ges.pos.y >= r.y and ges.pos.y < r.y + r.h then
            h.fn(ges.pos)
            return true
        end
    end
    return true
end

-- Closes the panel
function LightPanel:close()
    UIManager:close(self, "ui", self.card)
end

-- Opens the light panel
local function showPanel()
    local panel = LightPanel:new {}
    UIManager:show(panel, "ui", panel.card)
end

---------------------------------------------------------------- gestures

-- Light level for the point where an edge swipe ended
local function swipeEnd(ges)
    if type(ges) ~= "table" or ges.ges ~= "swipe" or not ges.pos or not ges.distance then return end
    local dy = ges.direction == "north" and -ges.distance or ges.direction == "south" and ges.distance or nil
    if not dy then return end
    return 1 - math.max(0, math.min(1, (ges.pos.y + dy) / Screen:getHeight()))
end

-- Wraps a light gesture: absolute level from the swipe, then the slider
local function wrapGesture(name, kind, set)
    local orig = DeviceListener[name]
    if not orig then return end
    DeviceListener[name] = function(self, ges, ...)
        local s = store()
        local f = s.absolute_swipes and swipeEnd(ges)
        if f then
            set(f)
        elseif s.show_slider then
            local Notification = require("ui/widget/notification")
            local orig_notify = Notification.notify
            Notification.notify = function() end
            orig(self, ges, ...)
            Notification.notify = orig_notify
        else
            return orig(self, ges, ...)
        end
        if s.show_slider then showSlider(kind) end
        return true
    end
end

wrapGesture("onIncreaseFlIntensity", "brightness", setBrightness)
wrapGesture("onDecreaseFlIntensity", "brightness", setBrightness)
if has_warmth then
    wrapGesture("onIncreaseFlWarmth", "warmth", setWarmth)
    wrapGesture("onDecreaseFlWarmth", "warmth", setWarmth)
end

Dispatcher:registerAction("light_panel", {
    category = "none", event = "ShowLightPanel", title = "Light panel", screen = true,
})
DeviceListener.onShowLightPanel = function() showPanel() return true end

---------------------------------------------------------------- schedule

-- Minutes since midnight for "HH:MM"
local function toMinutes(hhmm)
    local h, m = hhmm:match("^(%d+):(%d+)$")
    return tonumber(h) * 60 + tonumber(m)
end

-- Schedule entries sorted by time
local function sortedSchedule(s)
    local list = util.tableDeepCopy(s.schedule)
    table.sort(list, function(a, b) return toMinutes(a.time) < toMinutes(b.time) end)
    return list
end

-- Preset with the given name, or nil
local function findPreset(s, name)
    for __, p in ipairs(s.presets) do
        if p.name == name then return p end
    end
end

-- The period running now: its entry, a key unique to this start, and the next entry
-- with the minutes left until it
local function currentPeriod(s)
    local list = sortedSchedule(s)
    if #list == 0 then return end
    local now = os.time()
    local t = os.date("*t", now)
    local mins = t.hour * 60 + t.min
    local idx, day = #list, now - 86400
    for i = #list, 1, -1 do
        if toMinutes(list[i].time) <= mins then idx, day = i, now break end
    end
    local entry = list[idx]
    local nxt = list[idx % #list + 1]
    local to_next = (toMinutes(nxt.time) - mins) % 1440
    if to_next == 0 then to_next = 1440 end
    return entry, os.date("%Y-%m-%d ", day) .. entry.time, nxt, to_next
end

local last_set -- light values the schedule set last, to notice manual changes

-- Current light in percent
local function currentLight()
    return { brightness = math.floor(getBrightness() * 100 + 0.5), warmth = math.floor(getWarmth() * 100 + 0.5) }
end

-- Sets the light to the given percentages and remembers them
local function setLight(v)
    setBrightness(v.brightness / 100)
    if has_warmth then setWarmth(v.warmth / 100) end
    last_set = currentLight()
end

-- Whether the light was changed by hand since the schedule last set it
local function changedByHand()
    if not last_set then return false end
    local now = currentLight()
    return math.abs(now.brightness - last_set.brightness) > 2 or math.abs(now.warmth - last_set.warmth) > 2
end

-- Applies the schedule: the preset of a new period once, and the gradual blend before the next one
local function checkSchedule()
    local s = store()
    if not s.auto then return end
    local entry, key, nxt, to_next = currentPeriod(s)
    if not entry then return end
    if s.applied_key ~= key then
        local p = findPreset(s, entry.preset)
        s.applied_key, s.blend_from = key, nil
        save(s)
        if p then setLight(p) end
        return
    end
    if not s.gradual or to_next > s.gradual_minutes then return end
    local target = findPreset(s, nxt.preset)
    if not target or s.blend_off == key then return end
    if s.blend_from == nil then
        s.blend_from = currentLight()
        save(s)
    elseif changedByHand() then
        s.blend_off = key
        save(s)
        return
    end
    local f = 1 - to_next / s.gradual_minutes
    local from = s.blend_from
    setLight({
        brightness = math.floor(from.brightness + (target.brightness - from.brightness) * f + 0.5),
        warmth = math.floor(from.warmth + (target.warmth - from.warmth) * f + 0.5),
    })
end

-- Checks the schedule every minute while KOReader runs
local function tick()
    pcall(checkSchedule)
    UIManager:scheduleIn(60, tick)
end
UIManager:scheduleIn(5, tick)

-- Checks the schedule right after the device wakes up
local orig_resume = DeviceListener.onResume
DeviceListener.onResume = function(self, ...)
    UIManager:scheduleIn(1.5, function() pcall(checkSchedule) end)
    if orig_resume then return orig_resume(self, ...) end
end

---------------------------------------------------------------- menu

-- Asks for a name and passes it to on_done (empty names are ignored)
local function askName(title, initial, on_done)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new {
        title = title,
        input = initial,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = dialog:getInputText()
                UIManager:close(dialog)
                if name ~= "" then on_done(name) end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Asks for a percentage (0 to 100) and passes it to on_done
local function askPercent(title, value, on_done)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new {
        title_text = title,
        value = value,
        value_min = 0,
        value_max = 100,
        value_step = 1,
        value_hold_step = 10,
        unit = "%",
        ok_always_enabled = true,
        callback = function(spin) on_done(spin.value) end,
    })
end

-- Dialog to change preset i: light values, name or removal
editPreset = function(i, touchmenu)
    local p = store().presets[i]
    if not p then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    -- Saves a change to preset i and refreshes the menu
    local function update(fn)
        local st = store()
        if st.presets[i] then fn(st.presets[i]) end
        save(st)
        if touchmenu then touchmenu:updateItems() end
    end
    local buttons = {
        { { text = "Use the current light", callback = function()
            UIManager:close(dialog)
            update(function(q)
                q.brightness = math.floor(getBrightness() * 100 + 0.5)
                q.warmth = math.floor(getWarmth() * 100 + 0.5)
            end)
        end } },
        { { text = T("Brightness: %1%", p.brightness), callback = function()
            UIManager:close(dialog)
            askPercent("Brightness", p.brightness, function(v) update(function(q) q.brightness = v end) end)
        end } },
    }
    if has_warmth then
        table.insert(buttons, { { text = T("Warmth: %1%", p.warmth), callback = function()
            UIManager:close(dialog)
            askPercent("Warmth", p.warmth, function(v) update(function(q) q.warmth = v end) end)
        end } })
    end
    table.insert(buttons, { { text = "Rename", callback = function()
        UIManager:close(dialog)
        askName("Preset name", p.name, function(name)
            local st = store()
            for __, e in ipairs(st.schedule) do
                if e.preset == p.name then e.preset = name end
            end
            save(st)
            update(function(q) q.name = name end)
        end)
    end } })
    table.insert(buttons, { { text = "Remove", callback = function()
        UIManager:close(dialog)
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new {
            text = T("Remove the preset \"%1\"?", p.name),
            ok_text = "Remove",
            ok_callback = function()
                local st = store()
                table.remove(st.presets, i)
                save(st)
                if touchmenu then touchmenu:backToUpperMenu() end
            end,
        })
    end } })
    dialog = ButtonDialog:new { title = p.name, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

-- Asks for a time of day and passes "HH:MM" to on_done
local function askTime(title, hhmm, on_done)
    local DateTimeWidget = require("ui/widget/datetimewidget")
    local h, m = (hhmm or "12:00"):match("^(%d+):(%d+)$")
    UIManager:show(DateTimeWidget:new {
        hour = tonumber(h),
        min = tonumber(m),
        ok_text = "Set",
        title_text = title,
        callback = function(t) on_done(string.format("%02d:%02d", t.hour, t.min)) end,
    })
end

-- Lets the user pick one of the presets and passes its name to on_done
local function askPreset(on_done)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for __, p in ipairs(store().presets) do
        table.insert(buttons, { { text = p.name, callback = function()
            UIManager:close(dialog)
            on_done(p.name)
        end } })
    end
    dialog = ButtonDialog:new { title = "Preset", title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

-- Whether another schedule entry already starts at hhmm
local function timeTaken(s, hhmm, except)
    for __, e in ipairs(s.schedule) do
        if e.time == hhmm and e.time ~= except then return true end
    end
    return false
end

-- Tells that a time is already used
local function warnTaken(hhmm)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new { text = T("There is already a preset starting at %1. Each time can have only one.", hhmm) })
end

-- Saves the schedule, forgets which period was applied and checks it again
local function saveSchedule(s)
    s.applied_key = nil
    save(s)
    pcall(checkSchedule)
end

-- Dialog for one schedule entry: change its time or preset, or remove it
local function editEntry(hhmm, touchmenu)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    -- Changes the entry starting at hhmm and refreshes the menu
    local function update(fn)
        local st = store()
        for __, e in ipairs(st.schedule) do
            if e.time == hhmm then fn(e, st) end
        end
        saveSchedule(st)
        if touchmenu then touchmenu:backToUpperMenu() end
    end
    dialog = ButtonDialog:new {
        title = hhmm,
        title_align = "center",
        buttons = {
            { { text = "Change the time", callback = function()
                UIManager:close(dialog)
                askTime("Starts at", hhmm, function(new)
                    if timeTaken(store(), new, hhmm) then return warnTaken(new) end
                    update(function(e) e.time = new end)
                end)
            end } },
            { { text = "Change the preset", callback = function()
                UIManager:close(dialog)
                askPreset(function(name) update(function(e) e.preset = name end) end)
            end } },
            { { text = "Remove", callback = function()
                UIManager:close(dialog)
                local st = store()
                for i, e in ipairs(st.schedule) do
                    if e.time == hhmm then table.remove(st.schedule, i) break end
                end
                saveSchedule(st)
                if touchmenu then touchmenu:backToUpperMenu() end
            end } },
        },
    }
    UIManager:show(dialog)
end

-- Light presets → Automatic presets: on/off, the schedule and the gradual change
local function scheduleMenu()
    return {
        text = "Automatic presets",
        sub_item_table_func = function()
            local s = store()
            local items = {
                {
                    text = "Follow the schedule",
                    checked_func = function() return store().auto end,
                    callback = function()
                        local st = store()
                        st.auto = not st.auto
                        saveSchedule(st)
                    end,
                    separator = true,
                },
            }
            for __, e in ipairs(sortedSchedule(s)) do
                table.insert(items, {
                    text_func = function()
                        local missing = not findPreset(store(), e.preset)
                        return T("%1  →  %2%3", e.time, e.preset, missing and "  (preset removed)" or "")
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu) editEntry(e.time, touchmenu) end,
                })
            end
            table.insert(items, {
                text = "Add a time",
                keep_menu_open = true,
                callback = function(touchmenu)
                    askTime("Starts at", "12:00", function(hhmm)
                        if timeTaken(store(), hhmm) then return warnTaken(hhmm) end
                        askPreset(function(name)
                            local st = store()
                            table.insert(st.schedule, { time = hhmm, preset = name })
                            saveSchedule(st)
                            if touchmenu then touchmenu:backToUpperMenu() end
                        end)
                    end)
                end,
                separator = true,
            })
            table.insert(items, {
                text = "Change gradually",
                checked_func = function() return store().gradual end,
                callback = function()
                    local st = store()
                    st.gradual = not st.gradual
                    save(st)
                end,
            })
            table.insert(items, {
                text_func = function() return T("Gradual change takes: %1 min", store().gradual_minutes) end,
                enabled_func = function() return store().gradual end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new {
                        title_text = "Gradual change (minutes)",
                        value = store().gradual_minutes,
                        value_min = 5,
                        value_max = 120,
                        value_step = 5,
                        default_value = CONFIG.gradual_minutes,
                        ok_always_enabled = true,
                        callback = function(spin)
                            local st = store()
                            st.gradual_minutes = spin.value
                            save(st)
                            if touchmenu then touchmenu:updateItems() end
                        end,
                    })
                end,
                separator = true,
            })
            table.insert(items, {
                text = "Each preset lasts until the next time. Changing the light by hand keeps it until then.",
                enabled_func = function() return false end,
            })
            return items
        end,
    }
end

-- Settings → Light presets: apply, edit, save current, and options
local function presetsMenu()
    return {
        text = "Light presets",
        sub_item_table_func = function()
            local s = store()
            local items = {}
            for i, p in ipairs(s.presets) do
                table.insert(items, {
                    text_func = function()
                        local q = store().presets[i] or p
                        return has_warmth and T("%1  (%2% · warmth %3%)", q.name, q.brightness, q.warmth)
                            or T("%1  (%2%)", q.name, q.brightness)
                    end,
                    callback = function() applyPreset(store().presets[i] or p) end,
                    hold_callback = function(touchmenu) editPreset(i, touchmenu) end,
                    separator = i == #s.presets,
                })
            end
            table.insert(items, {
                text = "Save current light as a preset",
                keep_menu_open = true,
                callback = function(touchmenu)
                    askName("Preset name", "", function(name)
                        local st = store()
                        table.insert(st.presets, {
                            name = name,
                            brightness = math.floor(getBrightness() * 100 + 0.5),
                            warmth = math.floor(getWarmth() * 100 + 0.5),
                        })
                        save(st)
                        if touchmenu then touchmenu:backToUpperMenu() end
                    end)
                end,
            })
            table.insert(items, scheduleMenu())
            table.insert(items, {
                text = "Open the light panel",
                callback = function() showPanel() end,
                separator = true,
            })
            table.insert(items, {
                text = "Edge swipes set the level where the finger stops",
                checked_func = function() return store().absolute_swipes end,
                callback = function() local st = store() st.absolute_swipes = not st.absolute_swipes save(st) end,
            })
            table.insert(items, {
                text = "Show the slider while adjusting",
                checked_func = function() return store().show_slider end,
                callback = function() local st = store() st.show_slider = not st.show_slider save(st) end,
            })
            table.insert(items, {
                text_func = function() return T("Slider closes after: %1 s", store().slider_seconds) end,
                enabled_func = function() return store().show_slider end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new {
                        title_text = "Slider closes after (seconds)",
                        value = store().slider_seconds,
                        value_min = 1,
                        value_max = 15,
                        value_step = 1,
                        default_value = CONFIG.slider_seconds,
                        ok_always_enabled = true,
                        callback = function(spin)
                            local st = store()
                            st.slider_seconds = spin.value
                            save(st)
                            if touchmenu then touchmenu:updateItems() end
                        end,
                    })
                end,
                separator = true,
            })
            table.insert(items, {
                text_func = function() return "Hold a preset to edit or remove it" end,
                enabled_func = function() return false end,
            })
            return items
        end,
    }
end

-- Adds "Light presets" right after Frontlight in the settings tab of both menus
for __, m in ipairs({
    { "apps/filemanager/filemanagermenu", "ui/elements/filemanager_menu_order" },
    { "apps/reader/modules/readermenu", "ui/elements/reader_menu_order" },
}) do
    local Menu, order = require(m[1]), require(m[2])
    if order.setting and not util.arrayContains(order.setting, "light_presets") then
        for i, id in ipairs(order.setting) do
            if id == "frontlight" then table.insert(order.setting, i + 1, "light_presets") break end
        end
    end
    local orig = Menu.setUpdateItemTable
    Menu.setUpdateItemTable = function(self, ...)
        self.menu_items.light_presets = presetsMenu()
        return orig(self, ...)
    end
end
