--[[
Pure Lua chess rules: legal move generation, FEN, SAN, UCI, PGN and
game end detection (checkmate, stalemate, fifty moves, threefold
repetition, insufficient material).

Squares are 0x88 indices: a1 = 0, h1 = 7, a2 = 16 ... h8 = 119.
Pieces are single letters, upper case for White ("P", "N", "B", "R",
"Q", "K") and lower case for Black.
--]]

local Chess = {}
Chess.__index = Chess

Chess.START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

local FILES = "abcdefgh"

local KNIGHT_OFFSETS = { 33, 31, 18, 14, -33, -31, -18, -14 }
local BISHOP_OFFSETS = { 15, 17, -15, -17 }
local ROOK_OFFSETS = { 16, 1, -16, -1 }
local KING_OFFSETS = { 15, 16, 17, 1, -15, -16, -17, -1 }

local PIECE_VALUE = { p = 1, n = 3, b = 3, r = 5, q = 9, k = 0 }
Chess.PIECE_VALUE = PIECE_VALUE

local PIECE_NAMES = { p = "pawn", n = "knight", b = "bishop", r = "rook", q = "queen", k = "king" }
Chess.PIECE_NAMES = PIECE_NAMES

local function onBoard(sq) return sq >= 0 and sq <= 119 and sq % 16 < 8 end
Chess.onBoard = onBoard

local function colorOf(p)
    if not p then return nil end
    return p == p:upper() and "w" or "b"
end
Chess.colorOf = colorOf

local function typeOf(p) return p and p:lower() end
Chess.typeOf = typeOf

local function opposite(c) return c == "w" and "b" or "w" end
Chess.opposite = opposite

function Chess.squareName(sq)
    local f = sq % 16
    local r = math.floor(sq / 16)
    return FILES:sub(f + 1, f + 1) .. tostring(r + 1)
end

function Chess.squareIndex(name)
    if type(name) ~= "string" or #name ~= 2 then return nil end
    local f = FILES:find(name:sub(1, 1), 1, true)
    local r = tonumber(name:sub(2, 2))
    if not f or not r or r < 1 or r > 8 then return nil end
    return (r - 1) * 16 + (f - 1)
end

function Chess.fileOf(sq) return sq % 16 end
function Chess.rankOf(sq) return math.floor(sq / 16) end

local squareName = Chess.squareName
local squareIndex = Chess.squareIndex

function Chess.new(fen)
    local self = setmetatable({}, Chess)
    local ok, err = self:load(fen or Chess.START_FEN)
    if not ok then return nil, err end
    return self
end

function Chess:clear()
    self.board = {}
    self.turn = "w"
    self.castling = { K = false, Q = false, k = false, q = false }
    self.ep = nil
    self.halfmove = 0
    self.fullmove = 1
    self.kings = { w = nil, b = nil }
    self.stack = {}
    self.repetition = {}
    self.start_fen = nil
end

function Chess:load(fen)
    if type(fen) ~= "string" then return false, "no FEN" end
    local parts = {}
    for token in fen:gmatch("%S+") do parts[#parts + 1] = token end
    if #parts < 4 then return false, "FEN needs at least 4 fields" end
    self:clear()
    local rank, file = 7, 0
    for i = 1, #parts[1] do
        local ch = parts[1]:sub(i, i)
        if ch == "/" then
            rank = rank - 1
            file = 0
        elseif ch:match("%d") then
            file = file + tonumber(ch)
        elseif ch:match("[pnbrqkPNBRQK]") then
            if file > 7 or rank < 0 then return false, "bad FEN board" end
            local sq = rank * 16 + file
            self.board[sq] = ch
            if ch == "K" then self.kings.w = sq elseif ch == "k" then self.kings.b = sq end
            file = file + 1
        else
            return false, "bad FEN character " .. ch
        end
    end
    if not self.kings.w or not self.kings.b then return false, "FEN needs both kings" end
    self.turn = parts[2] == "b" and "b" or "w"
    local c = parts[3] or "-"
    self.castling.K = c:find("K", 1, true) ~= nil
    self.castling.Q = c:find("Q", 1, true) ~= nil
    self.castling.k = c:find("k", 1, true) ~= nil
    self.castling.q = c:find("q", 1, true) ~= nil
    -- castling rights only make sense with king and rook on their start squares
    if self.board[4] ~= "K" then self.castling.K, self.castling.Q = false, false end
    if self.board[116] ~= "k" then self.castling.k, self.castling.q = false, false end
    if self.board[7] ~= "R" then self.castling.K = false end
    if self.board[0] ~= "R" then self.castling.Q = false end
    if self.board[119] ~= "r" then self.castling.k = false end
    if self.board[112] ~= "r" then self.castling.q = false end
    self.ep = parts[4] ~= "-" and squareIndex(parts[4]) or nil
    self.halfmove = tonumber(parts[5] or "0") or 0
    self.fullmove = tonumber(parts[6] or "1") or 1
    self.start_fen = self:fen()
    self:recordPosition()
    return true
end

function Chess:clone()
    local c = setmetatable({}, Chess)
    c.board = {}
    for k, v in pairs(self.board) do c.board[k] = v end
    c.turn = self.turn
    c.castling = { K = self.castling.K, Q = self.castling.Q, k = self.castling.k, q = self.castling.q }
    c.ep = self.ep
    c.halfmove = self.halfmove
    c.fullmove = self.fullmove
    c.kings = { w = self.kings.w, b = self.kings.b }
    c.stack = {}
    for i, v in ipairs(self.stack) do c.stack[i] = v end
    c.repetition = {}
    for k, v in pairs(self.repetition) do c.repetition[k] = v end
    c.start_fen = self.start_fen
    return c
end

function Chess:get(sq)
    if type(sq) == "string" then sq = squareIndex(sq) end
    return sq and self.board[sq]
end

-- The en passant square is only written when a capture is actually possible,
-- like most GUIs do, so repetition keys stay comparable.
function Chess:epForFen()
    if not self.ep then return nil end
    local pawn = self.turn == "w" and "P" or "p"
    local dir = self.turn == "w" and -16 or 16
    for _, d in ipairs({ -1, 1 }) do
        local sq = self.ep + dir + d
        if onBoard(sq) and self.board[sq] == pawn then return self.ep end
    end
    return nil
end

function Chess:positionKey()
    local rows = {}
    for rank = 7, 0, -1 do
        local row, empty = {}, 0
        for file = 0, 7 do
            local p = self.board[rank * 16 + file]
            if p then
                if empty > 0 then row[#row + 1] = tostring(empty); empty = 0 end
                row[#row + 1] = p
            else
                empty = empty + 1
            end
        end
        if empty > 0 then row[#row + 1] = tostring(empty) end
        rows[#rows + 1] = table.concat(row)
    end
    local c = (self.castling.K and "K" or "") .. (self.castling.Q and "Q" or "")
        .. (self.castling.k and "k" or "") .. (self.castling.q and "q" or "")
    if c == "" then c = "-" end
    local ep = self:epForFen()
    return table.concat(rows, "/") .. " " .. self.turn .. " " .. c .. " " .. (ep and squareName(ep) or "-")
end

function Chess:fen()
    return self:positionKey() .. " " .. self.halfmove .. " " .. self.fullmove
end

function Chess:recordPosition()
    local key = self:positionKey()
    self.repetition[key] = (self.repetition[key] or 0) + 1
end

-- Attack detection -----------------------------------------------------------

function Chess:isAttacked(sq, by)
    local board = self.board
    -- pawns
    if by == "w" then
        for _, d in ipairs({ -15, -17 }) do
            local s = sq + d
            if onBoard(s) and board[s] == "P" then return true end
        end
    else
        for _, d in ipairs({ 15, 17 }) do
            local s = sq + d
            if onBoard(s) and board[s] == "p" then return true end
        end
    end
    local knight = by == "w" and "N" or "n"
    for _, d in ipairs(KNIGHT_OFFSETS) do
        local s = sq + d
        if onBoard(s) and board[s] == knight then return true end
    end
    local king = by == "w" and "K" or "k"
    for _, d in ipairs(KING_OFFSETS) do
        local s = sq + d
        if onBoard(s) and board[s] == king then return true end
    end
    local bishop, rook, queen
    if by == "w" then bishop, rook, queen = "B", "R", "Q" else bishop, rook, queen = "b", "r", "q" end
    for _, d in ipairs(BISHOP_OFFSETS) do
        local s = sq + d
        while onBoard(s) do
            local p = board[s]
            if p then
                if p == bishop or p == queen then return true end
                break
            end
            s = s + d
        end
    end
    for _, d in ipairs(ROOK_OFFSETS) do
        local s = sq + d
        while onBoard(s) do
            local p = board[s]
            if p then
                if p == rook or p == queen then return true end
                break
            end
            s = s + d
        end
    end
    return false
end

-- All squares of pieces of colour `by` that attack `sq`.
function Chess:attackers(sq, by)
    local result = {}
    local board = self.board
    for s = 0, 119 do
        local p = onBoard(s) and board[s]
        if p and colorOf(p) == by then
            local t = typeOf(p)
            local diff = sq - s
            if t == "p" then
                local dirs = by == "w" and { 15, 17 } or { -15, -17 }
                for _, d in ipairs(dirs) do
                    if diff == d then result[#result + 1] = s end
                end
            elseif t == "n" then
                for _, d in ipairs(KNIGHT_OFFSETS) do
                    if diff == d then result[#result + 1] = s end
                end
            elseif t == "k" then
                for _, d in ipairs(KING_OFFSETS) do
                    if diff == d then result[#result + 1] = s end
                end
            else
                local offsets = t == "b" and BISHOP_OFFSETS or t == "r" and ROOK_OFFSETS or KING_OFFSETS
                for _, d in ipairs(offsets) do
                    local x = s + d
                    while onBoard(x) do
                        if x == sq then result[#result + 1] = s; break end
                        if board[x] then break end
                        x = x + d
                    end
                end
            end
        end
    end
    return result
end

function Chess:inCheck(color)
    color = color or self.turn
    return self:isAttacked(self.kings[color], opposite(color))
end

-- Move generation ------------------------------------------------------------

local function addMove(list, from, to, piece, captured, flags, promotion)
    list[#list + 1] = { from = from, to = to, piece = piece, captured = captured, flags = flags, promotion = promotion }
end

function Chess:pseudoMoves()
    local list = {}
    local board = self.board
    local us = self.turn
    local them = opposite(us)
    for sq = 0, 119 do
        local p = onBoard(sq) and board[sq]
        if p and colorOf(p) == us then
            local t = typeOf(p)
            if t == "p" then
                local dir = us == "w" and 16 or -16
                local startRank = us == "w" and 1 or 6
                local lastRank = us == "w" and 7 or 0
                local to = sq + dir
                if onBoard(to) and not board[to] then
                    if math.floor(to / 16) == lastRank then
                        for _, promo in ipairs({ "q", "r", "b", "n" }) do
                            addMove(list, sq, to, p, nil, "promotion", promo)
                        end
                    else
                        addMove(list, sq, to, p, nil, "normal")
                        local to2 = to + dir
                        if math.floor(sq / 16) == startRank and not board[to2] then
                            addMove(list, sq, to2, p, nil, "double")
                        end
                    end
                end
                for _, side in ipairs({ -1, 1 }) do
                    local cap = sq + dir + side
                    if onBoard(cap) then
                        local target = board[cap]
                        if target and colorOf(target) == them then
                            if math.floor(cap / 16) == lastRank then
                                for _, promo in ipairs({ "q", "r", "b", "n" }) do
                                    addMove(list, sq, cap, p, target, "promotion", promo)
                                end
                            else
                                addMove(list, sq, cap, p, target, "capture")
                            end
                        elseif cap == self.ep then
                            addMove(list, sq, cap, p, us == "w" and "p" or "P", "ep")
                        end
                    end
                end
            else
                local offsets, slide
                if t == "n" then offsets, slide = KNIGHT_OFFSETS, false
                elseif t == "b" then offsets, slide = BISHOP_OFFSETS, true
                elseif t == "r" then offsets, slide = ROOK_OFFSETS, true
                elseif t == "q" then offsets, slide = KING_OFFSETS, true
                else offsets, slide = KING_OFFSETS, false end
                for _, d in ipairs(offsets) do
                    local to = sq + d
                    while onBoard(to) do
                        local target = board[to]
                        if target then
                            if colorOf(target) == them then
                                addMove(list, sq, to, p, target, "capture")
                            end
                            break
                        end
                        addMove(list, sq, to, p, nil, "normal")
                        if not slide then break end
                        to = to + d
                    end
                end
                if t == "k" then
                    local home = us == "w" and 4 or 116
                    if sq == home and not self:isAttacked(sq, them) then
                        local ks = us == "w" and "K" or "k"
                        local qs = us == "w" and "Q" or "q"
                        if self.castling[ks] and not board[sq + 1] and not board[sq + 2]
                            and not self:isAttacked(sq + 1, them) and not self:isAttacked(sq + 2, them) then
                            addMove(list, sq, sq + 2, p, nil, "castle_k")
                        end
                        if self.castling[qs] and not board[sq - 1] and not board[sq - 2] and not board[sq - 3]
                            and not self:isAttacked(sq - 1, them) and not self:isAttacked(sq - 2, them) then
                            addMove(list, sq, sq - 2, p, nil, "castle_q")
                        end
                    end
                end
            end
        end
    end
    return list
end

local CASTLE_ROOK_SQUARES = { [0] = "Q", [7] = "K", [112] = "q", [119] = "k" }

-- Applies a move without legality checks; pushes undo data on the stack.
function Chess:makeMove(m)
    local board = self.board
    local us = self.turn
    local undo = {
        move = m,
        castling = { K = self.castling.K, Q = self.castling.Q, k = self.castling.k, q = self.castling.q },
        ep = self.ep,
        halfmove = self.halfmove,
        fullmove = self.fullmove,
        kings = { w = self.kings.w, b = self.kings.b },
    }
    board[m.to] = m.promotion and (us == "w" and m.promotion:upper() or m.promotion) or m.piece
    board[m.from] = nil
    if m.flags == "ep" then
        local capSq = m.to + (us == "w" and -16 or 16)
        board[capSq] = nil
    elseif m.flags == "castle_k" then
        board[m.to - 1] = board[m.to + 1]
        board[m.to + 1] = nil
    elseif m.flags == "castle_q" then
        board[m.to + 1] = board[m.to - 2]
        board[m.to - 2] = nil
    end
    if typeOf(m.piece) == "k" then
        self.kings[us] = m.to
        if us == "w" then self.castling.K, self.castling.Q = false, false
        else self.castling.k, self.castling.q = false, false end
    end
    local r = CASTLE_ROOK_SQUARES[m.from]
    if r then self.castling[r] = false end
    r = CASTLE_ROOK_SQUARES[m.to]
    if r then self.castling[r] = false end
    self.ep = m.flags == "double" and (m.from + (us == "w" and 16 or -16)) or nil
    if typeOf(m.piece) == "p" or m.captured then self.halfmove = 0 else self.halfmove = self.halfmove + 1 end
    if us == "b" then self.fullmove = self.fullmove + 1 end
    self.turn = opposite(us)
    self.stack[#self.stack + 1] = undo
    return undo
end

function Chess:unmakeMove()
    local undo = table.remove(self.stack)
    if not undo then return nil end
    local m = undo.move
    local board = self.board
    self.turn = opposite(self.turn)
    local us = self.turn
    board[m.from] = m.piece
    board[m.to] = nil
    if m.flags == "ep" then
        board[m.to + (us == "w" and -16 or 16)] = m.captured
    elseif m.captured then
        board[m.to] = m.captured
    end
    if m.flags == "castle_k" then
        board[m.to + 1] = board[m.to - 1]
        board[m.to - 1] = nil
    elseif m.flags == "castle_q" then
        board[m.to - 2] = board[m.to + 1]
        board[m.to + 1] = nil
    end
    self.castling = undo.castling
    self.ep = undo.ep
    self.halfmove = undo.halfmove
    self.fullmove = undo.fullmove
    self.kings = undo.kings
    return m
end

function Chess:moves(opts)
    local legal = {}
    local us = self.turn
    local only = opts and opts.square
    for _, m in ipairs(self:pseudoMoves()) do
        if not only or m.from == only then
            self:makeMove(m)
            if not self:isAttacked(self.kings[us], opposite(us)) then
                legal[#legal + 1] = m
            end
            self:unmakeMove()
        end
    end
    return legal
end

-- Notation -------------------------------------------------------------------

function Chess.uci(m)
    return squareName(m.from) .. squareName(m.to) .. (m.promotion or "")
end

function Chess:san(m, legal)
    local s
    if m.flags == "castle_k" then
        s = "O-O"
    elseif m.flags == "castle_q" then
        s = "O-O-O"
    else
        local t = typeOf(m.piece)
        local capture = m.captured ~= nil
        if t == "p" then
            s = capture and (squareName(m.from):sub(1, 1) .. "x") or ""
            s = s .. squareName(m.to)
            if m.promotion then s = s .. "=" .. m.promotion:upper() end
        else
            s = t:upper()
            legal = legal or self:moves()
            local sameFile, sameRank, ambiguous = false, false, false
            for _, o in ipairs(legal) do
                if o.piece == m.piece and o.to == m.to and o.from ~= m.from then
                    ambiguous = true
                    if o.from % 16 == m.from % 16 then sameFile = true end
                    if math.floor(o.from / 16) == math.floor(m.from / 16) then sameRank = true end
                end
            end
            if ambiguous then
                local name = squareName(m.from)
                if not sameFile then s = s .. name:sub(1, 1)
                elseif not sameRank then s = s .. name:sub(2, 2)
                else s = s .. name end
            end
            if capture then s = s .. "x" end
            s = s .. squareName(m.to)
        end
    end
    self:makeMove(m)
    if self:inCheck() then
        s = s .. (#self:moves() == 0 and "#" or "+")
    end
    self:unmakeMove()
    return s
end

-- Accepts "e2e4", "e7e8q" and the king-takes-rook castling form ("e1h1")
-- that lichess uses in some places.
function Chess:moveFromUci(str)
    if type(str) ~= "string" or #str < 4 then return nil end
    local from = squareIndex(str:sub(1, 2))
    local to = squareIndex(str:sub(3, 4))
    local promo = #str >= 5 and str:sub(5, 5):lower() or nil
    if not from or not to then return nil end
    local piece = self.board[from]
    if piece and typeOf(piece) == "k" then
        local target = self.board[to]
        if target and typeOf(target) == "r" and colorOf(target) == colorOf(piece) then
            to = to > from and from + 2 or from - 2
        end
    end
    for _, m in ipairs(self:moves({ square = from })) do
        if m.to == to and m.promotion == (m.promotion and (promo or "q") or nil) then
            return m
        end
    end
    return nil
end

local function stripSan(s)
    return (s:gsub("[+#!?]", ""):gsub("e%.p%.", ""):gsub("0", "O"))
end

function Chess:moveFromSan(san)
    if type(san) ~= "string" then return nil end
    local want = stripSan(san)
    local legal = self:moves()
    for _, m in ipairs(legal) do
        if stripSan(self:san(m, legal)) == want then return m end
    end
    -- be lenient: some sources omit "=" in promotions or add superfluous disambiguation
    local promo = want:match("=?([QRBNqrbn])$")
    local target = want:match("([a-h][1-8])=?[QRBNqrbn]?$")
    if not target then return nil end
    local pieceLetter = want:match("^([NBRQK])")
    for _, m in ipairs(legal) do
        if squareName(m.to) == target then
            local t = typeOf(m.piece)
            if (pieceLetter and t == pieceLetter:lower()) or (not pieceLetter and t == "p") then
                if (not m.promotion and not (promo and not pieceLetter)) or (m.promotion and promo and m.promotion == promo:lower()) then
                    local hint = want:gsub("^[NBRQK]", ""):gsub("x", ""):gsub("[a-h][1-8]=?[QRBNqrbn]?$", "")
                    local fromName = squareName(m.from)
                    if hint == "" or fromName:find(hint, 1, true) then return m end
                end
            end
        end
    end
    return nil
end

-- Plays a move given as a move table, UCI string or SAN string.
-- Returns the move (with .san set) or nil when it is not legal.
function Chess:move(mv)
    local m
    if type(mv) == "table" then
        for _, l in ipairs(self:moves({ square = mv.from })) do
            if l.to == mv.to and (l.promotion == mv.promotion or (l.promotion and not mv.promotion and l.promotion == "q")) then
                m = l
                break
            end
        end
    elseif type(mv) == "string" then
        m = self:moveFromUci(mv) or self:moveFromSan(mv)
    end
    if not m then return nil end
    m.san = self:san(m)
    m.fen_before = self:fen()
    self:makeMove(m)
    self:recordPosition()
    return m
end

-- Applies a legal move table (from moves()) and returns the game, for chaining.
function Chess:playMove(m)
    self:makeMove(m)
    return self
end

function Chess:undo()
    if #self.stack == 0 then return nil end
    local key = self:positionKey()
    if self.repetition[key] then
        self.repetition[key] = self.repetition[key] - 1
        if self.repetition[key] <= 0 then self.repetition[key] = nil end
    end
    return self:unmakeMove()
end

function Chess:history()
    local list = {}
    for i, u in ipairs(self.stack) do list[i] = u.move end
    return list
end

function Chess:lastMove()
    local u = self.stack[#self.stack]
    return u and u.move
end

-- Game state -----------------------------------------------------------------

function Chess:isCheckmate() return self:inCheck() and #self:moves() == 0 end
function Chess:isStalemate() return not self:inCheck() and #self:moves() == 0 end

function Chess:isInsufficientMaterial()
    local minors, bishops = 0, {}
    for sq = 0, 119 do
        local p = onBoard(sq) and self.board[sq]
        if p then
            local t = typeOf(p)
            if t == "p" or t == "r" or t == "q" then return false end
            if t == "n" or t == "b" then minors = minors + 1 end
            if t == "b" then bishops[#bishops + 1] = (sq % 16 + math.floor(sq / 16)) % 2 end
        end
    end
    if minors <= 1 then return true end
    -- only bishops, all on the same colour
    if #bishops == minors then
        for i = 2, #bishops do
            if bishops[i] ~= bishops[1] then return false end
        end
        return true
    end
    return false
end

function Chess:isThreefold()
    return (self.repetition[self:positionKey()] or 0) >= 3
end

-- Draws a player may claim (but that do not end the game by themselves).
function Chess:claimableDraw()
    if self:isThreefold() then return "threefold repetition" end
    if self.halfmove >= 100 then return "fifty-move rule" end
    return nil
end

-- Returns nil while the game goes on, else result ("1-0", "0-1", "1/2-1/2") and reason.
-- opts.no_claims: leave out the draws that must be claimed (threefold, fifty
-- moves); the automatic ones (fivefold, seventy-five moves) still count.
function Chess:gameResult(opts)
    local legal = self:moves()
    if #legal == 0 then
        if self:inCheck() then
            return self.turn == "w" and "0-1" or "1-0", "checkmate"
        end
        return "1/2-1/2", "stalemate"
    end
    if self:isInsufficientMaterial() then return "1/2-1/2", "insufficient material" end
    if opts and opts.no_claims then
        if self.halfmove >= 150 then return "1/2-1/2", "seventy-five-move rule" end
        if (self.repetition[self:positionKey()] or 0) >= 5 then return "1/2-1/2", "fivefold repetition" end
        return nil
    end
    if self.halfmove >= 100 then return "1/2-1/2", "fifty-move rule" end
    if self:isThreefold() then return "1/2-1/2", "threefold repetition" end
    return nil
end

-- Material balance in pawns from White's view.
function Chess:materialBalance()
    local total = 0
    for sq = 0, 119 do
        local p = onBoard(sq) and self.board[sq]
        if p then
            local v = PIECE_VALUE[typeOf(p)]
            total = total + (colorOf(p) == "w" and v or -v)
        end
    end
    return total
end

function Chess:plyCount() return #self.stack end

-- SAN list of the moves played since the start position.
function Chess:sanHistory()
    local list = {}
    for i, u in ipairs(self.stack) do list[i] = u.move.san or "?" end
    return list
end

function Chess:uciHistory()
    local list = {}
    for i, u in ipairs(self.stack) do list[i] = Chess.uci(u.move) end
    return list
end

-- Movetext such as "1. e4 e5 2. Nf3", starting from the loaded position.
function Chess:moveText()
    local start = Chess.new(self.start_fen)
    local parts = {}
    local num = start.fullmove
    local white = start.turn == "w"
    for i, u in ipairs(self.stack) do
        if white then
            parts[#parts + 1] = num .. ". " .. (u.move.san or "?")
        else
            if i == 1 then parts[#parts + 1] = num .. "... " .. (u.move.san or "?")
            else parts[#parts + 1] = u.move.san or "?" end
            num = num + 1
        end
        white = not white
    end
    return table.concat(parts, " ")
end

function Chess:pgn(headers)
    local lines = {}
    headers = headers or {}
    local order = { "Event", "Site", "Date", "Round", "White", "Black", "Result" }
    local result = headers.Result or (self:gameResult()) or "*"
    headers.Result = result
    headers.Event = headers.Event or "Casual game"
    headers.Site = headers.Site or "KOReader"
    headers.Date = headers.Date or os.date("%Y.%m.%d")
    headers.Round = headers.Round or "-"
    headers.White = headers.White or "?"
    headers.Black = headers.Black or "?"
    local seen = {}
    for _, k in ipairs(order) do
        lines[#lines + 1] = string.format('[%s "%s"]', k, headers[k])
        seen[k] = true
    end
    if self.start_fen ~= Chess.START_FEN then
        lines[#lines + 1] = string.format('[SetUp "1"]')
        lines[#lines + 1] = string.format('[FEN "%s"]', self.start_fen)
        seen.SetUp, seen.FEN = true, true
    end
    for k, v in pairs(headers) do
        if not seen[k] then lines[#lines + 1] = string.format('[%s "%s"]', k, v) end
    end
    lines[#lines + 1] = ""
    local text = self:moveText()
    lines[#lines + 1] = (text ~= "" and (text .. " ") or "") .. result
    return table.concat(lines, "\n")
end

-- Loads a PGN (headers optional, comments and variations ignored).
function Chess.fromPgn(pgn)
    local fen = pgn:match('%[FEN%s+"([^"]+)"%]')
    local game, err = Chess.new(fen or Chess.START_FEN)
    if not game then return nil, err end
    local body = pgn:gsub("%[[^%]]*%]", "")
    body = body:gsub("%b{}", ""):gsub(";[^\n]*", "")
    -- strip variations (possibly nested)
    local prev
    repeat
        prev = body
        body = body:gsub("%([^()]*%)", "")
    until body == prev
    body = body:gsub("%$%d+", "")
    for token in body:gmatch("%S+") do
        token = token:gsub("^%d+%.+", "")
        if token ~= "" and not token:match("^%d+%.+$") and token ~= "*" and token ~= "1-0"
            and token ~= "0-1" and token ~= "1/2-1/2" then
            if not game:move(token) then
                return nil, "illegal move in PGN: " .. token
            end
        end
    end
    return game
end

-- Plays a space separated list of SAN or UCI moves.
function Chess:playLine(line)
    for token in line:gmatch("%S+") do
        if not self:move(token) then return false, token end
    end
    return true
end

function Chess:perft(depth)
    if depth == 0 then return 1 end
    local n = 0
    for _, m in ipairs(self:moves()) do
        self:makeMove(m)
        n = n + self:perft(depth - 1)
        self:unmakeMove()
    end
    return n
end

return Chess
