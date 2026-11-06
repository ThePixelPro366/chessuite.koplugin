--[[
Plain language descriptions of moves and simple tactical facts, so the
coach can say "Rook takes knight on e5" instead of "Rxe5".
--]]

local Chess = require("chessuite/chess")

local Describe = {}

local NAMES = Chess.PIECE_NAMES
local VALUE = { p = 1, n = 3, b = 3, r = 5, q = 9, k = 100 }
local sq = Chess.squareName
local typeOf, colorOf = Chess.typeOf, Chess.colorOf

local function cap(s) return (s:gsub("^%l", string.upper)) end
Describe.capitalize = cap

function Describe.pieceName(p) return NAMES[typeOf(p)] end

-- "rook on a1"
function Describe.pieceOn(game, square)
    local p = game.board[square]
    if not p then return sq(square) end
    return NAMES[typeOf(p)] .. " on " .. sq(square)
end

-- Plain description of a legal move in `game` (the position before the move).
-- opts.no_check: leave out ", check".
function Describe.move(game, m, opts)
    local s
    local name = NAMES[typeOf(m.piece)]
    if m.flags == "castle_k" then
        s = "King castles short (kingside)"
    elseif m.flags == "castle_q" then
        s = "King castles long (queenside)"
    elseif m.flags == "ep" then
        s = "Pawn takes pawn on " .. sq(m.to) .. " (en passant)"
    elseif m.captured then
        s = cap(name) .. " takes " .. NAMES[typeOf(m.captured)] .. " on " .. sq(m.to)
    else
        s = cap(name) .. " to " .. sq(m.to)
    end
    if m.promotion then
        s = s .. " and becomes a " .. NAMES[m.promotion]
    end
    -- say which piece moves when two of the same kind could go there
    if typeOf(m.piece) ~= "p" and typeOf(m.piece) ~= "k" then
        for _, o in ipairs(game:moves()) do
            if o.piece == m.piece and o.to == m.to and o.from ~= m.from then
                s = s:gsub("^(%a+)", "%1 from " .. sq(m.from), 1)
                break
            end
        end
    end
    if not (opts and opts.no_check) then
        game:makeMove(m)
        if game:inCheck() then
            s = s .. (#game:moves() == 0 and ", checkmate" or ", check")
        end
        game:unmakeMove()
    end
    return s
end

function Describe.uciMove(game, uci, opts)
    local m = game:moveFromUci(uci)
    if not m then return uci end
    return Describe.move(game, m, opts)
end

-- Describes a sequence of UCI moves, e.g. for "Your opponent can then play ...".
function Describe.line(game, ucis, max_moves)
    local g = game:clone()
    local parts = {}
    for i, u in ipairs(ucis) do
        if max_moves and i > max_moves then break end
        local m = g:moveFromUci(u)
        if not m then break end
        local who = g.turn == game.turn and "" or "then "
        parts[#parts + 1] = who .. Describe.move(g, m):gsub("^%u", string.lower)
        g:makeMove(m)
    end
    if #parts == 0 then return "" end
    return cap(table.concat(parts, ", "))
end

-- Facts ----------------------------------------------------------------------

local function isDefended(game, square, owner)
    -- remove the piece temporarily so x-ray style defence counts like a recapture
    return #game:attackers(square, owner) > 0
end

-- Pieces of `color` (no pawns, no king) that can be taken for free or by a
-- cheaper piece. Most valuable first.
function Describe.hangingPieces(game, color, include_pawns)
    local list = {}
    local them = Chess.opposite(color)
    for s = 0, 119 do
        local p = Chess.onBoard(s) and game.board[s]
        if p and colorOf(p) == color and typeOf(p) ~= "k" and (include_pawns or typeOf(p) ~= "p") then
            local attackers = game:attackers(s, them)
            if #attackers > 0 then
                local cheapest = 1000
                for _, a in ipairs(attackers) do
                    local v = VALUE[typeOf(game.board[a])]
                    if v < cheapest then cheapest = v end
                end
                local v = VALUE[typeOf(p)]
                if not isDefended(game, s, color) or cheapest < v then
                    list[#list + 1] = { square = s, piece = p, value = v }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.value > b.value end)
    return list
end

-- Enemy pieces the piece on `from` attacks that matter: the king, undefended
-- pieces, or pieces worth more than the attacker.
local function targetsOf(game, from)
    local piece = game.board[from]
    if not piece then return {} end
    local us = colorOf(piece)
    local them = Chess.opposite(us)
    local mv = VALUE[typeOf(piece)]
    local out = {}
    for s = 0, 119 do
        local p = Chess.onBoard(s) and game.board[s]
        if p and colorOf(p) == them and typeOf(p) ~= "p" then
            local attacks = false
            for _, a in ipairs(game:attackers(s, us)) do
                if a == from then attacks = true break end
            end
            if attacks then
                local v = VALUE[typeOf(p)]
                if typeOf(p) == "k" or v > mv or not isDefended(game, s, them) then
                    out[#out + 1] = { square = s, piece = p, value = v }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.value > b.value end)
    return out
end

local function theName(game, s)
    local p = game.board[s]
    if typeOf(p) == "k" then return "the king" end
    return "the " .. NAMES[typeOf(p)] .. " on " .. sq(s)
end

-- What a move does, most important first ("checkmate", "forks the king and
-- the queen on d8", ...). `game` is the position before the move.
function Describe.reasons(game, m)
    local out = {}
    local us = game.turn
    local them = Chess.opposite(us)
    local was_check = game:inCheck()
    game:makeMove(m)
    local gives_check = game:inCheck()
    if gives_check and #game:moves() == 0 then
        game:unmakeMove()
        return { "gives checkmate" }
    end
    local name = NAMES[typeOf(m.piece)]
    if m.captured and m.flags ~= "ep" then
        local victim = NAMES[typeOf(m.captured)]
        local recapture = #game:attackers(m.to, them) > 0
        local vv, mv = VALUE[typeOf(m.captured)], VALUE[typeOf(m.piece)]
        if not recapture then
            out[#out + 1] = "wins the " .. victim .. " for free"
        elseif vv > mv then
            out[#out + 1] = "wins the " .. victim .. " for the " .. name
        elseif vv == mv then
            out[#out + 1] = typeOf(m.captured) == typeOf(m.piece) and ("trades " .. name .. "s")
                or ("trades the " .. name .. " for the " .. victim)
        else
            out[#out + 1] = "gives up the " .. name .. " for the " .. victim
        end
    end
    if was_check then
        if typeOf(m.piece) == "k" then out[#out + 1] = "gets the king out of check"
        elseif m.captured then out[#out + 1] = "takes the checking piece"
        else out[#out + 1] = "blocks the check" end
    end
    if gives_check then out[#out + 1] = "gives check" end
    local targets = targetsOf(game, m.to)
    local real = {}
    for _, t in ipairs(targets) do
        if typeOf(t.piece) ~= "k" or gives_check then real[#real + 1] = t end
    end
    if #real >= 2 then
        out[#out + 1] = "attacks " .. theName(game, real[1].square) .. " and " .. theName(game, real[2].square)
            .. " at the same time (a fork)"
    elseif #real == 1 and typeOf(real[1].piece) ~= "k" then
        out[#out + 1] = "attacks " .. theName(game, real[1].square)
    end
    if m.flags == "castle_k" or m.flags == "castle_q" then
        out[#out + 1] = "brings the king to safety"
    end
    if m.promotion then out[#out + 1] = "makes a new " .. NAMES[m.promotion] end
    game:unmakeMove()
    return out
end

function Describe.joinReasons(list, max)
    max = max or 2
    local parts = {}
    for i = 1, math.min(max, #list) do parts[i] = list[i] end
    if #parts == 0 then return nil end
    if #parts == 1 then return parts[1] end
    return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

return Describe
