--[[
Shared pieces for the plugin's full-screen pages.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local Common = {}

function Common.screenSize()
    return Screen:getWidth(), Screen:getHeight()
end

function Common.isLandscape()
    return Screen:getWidth() > Screen:getHeight()
end

function Common.scale(px) return Screen:scaleBySize(px) end

-- Icons ----------------------------------------------------------------------

-- The plugin folder (set by main.lua), where icons/ui/*.svg live: Material
-- Symbols by Google (Apache-2.0), filled, in black for e-ink.
Common.plugin_dir = "."

function Common.iconFile(name, white)
    return Common.plugin_dir .. "/icons/ui/" .. (white and "white/" or "") .. name .. ".svg"
end

function Common.pieceFile(color, piece)
    return Common.plugin_dir .. "/icons/pieces/" .. color .. piece:upper() .. ".svg"
end

-- `white` for an icon on a black background
function Common.icon(name, size, white)
    return ImageWidget:new{
        file = Common.iconFile(name, white),
        width = size,
        height = size,
        alpha = true,
        file_do_cache = true,
    }
end

-- Text helpers ---------------------------------------------------------------

function Common.label(text, size, bold, color, max_width)
    return TextWidget:new{
        text = text,
        face = Font:getFace(bold and "smalltfont" or "cfont", size or 20),
        bold = bold,
        fgcolor = color or Blitbuffer.COLOR_BLACK,
        max_width = max_width,
    }
end

function Common.paragraph(text, width, size, opts)
    opts = opts or {}
    return TextBoxWidget:new{
        text = text or "",
        face = Font:getFace(opts.bold and "smalltfont" or "cfont", size or 18),
        bold = opts.bold,
        width = width,
        height = opts.height,
        height_overflow_show_ellipsis = opts.height ~= nil,
        alignment = opts.alignment or "left",
        fgcolor = opts.color or Blitbuffer.COLOR_BLACK,
        bgcolor = opts.bgcolor or Blitbuffer.COLOR_WHITE,
    }
end

function Common.vspace(h) return VerticalSpan:new{ width = h or Size.span.vertical_large } end
function Common.hspace(w) return HorizontalSpan:new{ width = w or Size.span.horizontal_default } end

-- A round "avatar" for bots, players and cards: an icon, a chess piece or an initial.
local Avatar = InputContainer:extend{
    letter = "?",
    icon = nil,      -- name of an icons/ui icon
    piece = nil,     -- "p", "n", "b", "r", "q" or "k": a piece of the board's set
    size = 60,
    inverted = false, -- black disc
}

function Avatar:init()
    self.dimen = Geom:new{ w = self.size, h = self.size }
    if self.piece then
        -- a white piece on the black disc, a black one on the white disc
        local s = math.floor(self.size * 0.72)
        self.text = ImageWidget:new{ file = Common.pieceFile(self.inverted and "w" or "b", self.piece),
            width = s, height = s, alpha = true, file_do_cache = true }
    elseif self.icon then
        self.text = Common.icon(self.icon, math.floor(self.size * 0.58), self.inverted)
    else
        self.text = TextWidget:new{
            text = self.letter,
            face = Font:getFace("smalltfont", math.floor(self.size * 0.45)),
            bold = true,
            fgcolor = self.inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
        }
    end
end

function Avatar:getSize() return Geom:new{ w = self.size, h = self.size } end

function Avatar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local r = math.floor(self.size / 2)
    if self.inverted then
        bb:paintCircle(x + r, y + r, r, Blitbuffer.COLOR_BLACK)
    else
        -- a white disc, so the icon also shows on a black card
        bb:paintCircle(x + r, y + r, r, Blitbuffer.COLOR_WHITE)
        bb:paintCircle(x + r, y + r, r, Blitbuffer.COLOR_BLACK, math.max(2, math.floor(self.size / 20)))
    end
    local ts = self.text:getSize()
    self.text:paintTo(bb, x + r - math.floor(ts.w / 2), y + r - math.floor(ts.h / 2))
end

function Avatar:onCloseWidget() self.text:free() end
Common.Avatar = Avatar

-- A big tappable card -------------------------------------------------------

local Tile = InputContainer:extend{
    width = 300,
    height = nil,
    title = "",
    subtitle = nil,
    badge = nil,        -- small text on the right of the title
    letter = nil,       -- avatar letter on the left
    icon = nil,         -- or an icon (icons/ui/<name>.svg) on the left
    piece = nil,        -- or a chess piece ("p", "n", ...)
    callback = nil,
    hold_callback = nil,
    inverted = false,   -- black card (for the main action)
    enabled = true,
}

function Tile:init()
    local pad = Size.padding.large
    local inner_w = self.width - 2 * pad - 2 * Size.border.thick
    local fg = self.inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bg = self.inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    if not self.enabled then fg = Blitbuffer.COLOR_DARK_GRAY end
    local text_w = inner_w
    local avatar
    if self.letter or self.icon or self.piece then
        local asize = Common.scale(self.avatar_size or 44)
        avatar = Avatar:new{ letter = self.letter, icon = self.icon, piece = self.piece, size = asize,
            inverted = not self.inverted }
        text_w = inner_w - asize - Size.padding.large
    end
    local title_row = HorizontalGroup:new{ align = "center" }
    local badge_w = 0
    local badge
    if self.badge then
        badge = TextWidget:new{ text = self.badge, face = Font:getFace("cfont", 16), fgcolor = fg }
        badge_w = badge:getSize().w + Size.padding.default
    end
    title_row[#title_row + 1] = TextWidget:new{
        text = self.title,
        face = Font:getFace("smalltfont", 22),
        bold = true,
        fgcolor = fg,
        max_width = text_w - badge_w,
    }
    if badge then
        title_row[#title_row + 1] = HorizontalSpan:new{ width = Size.padding.default }
        title_row[#title_row + 1] = badge
    end
    local texts = VerticalGroup:new{ align = "left", title_row }
    if self.subtitle and self.subtitle ~= "" then
        texts[#texts + 1] = VerticalSpan:new{ width = Size.span.vertical_large }
        texts[#texts + 1] = TextBoxWidget:new{
            text = self.subtitle,
            face = Font:getFace("cfont", 16),
            width = text_w,
            fgcolor = fg,
            bgcolor = bg,
        }
    end
    local content
    if avatar then
        content = HorizontalGroup:new{ align = "center", avatar, HorizontalSpan:new{ width = Size.padding.large }, texts }
    else
        content = texts
    end
    local h = self.height and (self.height - 2 * pad - 2 * Size.border.thick) or content:getSize().h
    self[1] = FrameContainer:new{
        bordersize = Size.border.thick,
        radius = Size.radius.window,
        padding = pad,
        background = bg,
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = math.max(h, content:getSize().h) },
            content,
        },
    }
    self.dimen = Geom:new{ w = self.width, h = self[1]:getSize().h }
    self.ges_events = {
        TapTile = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldTile = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Tile:getSize() return self[1]:getSize() end

function Tile:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self[1]:paintTo(bb, x, y)
end

function Tile:onTapTile()
    if not self.enabled or not self.callback then return true end
    local d = self[1].dimen
    if d then
        UIManager:widgetInvert(self[1], d.x, d.y, d.w, d.h)
        UIManager:setDirty(nil, "fast", d)
        UIManager:forceRePaint()
    end
    UIManager:scheduleIn(0.1, function()
        if d then UIManager:setDirty(self.show_parent, "ui", d) end
        self.callback()
    end)
    return true
end

function Tile:onHoldTile()
    if self.hold_callback then self.hold_callback() end
    return true
end
Common.Tile = Tile

-- Lays tiles out in a grid of `cols` columns.
function Common.tileGrid(tiles, width, cols, gap)
    gap = gap or Size.padding.large
    local grid = VerticalGroup:new{ align = "left" }
    local row
    for i, t in ipairs(tiles) do
        if (i - 1) % cols == 0 then
            if row then
                grid[#grid + 1] = row
                grid[#grid + 1] = VerticalSpan:new{ width = gap }
            end
            row = HorizontalGroup:new{ align = "top" }
        else
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end
        row[#row + 1] = t
    end
    if row then grid[#grid + 1] = row end
    return grid
end

function Common.tileWidth(width, cols, gap)
    gap = gap or Size.padding.large
    return math.floor((width - (cols - 1) * gap) / cols)
end

-- A row of normal buttons at the bottom of a page.
function Common.buttonBar(buttons, width, show_parent)
    return ButtonTable:new{
        width = width,
        buttons = buttons,
        zero_sep = true,
        show_parent = show_parent,
    }
end

-- Makes a widget tappable (e.g. the coach's message opens "Why?").
local TapBox = InputContainer:extend{ callback = nil }
function TapBox:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
    self.ges_events = {
        TapBox = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end
function TapBox:getSize() return self[1]:getSize() end
function TapBox:paintTo(bb, x, y)
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    self[1]:paintTo(bb, x, y)
end
function TapBox:onTapBox()
    if self.callback then self.callback() end
    return true
end
Common.TapBox = TapBox

-- A box of fixed size that paints its child at its top-left corner: whatever
-- the child's width, the page around it never moves.
local FixedBox = InputContainer:extend{ width = 100, height = 100 }
function FixedBox:getSize() return Geom:new{ w = self.width, h = self.height } end
function FixedBox:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if self[1] then self[1]:paintTo(bb, x, y) end
end
Common.FixedBox = FixedBox

-- Full-screen page base ------------------------------------------------------

local Page = InputContainer:extend{
    title = "",
    subtitle = nil,
    covers_fullscreen = true,
    left_icon = nil,
    left_icon_tap_callback = nil,
}

function Page:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self.ges_events = self.ges_events or {}
    self:rebuild()
end

-- Subclasses implement buildContent(width, height) and return a widget.
function Page:buildContent(width, height)
    return VerticalGroup:new{}
end

function Page:rebuild()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    self.title_bar = TitleBar:new{
        width = w,
        fullscreen = true,
        with_bottom_line = true,
        title = self.title,
        subtitle = self.subtitle,
        left_icon = self.left_icon,
        left_icon_tap_callback = self.left_icon_tap_callback,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local th = self.title_bar:getSize().h
    local pad = Size.padding.large
    self.content_width = w - 2 * pad
    self.content_height = h - th - 2 * pad
    local content = self:buildContent(self.content_width, self.content_height)
    self[1] = FrameContainer:new{
        width = w,
        height = h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            self.title_bar,
            FrameContainer:new{
                padding = pad,
                bordersize = 0,
                margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                FixedBox:new{ width = self.content_width, height = self.content_height, content },
            },
        },
    }
end

function Page:refresh(mode)
    self:rebuild()
    UIManager:setDirty(self, mode or "ui")
end

function Page:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function Page:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end
Common.Page = Page

-- Messages and busy indicator -------------------------------------------------

function Common.info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

-- Shows "text" while fn() runs (blocking, e.g. a network request).
function Common.busy(text, fn)
    local msg = InfoMessage:new{ text = text, dismissable = false }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, a, b, c = pcall(fn)
    UIManager:close(msg)
    if not ok then
        Common.info("Error: " .. tostring(a))
        return false
    end
    return a, b, c
end

function Common.whenOnline(fn)
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:willRerunWhenOnline(fn) then return end
    fn()
end

-- A framed box (for coach messages and info panels).
function Common.box(widget, opts)
    opts = opts or {}
    return FrameContainer:new{
        bordersize = opts.border or Size.border.thick,
        radius = opts.radius or Size.radius.window,
        padding = opts.padding or Size.padding.default,
        background = opts.background or Blitbuffer.COLOR_WHITE,
        widget,
    }
end

function Common.centered(widget, width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height or widget:getSize().h }, widget }
end

return Common
