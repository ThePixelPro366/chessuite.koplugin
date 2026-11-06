-- Stand-ins for the KOReader modules the plugin's pages use, good enough to
-- build every page, press its buttons and run games against the real engine.
-- Widgets are plain tables that remember their constructor arguments.

local Fake = { shown = {}, infos = {}, dialogs = {} }

local UIManager = require("ui/uimanager") -- the timer queue stub
function UIManager:show(w)
    table.insert(Fake.shown, w)
    if w.handleEvent then w:handleEvent({ name = "Show" }) end
end
function UIManager:close(w)
    for i = #Fake.shown, 1, -1 do if Fake.shown[i] == w then table.remove(Fake.shown, i) end end
    if w and w.onCloseWidget then w:onCloseWidget() end
end
-- every repaint request checks the page like KOReader's painting would
function UIManager:setDirty(w)
    if type(w) == "table" and w[1] and Fake.paint then Fake.paint(w[1]) end
end
function UIManager:forceRePaint() end
function UIManager:widgetInvert() end
function UIManager:widgetRepaint() end
function Fake.top() return Fake.shown[#Fake.shown] end

local function geom(t)
    t = t or {}
    return { x = t.x or 0, y = t.y or 0, w = t.w or 0, h = t.h or 0 }
end

local Geom = {}
function Geom:new(t) return geom(t) end
package.loaded["ui/geometry"] = Geom

-- Generic widget class with extend/new/init like KOReader's Widget.
local Widget = {}
Widget.__index = Widget
function Widget:extend(subclass)
    subclass = subclass or {}
    setmetatable(subclass, self)
    self.__index = self
    return subclass
end
function Widget:new(o)
    o = self:extend(o)
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end
function Widget:getSize()
    if self.dimen and self.dimen.w then return { w = self.dimen.w, h = self.dimen.h } end
    -- KOReader's groups compute their children's positions here and keep them
    self._sized_count = #self
    local w, h = self.width or 0, self.height or 0
    for _, c in ipairs(self) do
        local s = type(c) == "table" and c.getSize and c:getSize() or { w = 0, h = 0 }
        if self._horizontal then w = w + s.w; h = math.max(h, s.h) else w = math.max(w, s.w); h = h + s.h end
    end
    if h == 0 then h = 30 end
    if w == 0 then w = 100 end
    return { w = w, h = h }
end
function Widget:paintTo() end
function Widget:free() end
function Widget:handleEvent(ev)
    local f = self["on" .. ev.name]
    if f then return f(self, ev.args, ev.ges) end
end
Widget.__tostring = function() return "Widget" end

local function class(extra)
    local c = Widget:extend(extra or {})
    return c
end

local InputContainer = class{ _init = function(self) self.ges_events = self.ges_events or {}; self.key_events = self.key_events or {} end }
package.loaded["ui/widget/widget"] = Widget
package.loaded["ui/widget/container/inputcontainer"] = InputContainer
package.loaded["ui/widget/container/widgetcontainer"] = class()
for _, name in ipairs({ "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
    "ui/widget/container/leftcontainer", "ui/widget/verticalgroup", "ui/widget/verticalspan",
    "ui/widget/horizontalspan", "ui/widget/imagewidget", "ui/widget/qrwidget", "ui/widget/qrmessage",
    "ui/widget/scrolltextwidget", "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/widget/titlebar",
    "ui/widget/pathchooser", "ui/widget/spinwidget", "ui/widget/textviewer" }) do
    package.loaded[name] = class()
end
package.loaded["ui/widget/horizontalgroup"] = class{ _horizontal = true }
package.loaded["ui/widget/buttontable"] = class{ init = function(self) Fake.last_buttons = self.buttons end }
package.loaded["ui/widget/infomessage"] = class{ init = function(self) table.insert(Fake.infos, self.text) end }
package.loaded["ui/widget/buttondialog"] = class{ init = function(self) table.insert(Fake.dialogs, self) end }
package.loaded["ui/widget/confirmbox"] = class{}
package.loaded["ui/widget/inputdialog"] = class{
    getInputText = function(self) return self.input end,
    onShowKeyboard = function() end,
}
package.loaded["ui/gesturerange"] = class()

local Color = {}
Color.__index = Color
local function color8(v) return setmetatable({ v = v }, Color) end
function Color:invert() return color8(255 - self.v) end
package.loaded["ffi/blitbuffer"] = setmetatable({ Color8 = color8 }, {
    __index = function(_, k) if k:match("^COLOR_") then return color8(0) end end })

package.loaded["ui/size"] = setmetatable({}, { __index = function()
    return setmetatable({}, { __index = function() return 4 end })
end })
package.loaded["ui/font"] = { getFace = function(_, name, size) return { name = name, size = size } end }
local Screen = {
    w = 1072, h = 1448,
    getWidth = function(self) return self.w end,
    getHeight = function(self) return self.h end,
    scaleBySize = function(_, v) return math.floor(v * 1.5) end,
}
package.loaded["device"] = {
    screen = Screen,
    hasKeys = function() return true end,
    isKindle = function() return false end,
    isTouchDevice = function() return true end,
    input = { group = { Back = { "Back" } } },
}
package.loaded["ui/message/simpletcpserver"] = {
    new = function(_, o) o = o or {}; o.start = function() return true end; o.stop = function() end; return o end,
}
function UIManager:insertZMQ(q) return q end
function UIManager:removeZMQ() end
package.loaded["ui/network/manager"] = {
    willRerunWhenOnline = function() return false end,
    isOnline = function() return true end,
}
package.loaded["dispatcher"] = { registerAction = function() end }
package.loaded["gettext"] = function(s) return s end
Fake.Screen = Screen

-- Walks a widget tree like a repaint and fails where KOReader would crash:
-- a group that got children after its size (and child positions) was computed.
function Fake.paint(w, seen)
    seen = seen or {}
    if type(w) ~= "table" or seen[w] then return end
    seen[w] = true
    if w._sized_count and #w > w._sized_count then
        error("widget got " .. (#w - w._sized_count) .. " children after getSize(): KOReader would crash painting it")
    end
    for _, c in ipairs(w) do Fake.paint(c, seen) end
end

-- Tap a button by its label in the last ButtonTable built.
function Fake.press(label)
    for _, row in ipairs(Fake.last_buttons or {}) do
        for _, b in ipairs(row) do
            if b.text and b.text:find(label, 1, true) then
                assert(b.enabled ~= false, "button disabled: " .. label)
                b.callback()
                return true
            end
        end
    end
    error("no button " .. label)
end

-- Choose an entry in the last ButtonDialog.
function Fake.choose(label)
    local d = Fake.dialogs[#Fake.dialogs]
    for _, row in ipairs(d.buttons) do
        for _, b in ipairs(row) do
            if b.text and b.text:find(label, 1, true) then b.callback(); return true end
        end
    end
    error("no dialog entry " .. label)
end

return Fake
