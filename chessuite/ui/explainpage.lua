--[[
"Why?": a full-screen explanation you can see. A smaller board steps through
the line (your move, the answer, what follows) with numbered arrows and
rings around the pieces the tactic hits, next to the explanation in words.
Like chess.com's Show button, step by step with ‹ ›, or Play.

    ExplainPage:new{ plugin = ..., parts = { { title, headline, text, steps } ... } }
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BoardWidget = require("chessuite/ui/boardwidget")
local Common = require("chessuite/ui/common")
local Store = require("chessuite/store")

local PLAY_DELAY = 1.6 -- seconds per step when playing it through

local ExplainPage = Common.Page:extend{
    title = "Why?",
    plugin = nil,
    parts = nil,     -- { { title = "What goes wrong", headline, text, steps = {...} }, ... }
    flipped = false, -- the board from Black's side
}

function ExplainPage:init()
    self.part = 1
    self.step = 1
    Common.Page.init(self)
end

function ExplainPage:current() return self.parts[self.part] end

function ExplainPage:buildContent(width, height)
    local landscape = width > height
    local gap = Size.padding.default
    local p = self:current()
    local steps = p.steps or {}
    local st = steps[self.step]
    local side_w = landscape and math.floor(width * 0.45) or width

    local rows = {}
    if #self.parts > 1 then
        local tabs = {}
        for i, part in ipairs(self.parts) do
            tabs[#tabs + 1] = { text = (i == self.part and "★ " or "") .. part.title, callback = function()
                self:stop()
                self.part, self.step = i, 1
                self:refresh()
            end }
        end
        rows[#rows + 1] = tabs
    end
    rows[#rows + 1] = {
        { text = "‹", enabled = self.step > 1, callback = function() self:stop(); self:go(self.step - 1) end },
        { text = #steps > 0 and (self.step .. " / " .. #steps) or "–", enabled = false },
        { text = "›", enabled = self.step < #steps, callback = function() self:stop(); self:go(self.step + 1) end },
        { text = self.playing and "Stop" or "Play", enabled = #steps > 1, callback = function() self:togglePlay() end },
        { text = "Back", callback = function() self:onClose() end },
    }
    local buttons = Common.buttonBar(rows, side_w, self)

    local headline = Common.paragraph(p.headline or "", side_w, 20, { bold = true })
    local caption = Common.paragraph(st and st.caption or "", side_w, 18, { bold = true, height = Common.scale(52) })
    -- the text as tall as it needs, up to a limit (the board gets the rest)
    local text_h = landscape and math.floor(height * 0.45) or Common.scale(150)
    local text = Common.paragraph(p.text or "", side_w, 17)
    if text:getSize().h > text_h then text = Common.paragraph(p.text or "", side_w, 17, { height = text_h }) end

    local used = headline:getSize().h + text:getSize().h + caption:getSize().h + buttons:getSize().h + 5 * gap
    local board_size = landscape and height or math.min(width, height - used)
    board_size = board_size - board_size % 8
    if not self.board or self.board.size ~= board_size then
        if self.board then self.board:free() end
        self.board = BoardWidget:new{
            size = board_size,
            plugin_dir = self.plugin.path,
            show_parent = self,
            interactive = false,
            show_legal = false,
            show_coords = Store.get("show_coordinates"),
            dark_color = Store.get("board_dark"),
        }
    end
    self.board.interactive = false
    self.board.flipped = self.flipped
    self.board.game = st and st.game or p.start
    self.board:setArrows(st and st.arrows)
    self.board:setMarks(st and st.marks)
    self.board:setBadge(st and st.badge and st.badge.square, st and st.badge and st.badge.class)

    if landscape then
        return HorizontalGroup:new{ align = "top", self.board, Common.hspace(2 * gap),
            VerticalGroup:new{ align = "left", headline, Common.vspace(gap), text, Common.vspace(gap), caption,
                Common.vspace(gap), buttons } }
    end
    return VerticalGroup:new{
        align = "center",
        headline, Common.vspace(gap), text, Common.vspace(gap),
        self.board, Common.vspace(gap), caption, Common.vspace(gap), buttons,
    }
end

function ExplainPage:go(i)
    local n = #(self:current().steps or {})
    self.step = math.max(1, math.min(n, i))
    self:refresh("ui")
end

function ExplainPage:stop() self.playing = false end

function ExplainPage:togglePlay()
    if self.playing then
        self.playing = false
        return self:refresh()
    end
    self.playing = true
    if self.step >= #(self:current().steps or {}) then self.step = 1 end
    self:refresh("ui")
    local function tick()
        if self.closed or not self.playing then return end
        if self.step >= #self:current().steps then
            self.playing = false
            return self:refresh()
        end
        self:go(self.step + 1)
        UIManager:scheduleIn(PLAY_DELAY, tick)
    end
    UIManager:scheduleIn(PLAY_DELAY, tick)
end

function ExplainPage:onClose()
    self.closed = true
    self.playing = false
    if self.board then self.board:free() end
    return Common.Page.onClose(self)
end

return ExplainPage
