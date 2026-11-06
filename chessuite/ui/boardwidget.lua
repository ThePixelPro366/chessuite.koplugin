--[[
A chess board drawn for e-ink: high contrast squares, SVG pieces, a thick
frame on the selected piece, dots on the squares it can go to and marked
squares for the last move and for hints. Moves are made by tapping the
piece and then the target square.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Chess = require("chessuite/chess")

local BoardWidget = InputContainer:extend{
    size = 400,           -- width and height in pixels
    game = nil,           -- a Chess object
    flipped = false,      -- true: black at the bottom
    interactive = true,   -- accept taps
    player_color = nil,   -- only this colour may be moved ("w", "b"), nil = both
    show_legal = true,
    show_coords = true,
    dark_color = 0xAA,
    plugin_dir = nil,     -- where icons/pieces/*.svg live
    on_move = nil,        -- function(move) called with a legal move (promotion asked first)
    on_promotion = nil,   -- function(from, to, callback(piece_letter)) to ask for the piece
    marks = nil,          -- { [square] = "hint" | "good" | "bad" | "target" (a ring around the piece) }
    badge = nil,          -- { square = sq, class = "blunder" }: review symbol on a square
    arrows = nil,         -- list of { from = sq, to = sq, color = "red" | "green" | "blue",
                          --   thin = true, dashed = true (an attack, not a move), label = 1 (step number) }
}

function BoardWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.size, h = self.size }
    self.square = math.floor(self.size / 8)
    self.selected = nil
    self.targets = {}
    self.marks = self.marks or {}
    self.ges_events = {
        TapBoard = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    self.piece_cache = {}
    self.coord_face = Font:getFace("cfont", math.max(9, math.floor(self.square / 5)))
end

function BoardWidget:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function BoardWidget:setGame(game)
    self.game = game
    self.selected = nil
    self.targets = {}
end

function BoardWidget:setMarks(marks)
    self.marks = marks or {}
end

function BoardWidget:setArrows(arrows)
    self.arrows = arrows
end

function BoardWidget:setBadge(square, class)
    self.badge = square and class and { square = square, class = class } or nil
end

function BoardWidget:clearSelection()
    self.selected = nil
    self.targets = {}
end

-- Screen position (column, row from the top-left) of a 0x88 square.
function BoardWidget:squareToCell(sq)
    local file, rank = Chess.fileOf(sq), Chess.rankOf(sq)
    if self.flipped then return 7 - file, rank end
    return file, 7 - rank
end

function BoardWidget:cellToSquare(col, row)
    if self.flipped then return row * 16 + (7 - col) end
    return (7 - row) * 16 + col
end

function BoardWidget:pieceImage(p)
    local img = self.piece_cache[p]
    if not img then
        local name = (Chess.colorOf(p) == "w" and "w" or "b") .. p:upper() .. ".svg"
        local pad = math.floor(self.square * 0.06)
        img = ImageWidget:new{
            file = self.plugin_dir .. "/icons/pieces/" .. name,
            width = self.square - 2 * pad,
            height = self.square - 2 * pad,
            alpha = true,
            file_do_cache = true,
        }
        img._pad = pad
        self.piece_cache[p] = img
    end
    return img
end

function BoardWidget:free()
    for _, img in pairs(self.piece_cache) do
        if img.free then img:free() end
    end
    self.piece_cache = {}
end

function BoardWidget:onCloseWidget()
    self:free()
end

function BoardWidget:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local s = self.square
    local dark = Blitbuffer.Color8(self.dark_color or 0xAA)
    local light = Blitbuffer.COLOR_WHITE
    local game = self.game
    local last = game and game:lastMove()
    local check_sq = game and game:inCheck() and game.kings[game.turn]

    for row = 0, 7 do
        for col = 0, 7 do
            local sq = self:cellToSquare(col, row)
            local px, py = x + col * s, y + row * s
            local is_dark = (Chess.fileOf(sq) + Chess.rankOf(sq)) % 2 == 0
            bb:paintRect(px, py, s, s, is_dark and dark or light)
            -- last move: a frame inside both squares
            if last and (sq == last.from or sq == last.to) then
                bb:paintBorder(px + 2, py + 2, s - 4, s - 4, math.max(2, math.floor(s / 16)), Blitbuffer.COLOR_GRAY_5)
            end
            local mark = self.marks[sq]
            -- (a "target" ring is painted after the piece, below)
            if mark and mark ~= "target" then
                local w = math.max(3, math.floor(s / 10))
                bb:paintBorder(px + 1, py + 1, s - 2, s - 2, w, Blitbuffer.COLOR_BLACK)
                if mark == "bad" then
                    -- a cross in the corner for squares the coach warns about
                    local c = math.floor(s / 5)
                    bb:paintRect(px + s - c - w, py + w, c, c, Blitbuffer.COLOR_BLACK)
                end
            end
            if check_sq and sq == check_sq then
                bb:paintRect(px, py, s, s, Blitbuffer.COLOR_GRAY_6)
            end
            if self.selected == sq then
                bb:paintRect(px, py, s, s, Blitbuffer.COLOR_GRAY_7)
            end
            local p = game and game.board[sq]
            if p then
                local img = self:pieceImage(p)
                img:paintTo(bb, px + img._pad, py + img._pad)
            end
            if mark == "target" then
                -- a thick ring around an attacked piece
                local r = math.floor(s / 2) - 2
                bb:paintCircle(px + math.floor(s / 2), py + math.floor(s / 2), r, Blitbuffer.COLOR_BLACK,
                    math.max(3, math.floor(s / 14)))
            end
            if self.show_legal and self.targets[sq] then
                local r = math.floor(s / 7)
                if p then
                    -- capture: dark corners around the piece, like lichess' capture ring
                    local c = math.floor(s / 4)
                    for i = 0, c - 1 do
                        local w = c - i
                        bb:paintRect(px, py + i, w, 1, Blitbuffer.COLOR_GRAY_3)
                        bb:paintRect(px + s - w, py + i, w, 1, Blitbuffer.COLOR_GRAY_3)
                        bb:paintRect(px, py + s - 1 - i, w, 1, Blitbuffer.COLOR_GRAY_3)
                        bb:paintRect(px + s - w, py + s - 1 - i, w, 1, Blitbuffer.COLOR_GRAY_3)
                    end
                else
                    bb:paintCircle(px + math.floor(s / 2), py + math.floor(s / 2), r, Blitbuffer.COLOR_BLACK)
                    bb:paintCircle(px + math.floor(s / 2), py + math.floor(s / 2), r, Blitbuffer.COLOR_WHITE, math.max(1, math.floor(r / 3)))
                end
            end
            if self.show_coords then
                if col == 0 then
                    local t = TextWidget:new{ text = tostring(Chess.rankOf(sq) + 1), face = self.coord_face,
                        fgcolor = Blitbuffer.COLOR_BLACK, padding = 0 }
                    t:paintTo(bb, px + 2, py + 1)
                    t:free()
                end
                if row == 7 then
                    local f = Chess.squareName(sq):sub(1, 1)
                    local t = TextWidget:new{ text = f, face = self.coord_face, fgcolor = Blitbuffer.COLOR_BLACK, padding = 0 }
                    local ts = t:getSize()
                    t:paintTo(bb, px + s - ts.w - 2, py + s - ts.h)
                    t:free()
                end
            end
        end
    end
    bb:paintBorder(x, y, 8 * s, 8 * s, math.max(1, math.floor(s / 30)), Blitbuffer.COLOR_BLACK)
    for _, a in ipairs(self.arrows or {}) do self:paintArrow(bb, x, y, a) end
    -- step numbers last, so no arrow covers them
    for _, a in ipairs(self.arrows or {}) do
        if a.label then self:paintLabel(bb, x, y, a) end
    end
    if self.badge then self:paintBadge(bb, x, y) end
end

local ARROW_RGB = { red = { 0xD9, 0x3B, 0x30 }, green = { 0x3D, 0x8B, 0x37 }, blue = { 0x2F, 0x6E, 0xBA } }

-- An arrow between two square centres, drawn with a square brush.
function BoardWidget:paintArrow(bb, x, y, a)
    local s = self.square
    local Screen = require("device").screen
    local rgb = ARROW_RGB[a.color or "red"] or ARROW_RGB.red
    local color
    if Screen.isColorEnabled and Screen:isColorEnabled() then
        color = Blitbuffer.ColorRGB32(rgb[1], rgb[2], rgb[3], 0xFF)
    else
        color = Blitbuffer.ColorRGB32(0x33, 0x33, 0x33, 0xFF)
    end
    local function centre(sq)
        local col, row = self:squareToCell(sq)
        return x + col * s + s / 2, y + row * s + s / 2
    end
    local x1, y1 = centre(a.from)
    local x2, y2 = centre(a.to)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return end
    local ux, uy = dx / len, dy / len
    local w = math.max(3, math.floor(s / (a.thin and 16 or 9)))
    local head = s * (a.thin and 0.3 or 0.42)
    local function line(ax, ay, bx, by, width)
        local n = math.max(math.abs(bx - ax), math.abs(by - ay))
        for i = 0, n do
            local px = ax + (bx - ax) * i / math.max(n, 1)
            local py = ay + (by - ay) * i / math.max(n, 1)
            bb:paintRectRGB32(math.floor(px - width / 2), math.floor(py - width / 2), width, width, color)
        end
    end
    -- shaft stops where the head starts; an attack (dashed) is drawn in dashes
    local sx, sy = x2 - ux * head * 0.8, y2 - uy * head * 0.8
    if a.dashed then
        local slen = math.sqrt((sx - x1) ^ 2 + (sy - y1) ^ 2)
        local dash = math.max(6, s / 5)
        local t = 0
        while t < slen do
            local e = math.min(t + dash, slen)
            line(x1 + ux * t, y1 + uy * t, x1 + ux * e, y1 + uy * e, w)
            t = e + dash * 0.7
        end
    else
        line(x1, y1, sx, sy, w)
    end
    -- filled head: lines from the tip to the back edge, side to side
    local bx, by = x2 - ux * head, y2 - uy * head
    local px, py = -uy, ux
    local half = head * 0.6
    local steps = math.floor(half)
    for i = -steps, steps do
        local ex, ey = bx + px * i, by + py * i
        line(ex, ey, x2, y2, 2)
    end
end

-- The step number of an arrow, in a disc on the square it starts from.
function BoardWidget:paintLabel(bb, x, y, a)
    local s = self.square
    local col, row = self:squareToCell(a.from)
    local r = math.max(10, math.floor(s / 4.2))
    -- in the square's top-left corner, clear of the piece in the middle
    local cx, cy = x + col * s + r + 2, y + row * s + r + 2
    bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_WHITE)
    bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK, math.max(2, math.floor(r / 5)))
    local t = TextWidget:new{ text = tostring(a.label), face = Font:getFace("smalltfont", math.max(8, math.floor(r * 0.75))),
        bold = true, fgcolor = Blitbuffer.COLOR_BLACK, padding = 0 }
    local ts = t:getSize()
    t:paintTo(bb, cx - math.floor(ts.w / 2), cy - math.floor(ts.h / 2))
    t:free()
end

function BoardWidget:paintBadge(bb, x, y)
    local Coach = require("chessuite/coach")
    local info = Coach.BADGES[self.badge.class]
    if not info then return end
    local s = self.square
    local col, row = self:squareToCell(self.badge.square)
    local d = math.floor(s * 0.46)
    -- top-right corner of the square, sticking out a little like on chess.com
    local bx = math.min(x + (col + 1) * s - math.floor(d * 0.7), x + 8 * s - d)
    local by = math.max(y + row * s - math.floor(d * 0.3), y)
    local Screen = require("device").screen
    local color
    if Screen.isColorEnabled and Screen:isColorEnabled() then
        color = Blitbuffer.ColorRGB32(info.rgb[1], info.rgb[2], info.rgb[3], 0xFF)
    else
        color = Blitbuffer.ColorRGB32(info.gray, info.gray, info.gray, 0xFF)
    end
    local r = math.floor(d / 2)
    bb:paintRoundedRectRGB32(bx, by, d, d, Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF), r)
    local ring = math.max(2, math.floor(d / 14))
    bb:paintRoundedRectRGB32(bx + ring, by + ring, d - 2 * ring, d - 2 * ring, color, r - ring)
    local t = TextWidget:new{
        text = info.symbol,
        face = Font:getFace("smalltfont", math.max(10, math.floor(d * (#info.symbol > 1 and 0.42 or 0.55)))),
        bold = true,
        fgcolor = Blitbuffer.COLOR_WHITE,
        padding = 0,
    }
    local ts = t:getSize()
    t:paintTo(bb, bx + math.floor((d - ts.w) / 2), by + math.floor((d - ts.h) / 2))
    t:free()
end

function BoardWidget:refresh()
    UIManager:setDirty(self.show_parent or self, function()
        return "ui", self.dimen
    end)
end

function BoardWidget:onTapBoard(_, ges)
    if not self.interactive or not self.game then return true end
    local col = math.floor((ges.pos.x - self.dimen.x) / self.square)
    local row = math.floor((ges.pos.y - self.dimen.y) / self.square)
    if col < 0 or col > 7 or row < 0 or row > 7 then return true end
    local sq = self:cellToSquare(col, row)
    local game = self.game
    local p = game.board[sq]
    local mine = p and Chess.colorOf(p) == game.turn and (not self.player_color or self.player_color == game.turn)

    if self.selected and self.targets[sq] then
        local from = self.selected
        self:clearSelection()
        local moves = game:moves({ square = from })
        local promotion = false
        for _, m in ipairs(moves) do
            if m.to == sq and m.promotion then promotion = true end
        end
        local function play(promo)
            for _, m in ipairs(moves) do
                if m.to == sq and (m.promotion == promo) then
                    if self.on_move then self.on_move(m) end
                    return
                end
            end
        end
        if promotion and self.on_promotion then
            self:refresh()
            self.on_promotion(from, sq, function(piece) play(piece or "q") end)
        else
            play(promotion and "q" or nil)
        end
        return true
    end

    if mine and self.selected ~= sq then
        self.selected = sq
        self.targets = {}
        for _, m in ipairs(game:moves({ square = sq })) do self.targets[m.to] = true end
    else
        self:clearSelection()
    end
    self:refresh()
    return true
end

return BoardWidget
