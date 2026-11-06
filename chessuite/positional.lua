--[[
Positional reasons from Stockfish 11's own evaluation: the engine scores a
position term by term (king safety, mobility, threats, passed pawns, space,
pawn structure, piece placement). Comparing the terms before a move and
after the opponent's best answer shows what the move gave away, when no
tactic explains it ("it weakens your king", "it gives your opponent a passed
pawn on d4"). Stockfish 11 is the last version with this hand-written
evaluation, so the terms mean something a player can understand.
--]]

local Chess = require("chessuite/chess")

local Positional = {}

local typ, colorOf, opposite = Chess.typeOf, Chess.colorOf, Chess.opposite
local sqn = Chess.squareName

-- Words for each term, when it gets worse for the player ("mine") or better
-- for the opponent ("theirs").
local WORDS = {
    ["King safety"] = { mine = "it weakens your king's shelter", theirs = "it lets your opponent's king get safer" },
    Mobility = { mine = "your pieces get less room to move", theirs = "your opponent's pieces get more active" },
    Threats = { mine = "your pieces get harder to defend", theirs = "your opponent gets dangerous threats" },
    Passed = { mine = "your passed pawn loses its power", theirs = "your opponent gets a dangerous passed pawn" },
    Space = { mine = "you give up space in the centre", theirs = "your opponent gains space in the centre" },
    Pawns = { mine = "it weakens your pawns", theirs = "your opponent's pawns get stronger" },
    Knights = { mine = "your knight ends up on a poor square", theirs = "your opponent's knight gets a great square" },
    Bishops = { mine = "your bishop gets blocked in", theirs = "your opponent's bishop gets stronger" },
    Rooks = { mine = "your rook gets less active", theirs = "your opponent's rook gets active" },
    Queens = { mine = "your queen gets misplaced", theirs = "your opponent's queen gets active" },
    Imbalance = { mine = "the trade leaves you with the worse pieces", theirs = "the trade suits your opponent's pieces" },
}

local TERMS = { "King safety", "Threats", "Passed", "Mobility", "Pawns", "Space", "Knights", "Bishops", "Rooks", "Queens" }

-- Middlegame or endgame weight from the material on the board (0..1).
local function middlegameWeight(game)
    local npm = 0
    local V = { n = 3, b = 3, r = 5, q = 9 }
    for sq = 0, 119 do
        local p = Chess.onBoard(sq) and game.board[sq]
        if p and V[typ(p)] then npm = npm + V[typ(p)] end
    end
    return math.max(0, math.min(1, (npm - 10) / 52))
end

local function blend(pair, w)
    if not pair or not pair[1] or not pair[2] then return nil end
    return pair[1] * w + pair[2] * (1 - w)
end

--[[
The term that got worse the most for `color` between two evaluations
(before the move, and after the move and the opponent's answer). Returns
nil or { term, side = "mine" | "theirs", loss (pawns), words }.
--]]
function Positional.worst(before, after, color, game)
    if not before or not after then return nil end
    local w = middlegameWeight(game)
    local me = color == "w" and "white" or "black"
    local them = color == "w" and "black" or "white"
    local best
    for _, term in ipairs(TERMS) do
        local b, a = before[term], after[term]
        if b and a then
            local mine = (blend(a[me], w) or 0) - (blend(b[me], w) or 0)
            local theirs = (blend(a[them], w) or 0) - (blend(b[them], w) or 0)
            -- per side when the engine splits it, else the total from White's side
            local loss_mine, loss_theirs = -mine, theirs
            if not blend(a[me], w) then
                local t = (blend(a.total, w) or 0) - (blend(b.total, w) or 0)
                if color == "b" then t = -t end
                loss_mine, loss_theirs = -t, 0
            end
            for side, loss in pairs({ mine = loss_mine, theirs = loss_theirs }) do
                if loss >= 0.3 and (not best or loss > best.loss) then
                    best = { term = term, side = side, loss = loss }
                end
            end
        end
    end
    if best then best.words = WORDS[best.term] and WORDS[best.term][best.side] end
    return best and best.words and best or nil
end

-- Pawns of `color` with no enemy pawn in front of them on their file or the next ones.
function Positional.passedPawns(game, color)
    local out = {}
    local dir = color == "w" and 1 or -1
    for sq = 0, 119 do
        local p = Chess.onBoard(sq) and game.board[sq]
        if p and typ(p) == "p" and colorOf(p) == color then
            local f, r = sq % 16, math.floor(sq / 16)
            local free = true
            for df = -1, 1 do
                local x = f + df
                if x >= 0 and x <= 7 then
                    local rr = r + dir
                    while rr >= 0 and rr <= 7 do
                        local q = game.board[rr * 16 + x]
                        if q and typ(q) == "p" and colorOf(q) ~= color then free = false end
                        rr = rr + dir
                    end
                end
            end
            if free then out[#out + 1] = sq end
        end
    end
    return out
end

-- The squares to point at on the board for a reason, in the position after.
function Positional.squares(reason, game, color)
    local marks = {}
    if reason.term == "King safety" then
        local k = game.kings[reason.side == "mine" and color or opposite(color)]
        if k then marks[k] = "target" end
    elseif reason.term == "Passed" then
        local owner = reason.side == "mine" and color or opposite(color)
        for _, sq in ipairs(Positional.passedPawns(game, owner)) do marks[sq] = "target" end
    elseif reason.term == "Threats" then
        -- the player's pieces that are attacked
        for sq = 0, 119 do
            local p = Chess.onBoard(sq) and game.board[sq]
            if p and colorOf(p) == color and typ(p) ~= "k" and typ(p) ~= "p"
                and #game:attackers(sq, opposite(color)) > 0 then
                marks[sq] = "target"
            end
        end
    end
    return marks
end

-- A sentence with the detail: "it gives your opponent a passed pawn on d4".
function Positional.sentence(reason, game, color)
    if reason.term == "Passed" and reason.side == "theirs" then
        local passed = Positional.passedPawns(game, opposite(color))
        if #passed > 0 then
            local names = {}
            for _, sq in ipairs(passed) do names[#names + 1] = sqn(sq) end
            return "your opponent gets a dangerous passed pawn on " .. table.concat(names, " and ")
        end
    end
    return reason.words
end

return Positional
