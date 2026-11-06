--[[
Full-screen list of the moves of a game, one row per move number, in plain
words (or chess notation) with the review symbols. With on_pick, tapping a
move jumps there, like tapping a move in the lichess move list.
--]]

local ButtonTable = require("ui/widget/buttontable")
local VerticalGroup = require("ui/widget/verticalgroup")
local Chess = require("chessuite/chess")
local Coach = require("chessuite/coach")
local Common = require("chessuite/ui/common")
local Describe = require("chessuite/describe")
local Store = require("chessuite/store")

local MoveListPage = Common.Page:extend{
    game = nil,
    judgements = nil, -- [ply] = { class = ... }
    current = nil,    -- ply to mark
    on_pick = nil,    -- function(ply)
}

-- Rows of { number = "12.", white = {ply, text}, black = {ply, text} }.
function MoveListPage.rows(game, judgements)
    local words = Store.get("move_words")
    local replay = Chess.new(game.start_fen)
    local rows = {}
    for ply, u in ipairs(game:uciHistory()) do
        local m = replay:moveFromUci(u)
        if not m then break end
        local text = words and Describe.move(replay, m, { no_check = true }) or replay:san(m)
        local j = judgements and judgements[ply]
        if j and j.class then
            local sym = Coach.symbol(j.class)
            if sym ~= "" then text = text .. " " .. sym end
        end
        local entry = { ply = ply, text = text }
        if replay.turn == "w" or #rows == 0 then
            rows[#rows + 1] = { number = replay.fullmove .. "." }
        end
        rows[#rows][replay.turn == "w" and "white" or "black"] = entry
        replay:makeMove(m)
    end
    return rows
end

-- Plain text lines, e.g. "3. Knight to f3 · Pawn to d6 ?!".
function MoveListPage.lines(game, judgements)
    local out = {}
    for _, r in ipairs(MoveListPage.rows(game, judgements)) do
        out[#out + 1] = r.number .. " " .. (r.white and r.white.text or "…")
            .. (r.black and ("  ·  " .. r.black.text) or "")
    end
    return out
end

function MoveListPage:init()
    self.all_rows = MoveListPage.rows(self.game, self.judgements)
    self.page = nil
    Common.Page.init(self)
end

function MoveListPage:buildContent(width, height)
    local rows = self.all_rows
    if #rows == 0 then return Common.paragraph("No moves yet.", width, 20) end
    local row_h = Common.scale(42)
    local per_page = math.max(4, math.floor((height - 2 * row_h) / row_h))
    local pages = math.ceil(#rows / per_page)
    if not self.page then
        -- open on the page with the current move
        local cur_row = 1
        for i, r in ipairs(rows) do
            if (r.white and r.white.ply == self.current) or (r.black and r.black.ply == self.current) then cur_row = i end
        end
        self.page = math.ceil(cur_row / per_page)
    end
    self.page = math.max(1, math.min(self.page, pages))
    local function cell(entry)
        if not entry then return { text = "", enabled = false } end
        local text = entry.ply == self.current and ("[" .. entry.text .. "]") or entry.text
        return {
            text = text,
            enabled = self.on_pick ~= nil or entry.ply == self.current,
            callback = function()
                if not self.on_pick then return end
                self:onClose()
                self.on_pick(entry.ply)
            end,
        }
    end
    local buttons = {}
    for i = (self.page - 1) * per_page + 1, math.min(#rows, self.page * per_page) do
        local r = rows[i]
        buttons[#buttons + 1] = { { text = r.number, enabled = false }, cell(r.white), cell(r.black) }
    end
    local group = VerticalGroup:new{
        align = "left",
        ButtonTable:new{ width = width, buttons = buttons, zero_sep = true, show_parent = self },
    }
    if pages > 1 then
        group[#group + 1] = Common.vspace(Common.scale(10))
        group[#group + 1] = Common.buttonBar({ {
            { text = "‹", enabled = self.page > 1, callback = function() self.page = self.page - 1; self:refresh() end },
            { text = self.page .. " / " .. pages, enabled = false },
            { text = "›", enabled = self.page < pages, callback = function() self.page = self.page + 1; self:refresh() end },
        } }, width, self)
    end
    return group
end

return MoveListPage
