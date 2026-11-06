--[[
Names the tactic in a line of moves, and says which pieces and squares take
part, so the coach can explain it and draw it.

A port of the Lichess puzzle tagger (lichess-puzzler, tagger/cook.py and
util.py, by Thibault Duplessis and contributors, AGPL-3.0,
https://github.com/ornicar/lichess-puzzler), which names the themes of every
Lichess puzzle. A Lichess puzzle is "a move, then the line that punishes
it", which is exactly what the coach has after a mistake: the player's move,
then the engine's best line for the opponent.

    local t = Tactics.analyse(game_before, { "e2e4", "d8h4", ... })
    t.tags     -- { "fork", "hangingPiece", ... } like the Lichess themes
    t.found    -- details, most telling first: { kind, ply, pieces and squares }
    t.mate     -- moves to mate when the line ends in checkmate

Squares are 0x88 indices like in chessuite/chess.lua. In the line, move 1 is
the move being punished; the punishing side ("pov") plays moves 2, 4, 6...
--]]

local Chess = require("chessuite/chess")

local Tactics = {}

local VALUES = { p = 1, n = 3, b = 3, r = 5, q = 9, k = 0 }
local KING_VALUES = { p = 1, n = 3, b = 3, r = 5, q = 9, k = 99 }
-- python-chess piece type numbers (cook.py compares a value with one of these once)
local PIECE_TYPE = { p = 1, n = 2, b = 3, r = 4, q = 5, k = 6 }
local RAY = { b = true, r = true, q = true }

local KNIGHT = { 33, 31, 18, 14, -33, -31, -18, -14 }
local DIAG = { 15, 17, -15, -17 }
local ORTH = { 16, 1, -16, -1 }
local KING = { 15, 16, 17, 1, -15, -16, -17, -1 }

local onBoard = Chess.onBoard
local colorOf = Chess.colorOf
local opposite = Chess.opposite
local function typ(p) return p and p:lower() end
local function rank(sq) return math.floor(sq / 16) end
local function file(sq) return sq % 16 end
local function distance(a, b) return math.max(math.abs(rank(a) - rank(b)), math.abs(file(a) - file(b))) end
local function contains(list, x)
    for _, v in ipairs(list) do if v == x then return true end end
    return false
end

-- Board helpers (util.py) -------------------------------------------------------------

-- The squares the piece on `sq` attacks.
local function attacksFrom(g, sq)
    local p = g.board[sq]
    if not p then return {} end
    local t, out = typ(p), {}
    local function add(s) if onBoard(s) then out[#out + 1] = s end end
    if t == "p" then
        local d = colorOf(p) == "w" and 16 or -16
        add(sq + d - 1)
        add(sq + d + 1)
    elseif t == "n" then
        for _, d in ipairs(KNIGHT) do add(sq + d) end
    elseif t == "k" then
        for _, d in ipairs(KING) do add(sq + d) end
    else
        local dirs = t == "b" and DIAG or t == "r" and ORTH or KING
        for _, d in ipairs(dirs) do
            local s = sq + d
            while onBoard(s) do
                out[#out + 1] = s
                if g.board[s] then break end
                s = s + d
            end
        end
    end
    return out
end
Tactics.attacksFrom = attacksFrom

local function attackers(g, color, sq) return g:attackers(sq, color) end

-- The squares strictly between two squares on one line, or none.
local function between(a, b)
    local dr, df = rank(b) - rank(a), file(b) - file(a)
    if not (dr == 0 or df == 0 or math.abs(dr) == math.abs(df)) or a == b then return {} end
    local step = (dr > 0 and 16 or dr < 0 and -16 or 0) + (df > 0 and 1 or df < 0 and -1 or 0)
    local out = {}
    local s = a + step
    while s ~= b do
        out[#out + 1] = s
        s = s + step
    end
    return out
end
Tactics.between = between

local function withoutPiece(g, sq)
    local c = g:clone()
    c.board[sq] = nil
    return c
end

local function isDefended(g, piece, sq)
    local color = colorOf(piece)
    if #attackers(g, color, sq) > 0 then return true end
    -- defended through the attacker (x-ray)
    for _, a in ipairs(attackers(g, opposite(color), sq)) do
        if RAY[typ(g.board[a])] then
            if #attackers(withoutPiece(g, a), color, sq) > 0 then return true end
        end
    end
    return false
end

local function isHanging(g, piece, sq) return not isDefended(g, piece, sq) end

local function canBeTakenByLower(g, piece, sq)
    for _, a in ipairs(attackers(g, opposite(colorOf(piece)), sq)) do
        local t = typ(g.board[a])
        if t ~= "k" and VALUES[t] < VALUES[typ(piece)] then return true end
    end
    return false
end

-- Hanging, or can be taken by a cheaper piece.
local function isInBadSpot(g, sq)
    local piece = g.board[sq]
    if not piece then return false end
    return #attackers(g, opposite(colorOf(piece)), sq) > 0
        and (isHanging(g, piece, sq) or canBeTakenByLower(g, piece, sq))
end

-- When the piece on `sq` is pinned to its king: the pinning piece and the
-- line through the king (a set of squares).
local function pinOf(g, color, sq)
    local king = g.kings[color]
    if not king or king == sq then return nil end
    local dr, df = rank(sq) - rank(king), file(sq) - file(king)
    local diag = math.abs(dr) == math.abs(df)
    if not (dr == 0 or df == 0 or diag) then return nil end
    local step = (dr > 0 and 16 or dr < 0 and -16 or 0) + (df > 0 and 1 or df < 0 and -1 or 0)
    local s = king + step
    while s ~= sq do
        if g.board[s] then return nil end
        s = s + step
    end
    s = sq + step
    while onBoard(s) do
        local p = g.board[s]
        if p then
            local t = typ(p)
            if colorOf(p) ~= color and (t == "q" or (diag and t == "b") or (not diag and t == "r")) then
                -- the whole line, both ways from the king
                local line = {}
                for _, d in ipairs({ step, -step }) do
                    local x = king + d
                    while onBoard(x) do
                        line[x] = true
                        x = x + d
                    end
                end
                return s, line
            end
            return nil
        end
        s = s + step
    end
    return nil
end
Tactics.pinOf = pinOf

local function isPinned(g, color, sq) return pinOf(g, color, sq) ~= nil end

local function checkers(g)
    local king = g.kings[g.turn]
    if not king then return {} end
    return attackers(g, opposite(g.turn), king)
end

local function isTrapped(g, sq)
    if g:inCheck() or isPinned(g, g.turn, sq) then return false end
    local piece = g.board[sq]
    if not piece or typ(piece) == "p" or typ(piece) == "k" then return false end
    if not isInBadSpot(g, sq) then return false end
    for _, m in ipairs(g:moves({ square = sq })) do
        local capturing = g.board[m.to]
        if capturing and VALUES[typ(capturing)] >= VALUES[typ(piece)] then return false end
        g:makeMove(m)
        local bad = isInBadSpot(g, m.to)
        g:unmakeMove()
        if not bad then return false end
    end
    return true
end

local function materialCount(g, color)
    local n = 0
    for sq = 0, 119 do
        local p = onBoard(sq) and g.board[sq]
        if p and colorOf(p) == color then n = n + VALUES[typ(p)] end
    end
    return n
end
local function materialDiff(g, color) return materialCount(g, color) - materialCount(g, opposite(color)) end
Tactics.materialDiff = materialDiff

-- The line --------------------------------------------------------------------------

-- boards[0] is the position before move 1, boards[i] the one after move i.
local function buildLine(game, ucis)
    local L = { boards = { [0] = game:clone() }, moves = {} }
    local g = game:clone()
    for i, u in ipairs(ucis) do
        local m
        if u == "0000" then
            -- a pass (to look at a line from the other side)
            m = { from = -1, to = -1, null = true }
            g.turn = opposite(g.turn)
            g.ep = nil
        else
            m = g:moveFromUci(u)
            if not m then break end
            g:makeMove(m)
        end
        L.moves[i] = m
        L.boards[i] = g:clone()
    end
    L.n = #L.moves
    L.pov = opposite(game.turn)
    return L
end

local function movedType(L, i)
    if L.moves[i].null then return "k" end
    return typ(L.boards[i].board[L.moves[i].to])
end
local function isCapture(L, i) return L.moves[i].captured ~= nil end
local function isCastling(L, i)
    local m = L.moves[i]
    return not m.null and typ(m.piece) == "k" and distance(m.from, m.to) > 1
end
local function isAdvancedPawnMove(L, i)
    local m = L.moves[i]
    if m.promotion then return true end
    if movedType(L, i) ~= "p" then return false end
    local r = rank(m.to)
    if L.boards[i].turn == "w" then return r < 3 end -- a black pawn moved
    return r > 4
end
local function isVeryAdvancedPawnMove(L, i)
    if not isAdvancedPawnMove(L, i) then return false end
    local r = rank(L.moves[i].to)
    if L.boards[i].turn == "w" then return r < 2 end
    return r > 5
end

-- The punishing side's moves: 2, 4, 6 ... (from = 2 or 4 like [1::2] and [1::2][1:])
local function povMoves(L, from, drop_last)
    local out = {}
    for i = from, L.n, 2 do out[#out + 1] = i end
    if drop_last then out[#out] = nil end
    return out
end

-- Detectors (cook.py) -------------------------------------------------------------------
-- Each returns nil or a table with what the board should show.

local D = {}

function D.fork(L)
    for _, i in ipairs(povMoves(L, 2, true)) do
        local g, to = L.boards[i], L.moves[i].to
        if not isInBadSpot(g, to) then
            local targets = {}
            local mover = movedType(L, i)
            local defenders = attackers(g, opposite(L.pov), to)
            for _, sq in ipairs(attacksFrom(g, to)) do
                local p = g.board[sq]
                if p and colorOf(p) ~= L.pov and typ(p) ~= "p" then
                    if KING_VALUES[typ(p)] > KING_VALUES[mover]
                        or (isHanging(g, p, sq) and not contains(defenders, sq)) then
                        targets[#targets + 1] = sq
                    end
                end
            end
            if #targets > 1 then
                return { kind = "fork", ply = i, from = L.moves[i].from, piece = to, targets = targets }
            end
        end
    end
end

function D.hangingPiece(L)
    if L.n < 2 then return nil end
    local to = L.moves[2].to
    local b1 = L.boards[1]
    local captured = b1.board[to]
    if b1:inCheck() and (not captured or typ(captured) == "p") then return nil end
    if captured and typ(captured) ~= "p" and isHanging(b1, captured, to) then
        local op = L.moves[1]
        local op_capture = L.boards[0].board[op.to]
        if op_capture and VALUES[typ(op_capture)] >= VALUES[typ(captured)] and op.to == to then return nil end
        if L.n < 4 or materialDiff(L.boards[4], L.pov) >= materialDiff(L.boards[2], L.pov) then
            return { kind = "hangingPiece", ply = 2, piece = to, attacker = L.moves[2].from }
        end
    end
end

function D.trappedPiece(L)
    for _, i in ipairs(povMoves(L, 4)) do
        local sq = L.moves[i].to
        local captured = L.boards[i - 1].board[sq]
        if captured and typ(captured) ~= "p" then
            if L.moves[i - 1].to == sq then sq = L.moves[i - 1].from end
            if isTrapped(L.boards[i - 2], sq) then
                return { kind = "trappedPiece", ply = i, piece = sq }
            end
        end
    end
end

function D.discoveredCheck(L)
    for _, i in ipairs(povMoves(L, 2)) do
        local cs = checkers(L.boards[i])
        if #cs > 0 and not contains(cs, L.moves[i].to) then
            return { kind = "discoveredCheck", ply = i, moved = L.moves[i], revealed = cs[1],
                target = L.boards[i].kings[L.boards[i].turn] }
        end
    end
end

function D.discoveredAttack(L)
    local dc = D.discoveredCheck(L)
    if dc then return dc end
    for _, i in ipairs(povMoves(L, 4)) do
        if isCapture(L, i) then
            local m = L.moves[i]
            if L.moves[i - 1].to == m.to then return nil end
            local prev = L.moves[i - 2]
            if contains(between(m.from, m.to), prev.from) and m.to ~= prev.to and m.from ~= prev.to
                and not isCastling(L, i - 2) then
                return { kind = "discoveredAttack", ply = i - 2, moved = prev, revealed = m.from, target = m.to }
            end
        end
    end
end

function D.doubleCheck(L)
    for _, i in ipairs(povMoves(L, 2)) do
        local cs = checkers(L.boards[i])
        if #cs > 1 then return { kind = "doubleCheck", ply = i, checkers = cs } end
    end
end

function D.skewer(L)
    for _, i in ipairs(povMoves(L, 4)) do
        local prev = L.boards[i - 1]
        local m = L.moves[i]
        local capture = prev.board[m.to]
        if capture and RAY[movedType(L, i)] and not L.boards[i]:isCheckmate() then
            local op = L.moves[i - 1]
            if not (op.to == m.to or not contains(between(m.from, m.to), op.from)) then
                if KING_VALUES[movedType(L, i - 1)] > KING_VALUES[typ(capture)] and isInBadSpot(prev, m.to) then
                    return { kind = "skewer", ply = i - 2, attacker = m.from, front = op.from, behind = m.to,
                        front_move = op }
                end
            end
        end
    end
end

-- The pinned piece cannot take part: it may not attack, or may not run away.
function D.pin(L)
    for _, i in ipairs(povMoves(L, 2)) do
        local g = L.boards[i]
        for sq = 0, 119 do
            local piece = onBoard(sq) and g.board[sq]
            if piece and colorOf(piece) ~= L.pov then
                local pinner, line = pinOf(g, colorOf(piece), sq)
                if pinner then
                    local found
                    -- it cannot attack a player piece
                    for _, a in ipairs(attacksFrom(g, sq)) do
                        local attacked = g.board[a]
                        if attacked and colorOf(attacked) == L.pov and not line[a]
                            and (VALUES[typ(attacked)] > VALUES[typ(piece)] or isHanging(g, attacked, a)) then
                            found = true
                        end
                    end
                    -- or it cannot escape an attack
                    if not found then
                        for _, a in ipairs(attackers(g, L.pov, sq)) do
                            if line[a] then
                                if VALUES[typ(piece)] > VALUES[typ(g.board[a])] then found = true end
                                if not found and isHanging(g, piece, sq)
                                    and not contains(attackers(g, opposite(L.pov), a), sq) then
                                    for _, mv in ipairs(g:pseudoMoves()) do
                                        if mv.from == sq and not line[mv.to] then found = true break end
                                    end
                                end
                            end
                        end
                    end
                    if found then
                        return { kind = "pin", ply = i, pinned = sq, pinner = pinner,
                            behind = g.kings[colorOf(piece)] }
                    end
                end
            end
        end
    end
end

function D.attraction(L)
    for i = 2, L.n do
        if L.boards[i].turn ~= L.pov then
            local to = L.moves[i].to
            local reply = L.moves[i + 1]
            if reply and reply.to == to then
                local attracted = movedType(L, i + 1)
                if attracted == "k" or attracted == "q" or attracted == "r" then
                    local nxt = L.moves[i + 2]
                    if nxt and contains(attackers(L.boards[i + 2], L.pov, to), nxt.to) then
                        if attracted == "k" or (L.moves[i + 4] and L.moves[i + 4].to == to) then
                            return { kind = "attraction", ply = i, square = to, piece = reply.from }
                        end
                    end
                end
            end
        end
    end
end

function D.deflection(L)
    for _, i in ipairs(povMoves(L, 4)) do
        local m = L.moves[i]
        local captured = L.boards[i - 1].board[m.to]
        if captured or m.promotion then
            local capturing = movedType(L, i)
            if not (captured and KING_VALUES[typ(captured)] > KING_VALUES[capturing]) then
                local square = m.to
                local op = L.moves[i - 1]
                local pl = L.moves[i - 2]
                local pl_capture = L.boards[i - 3].board[pl.to]
                local gb = L.boards[i - 2]
                local defended = attacksFrom(gb, op.from)
                if (not pl_capture or VALUES[typ(pl_capture)] < PIECE_TYPE[movedType(L, i - 2)])
                    and square ~= op.to and square ~= pl.to
                    and (op.to == pl.to or gb:inCheck())
                    and (contains(defended, square)
                        or (m.promotion and file(m.to) == file(op.from) and contains(defended, m.from)))
                    and not contains(attacksFrom(L.boards[i - 1], op.to), square) then
                    return { kind = "deflection", ply = i - 2, defender = op.from, defender_to = op.to, square = square }
                end
            end
        end
    end
end

function D.capturingDefender(L)
    for _, i in ipairs(povMoves(L, 4)) do
        local g = L.boards[i]
        local m = L.moves[i]
        local capture = L.boards[i - 1].board[m.to]
        local mover = movedType(L, i)
        if g:isCheckmate() or (capture and mover ~= "k" and VALUES[typ(capture)] <= VALUES[mover]
            and isHanging(L.boards[i - 1], capture, m.to) and L.moves[i - 1].to ~= m.to) then
            local prev = L.moves[i - 2]
            if not L.boards[i - 2]:inCheck() and prev.to ~= m.from then
                local init = L.boards[i - 3]
                local dsq = prev.to
                local defender = init.board[dsq]
                if defender and contains(attackers(init, colorOf(defender), m.to), dsq) and not init:inCheck() then
                    return { kind = "capturingDefender", ply = i - 2, defender = dsq, square = m.to }
                end
            end
        end
    end
end

function D.intermezzo(L)
    for _, i in ipairs(povMoves(L, 4)) do
        if isCapture(L, i) then
            local m = L.moves[i]
            local sq = m.to
            local op = L.moves[i - 1]
            if not contains(attackers(L.boards[i - 2], opposite(L.pov), sq), op.from) then
                if L.moves[i - 2].to ~= sq then
                    local prev_op = L.moves[i - 3]
                    if prev_op and prev_op.to == sq and isCapture(L, i - 3) then
                        local legal = false
                        for _, lm in ipairs(L.boards[i - 3]:moves()) do
                            if lm.from == m.from and lm.to == m.to then legal = true end
                        end
                        if legal then return { kind = "intermezzo", ply = i - 2, square = sq } end
                    end
                    return nil
                end
            end
        end
    end
end

function D.promotion(L)
    for _, i in ipairs(povMoves(L, 2)) do
        if L.moves[i].promotion then return { kind = "promotion", ply = i, square = L.moves[i].to } end
    end
end

function D.advancedPawn(L)
    for _, i in ipairs(povMoves(L, 2)) do
        if isVeryAdvancedPawnMove(L, i) then return { kind = "advancedPawn", ply = i, square = L.moves[i].to } end
    end
end

function D.attackingF2F7(L)
    for _, i in ipairs(povMoves(L, 2)) do
        local sq = L.moves[i].to
        local name = Chess.squareName(sq)
        if L.boards[i - 1].board[sq] and (name == "f2" or name == "f7") then
            local k = L.boards[i].board[Chess.squareIndex(name == "f7" and "e8" or "e1")]
            if k and typ(k) == "k" and colorOf(k) ~= L.pov then return { kind = "attackingF2F7", ply = i, square = sq } end
            return nil
        end
    end
end

-- Mates (on the final position) --------------------------------------------------------

local function backRankMate(L)
    local g = L.boards[L.n]
    local them = opposite(L.pov)
    local king = g.kings[them]
    local back = L.pov == "w" and 7 or 0
    if not (g:isCheckmate() and rank(king) == back) then return false end
    local fwd = L.pov == "w" and -16 or 16
    local squares = { king + fwd }
    if file(king) < 7 then squares[#squares + 1] = king + fwd + 1 end
    if file(king) > 0 then squares[#squares + 1] = king + fwd - 1 end
    for _, s in ipairs(squares) do
        local p = g.board[s]
        if not p or colorOf(p) == L.pov or #attackers(g, L.pov, s) > 0 then return false end
    end
    for _, c in ipairs(checkers(g)) do
        if rank(c) == back then return true end
    end
    return false
end

local function smotheredMate(L)
    local g = L.boards[L.n]
    local king = g.kings[opposite(L.pov)]
    for _, c in ipairs(checkers(g)) do
        if typ(g.board[c]) == "n" then
            for _, d in ipairs(KING) do
                local s = king + d
                if onBoard(s) then
                    local b = g.board[s]
                    if not b or colorOf(b) == L.pov then return false end
                end
            end
            return true
        end
    end
    return false
end

-- Order: the most telling first, for the explanation.
local ORDER = { "fork", "doubleCheck", "discoveredAttack", "skewer", "pin", "trappedPiece", "deflection",
    "attraction", "capturingDefender", "intermezzo", "hangingPiece", "attackingF2F7", "promotion", "advancedPawn" }
Tactics.ORDER = ORDER

-- Analyses a line: game is the position before ucis[1].
function Tactics.analyse(game, ucis)
    local L = buildLine(game, ucis)
    local result = { tags = {}, found = {}, line = L }
    if L.n < 2 then return result end
    local last = L.boards[L.n]
    if last:isCheckmate() and last.turn ~= L.pov then
        result.mate = math.floor(L.n / 2)
        result.tags[#result.tags + 1] = "mate"
        result.tags[#result.tags + 1] = "mateIn" .. math.min(5, result.mate)
        if smotheredMate(L) then
            result.tags[#result.tags + 1] = "smotheredMate"
            result.mate_kind = "smotheredMate"
        elseif backRankMate(L) then
            result.tags[#result.tags + 1] = "backRankMate"
            result.mate_kind = "backRankMate"
        end
    end
    for _, name in ipairs(ORDER) do
        local ok, d = pcall(D[name], L)
        if ok and d then
            result.found[#result.found + 1] = d
            -- a discovered check is tagged discoveredAttack by Lichess
            result.tags[#result.tags + 1] = name
        end
    end
    return result
end

-- How long the line needs to be to show the point: up to the mate, or up to
-- where the material the punishing side wins is in the bag (the engine's
-- line goes on much longer). At least the reply (2 moves).
function Tactics.usefulLength(game, ucis, max)
    local L = buildLine(game, ucis)
    max = math.min(max or 10, L.n)
    if max < 2 then return max end
    local function settled(i)
        -- after the pov move i and the answer to it
        local j = math.min(i + 1, max)
        return materialDiff(L.boards[j], L.pov)
    end
    for i = 2, max do
        if L.boards[i]:isCheckmate() then return i end
    end
    local final = settled(max % 2 == 0 and max or max - 1)
    local start = materialDiff(L.boards[1], L.pov)
    if final - start < 1 then return 2 end
    for i = 2, max, 2 do
        if settled(i) >= final then return math.min(max, i + 1 <= max and L.moves[i + 1]
            and L.moves[i + 1].captured and i + 1 or i) end
    end
    return max
end

Tactics.buildLine = buildLine
return Tactics
