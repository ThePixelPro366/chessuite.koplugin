--[[
Explanations you can see: why a move is bad (or good) in plain words, and
the line that shows it, step by step, with arrows and circles for the
tactic (chessuite/tactics.lua names it: fork, pin, skewer, ...).

    local e = Explain.punishment(game_before, move, reply_pv, opts)
    e.headline  -- "it walks into a fork"
    e.text      -- the whole story
    e.steps     -- { { game, move, arrows, marks, caption }, ... } for the board
--]]

local Chess = require("chessuite/chess")
local Describe = require("chessuite/describe")
local Tactics = require("chessuite/tactics")

local Explain = {}

local NAMES = Chess.PIECE_NAMES
local VALUES = { p = 1, n = 3, b = 3, r = 5, q = 9, k = 0 }
local typ = Chess.typeOf
local sqn = Chess.squareName

local function lower(s) return (s:gsub("^%u", string.lower)) end
local function cap(s) return (s:gsub("^%l", string.upper)) end

-- Words for "you" and "your opponent", or the colours when the move is not yours.
local function voice(you, mover)
    if you then
        return { me = "you", my = "your", them = "your opponent", their = "your opponent's", Them = "Your opponent" }
    end
    local m = mover == "w" and "White" or "Black"
    local o = mover == "w" and "Black" or "White"
    return { me = m, my = m .. "'s", them = o, their = o .. "'s", Them = o }
end

-- "your rook on e5" / "the king"
local function pieceWords(g, sq, owner_words)
    local p = g.board[sq]
    if not p then return sqn(sq) end
    if typ(p) == "k" then return owner_words .. " king" end
    return owner_words .. " " .. NAMES[typ(p)] .. " on " .. sqn(sq)
end

-- One sentence per kind: what happens and why it hurts. `v` is the voice,
-- d the detail from Tactics, L the line (boards and moves).
local TELL = {}

function TELL.fork(d, L, v)
    local g = L.boards[d.ply]
    local names = {}
    for _, t in ipairs(d.targets) do names[#names + 1] = pieceWords(g, t, v.my) end
    local m = Describe.move(L.boards[d.ply - 1], L.moves[d.ply])
    return "it walks into a fork",
        v.Them .. " plays " .. lower(m) .. ", which attacks " .. table.concat(names, " and ")
            .. " at the same time. Only one of them can be saved."
end

function TELL.hangingPiece(d, L, v)
    local g = L.boards[1]
    return "it leaves your " .. NAMES[typ(g.board[d.piece])] .. " unprotected",
        "After this move nothing defends " .. pieceWords(g, d.piece, v.my) .. ", so " .. v.them
            .. " simply takes it: " .. lower(Describe.move(L.boards[1], L.moves[2])) .. "."
end

function TELL.trappedPiece(d, L, v)
    local g = L.boards[d.ply - 2]
    return "your " .. NAMES[typ(g.board[d.piece] or "p")] .. " gets trapped",
        cap(pieceWords(g, d.piece, v.my)) .. " has no safe square left: wherever it goes it can be taken, so it is lost."
end

function TELL.pin(d, L, v)
    local g = L.boards[d.ply]
    local behind = g.board[d.behind]
    return "it allows a pin",
        cap(v.their) .. " " .. NAMES[typ(g.board[d.pinner])] .. " on " .. sqn(d.pinner) .. " pins "
            .. pieceWords(g, d.pinned, v.my) .. " to " .. (behind and typ(behind) == "k" and (v.my .. " king")
            or pieceWords(g, d.behind, v.my))
            .. ": it cannot move away without exposing what is behind it."
end

function TELL.skewer(d, L, v)
    local g = L.boards[d.ply]
    return "it allows a skewer",
        v.Them .. " attacks " .. pieceWords(g, d.front, v.my) .. " with " .. lower(Describe.move(L.boards[d.ply - 1],
            L.moves[d.ply])) .. ". When it steps aside, " .. pieceWords(g, d.behind, v.my)
            .. " behind it on the same line is taken."
end

function TELL.discoveredAttack(d, L, v)
    local g = L.boards[d.ply]
    local moved = Describe.move(L.boards[d.ply - 1], L.moves[d.ply])
    return "it allows a discovered attack",
        v.Them .. " plays " .. lower(moved) .. " and so opens the line of the "
            .. NAMES[typ(g.board[d.revealed])] .. " on " .. sqn(d.revealed) .. ", which suddenly attacks "
            .. pieceWords(g, d.target, v.my) .. ". Two threats at once: one of them works."
end

function TELL.discoveredCheck(d, L, v)
    local g = L.boards[d.ply]
    return "it allows a discovered check",
        v.Them .. " moves the " .. NAMES[typ(g.board[d.moved.to])] .. " out of the way, and the "
            .. NAMES[typ(g.board[d.revealed])] .. " on " .. sqn(d.revealed) .. " behind it gives check. While "
            .. v.me .. " deal" .. (v.me == "you" and "" or "s") .. " with the check, the piece that moved does damage."
end

function TELL.doubleCheck(d, L, v)
    return "it allows a double check",
        v.Them .. " checks with two pieces at once. Nothing can block or take both, so only the king can move."
end

function TELL.deflection(d, L, v)
    local g = L.boards[d.ply - 1]
    return "your defender gets pulled away",
        cap(pieceWords(g, d.defender, v.my)) .. " is the only guard of " .. sqn(d.square) .. ". " .. v.Them
            .. " lures it away, and then " .. sqn(d.square) .. " is no longer protected."
end

function TELL.attraction(d, L, v)
    local g = L.boards[d.ply]
    return "your " .. NAMES[typ(g.board[d.piece] or "p")] .. " gets lured onto a bad square",
        v.Them .. " gives up a piece on " .. sqn(d.square) .. " to draw " .. pieceWords(g, d.piece, v.my)
            .. " there, where it is attacked right away."
end

function TELL.capturingDefender(d, L, v)
    local g = L.boards[d.ply - 1]
    return "your defender gets taken",
        v.Them .. " takes " .. pieceWords(g, d.defender, v.my) .. ", the piece that guards " .. sqn(d.square)
            .. ", and then wins what it was defending."
end

function TELL.intermezzo(d, L, v)
    return "an in-between move turns it around",
        "Before taking back, " .. v.them .. " first plays a stronger move in between, and comes out ahead."
end

function TELL.promotion(d, L, v)
    return "a pawn gets through to promote",
        cap(v.their) .. " pawn reaches " .. sqn(d.square) .. " and becomes a new piece."
end

function TELL.advancedPawn(d, L, v)
    return "a pawn gets too close to promoting",
        cap(v.their) .. " pawn on " .. sqn(d.square) .. " is almost through and costs material to stop."
end

function TELL.attackingF2F7(d, L, v)
    local s = sqn(d.square)
    return "it lets " .. v.them .. " hit " .. s,
        "The pawn on " .. s .. " is only guarded by the king. " .. v.Them .. " takes it, and the king is exposed."
end

-- Board pictures --------------------------------------------------------------------

-- What to draw on the key position of a tactic.
local function overlay(d, L)
    local arrows, marks = {}, {}
    local function ring(sq) marks[sq] = "target" end
    local k = d.kind
    if k == "fork" then
        for _, t in ipairs(d.targets) do
            arrows[#arrows + 1] = { from = d.piece, to = t, color = "red", dashed = true }
            ring(t)
        end
    elseif k == "hangingPiece" then
        arrows[#arrows + 1] = { from = d.attacker, to = d.piece, color = "red", dashed = true }
        ring(d.piece)
    elseif k == "trappedPiece" then
        ring(d.piece)
    elseif k == "pin" then
        arrows[#arrows + 1] = { from = d.pinner, to = d.pinned, color = "red", dashed = true }
        arrows[#arrows + 1] = { from = d.pinned, to = d.behind, color = "red", dashed = true, thin = true }
        ring(d.pinned)
    elseif k == "skewer" then
        arrows[#arrows + 1] = { from = d.attacker, to = d.front, color = "red", dashed = true }
        arrows[#arrows + 1] = { from = d.front, to = d.behind, color = "red", dashed = true, thin = true }
        ring(d.front)
        ring(d.behind)
    elseif k == "discoveredAttack" or k == "discoveredCheck" then
        arrows[#arrows + 1] = { from = d.revealed, to = d.target, color = "red", dashed = true }
        ring(d.target)
    elseif k == "doubleCheck" then
        local king = L.boards[d.ply].kings[L.boards[d.ply].turn]
        for _, c in ipairs(d.checkers) do arrows[#arrows + 1] = { from = c, to = king, color = "red", dashed = true } end
        ring(king)
    elseif k == "deflection" or k == "capturingDefender" then
        ring(d.square)
        if d.defender then marks[d.defender] = "hint" end
    elseif k == "attraction" or k == "promotion" or k == "advancedPawn" or k == "attackingF2F7" then
        ring(d.square)
    end
    return arrows, marks
end
Explain.overlay = overlay

-- The final mate: the checking pieces and the king's escape squares.
local function mateOverlay(L)
    local g = L.boards[L.n]
    local king = g.kings[g.turn]
    local arrows, marks = {}, { [king] = "target" }
    for _, c in ipairs(g:attackers(king, Chess.opposite(g.turn))) do
        arrows[#arrows + 1] = { from = c, to = king, color = "red", dashed = true }
    end
    return arrows, marks
end

-- Material won by the punishing side over the shown line, in points, and the
-- most valuable piece the other side lost.
local function materialResult(L, upto)
    local start = Tactics.materialDiff(L.boards[1], L.pov)
    local finish = Tactics.materialDiff(L.boards[upto], L.pov)
    local biggest
    for i = 2, upto do
        local c = L.moves[i].captured
        if c and Chess.colorOf(c) ~= L.pov and (not biggest or VALUES[typ(c)] > VALUES[biggest]) then biggest = typ(c) end
    end
    return finish - start, biggest
end

-- Steps for the board: the move itself, then each move of the line; the
-- tactic is drawn on its key move, the mate on the last one.
local function buildSteps(L, upto, key, v, first_caption)
    local steps = {}
    local g0 = L.boards[0]
    steps[#steps + 1] = {
        game = L.boards[1], move = L.moves[1],
        arrows = { { from = L.moves[1].from, to = L.moves[1].to, color = "blue", label = 1 } },
        caption = first_caption or (cap(v.me) .. " play" .. (v.me == "you" and "" or "s") .. " "
            .. lower(Describe.move(g0, L.moves[1])) .. "."),
    }
    for i = 2, upto do
        local m = L.moves[i]
        local who = (i % 2 == 0) and v.Them or cap(v.me)
        local arrows = { { from = m.from, to = m.to, color = i % 2 == 0 and "red" or "blue", label = i } }
        local marks = {}
        local caption = who .. ": " .. lower(Describe.move(L.boards[i - 1], m)) .. "."
        if key and key.ply == i then
            local a, mk = overlay(key, L)
            for _, x in ipairs(a) do arrows[#arrows + 1] = x end
            for s, kind in pairs(mk) do marks[s] = kind end
            caption = caption .. " " .. (key.caption or "")
        end
        if i == upto and L.boards[i]:isCheckmate() then
            local a, mk = mateOverlay(L)
            for _, x in ipairs(a) do arrows[#arrows + 1] = x end
            for s, kind in pairs(mk) do marks[s] = kind end
        end
        steps[#steps + 1] = { game = L.boards[i], move = m, arrows = arrows, marks = marks, caption = caption }
    end
    return steps
end

local KEY_CAPTION = {
    fork = "A fork: two pieces attacked at once.",
    hangingPiece = "The piece had no defender.",
    trappedPiece = "The piece cannot escape.",
    pin = "A pin: the piece cannot move away.",
    skewer = "A skewer: the piece behind is next.",
    discoveredAttack = "A discovered attack: the line opens.",
    discoveredCheck = "A discovered check.",
    doubleCheck = "Double check: only the king can move.",
    deflection = "The defender is pulled away.",
    attraction = "The piece is lured here.",
    capturingDefender = "The defender is gone.",
    intermezzo = "An in-between move.",
    promotion = "Promotion.",
    advancedPawn = "The pawn is almost through.",
    attackingF2F7 = "The weak pawn next to the king.",
}

-- The tactic that explains the line best: the one that strikes first (ties go
-- by Tactics.ORDER), leaving out pins that were there before the move.
function Explain.keyTactic(t, L)
    local key
    for _, d in ipairs(t.found) do
        local old_pin = false
        if d.kind == "pin" then
            local pinned = L.boards[d.ply].board[d.pinned]
            local before = L.boards[0].board[d.pinned]
            old_pin = before == pinned and Tactics.pinOf(L.boards[0], Chess.colorOf(pinned), d.pinned) == d.pinner
        end
        if not old_pin and (not key or d.ply < key.ply) then key = d end
    end
    return key
end

--[[
Why a move is bad: `pv` is the engine's best line after the move (the
answer and what follows). Returns nil when there is no line.
  opts.you: the move is the player's (default true; else the colours are named)
  opts.cost: words for what it costs ("you lose about 2 pawns of advantage")
  opts.max: the longest line to show (plies after the move, default 9)
--]]
function Explain.punishment(game_before, move, pv, opts)
    opts = opts or {}
    if not pv or #pv == 0 then return nil end
    local you = opts.you ~= false
    local v = voice(you, game_before.turn)
    local ucis = { Chess.uci(move) }
    for i = 1, math.min(#pv, opts.max or 9) do ucis[#ucis + 1] = pv[i] end
    local t = Tactics.analyse(game_before, ucis)
    local L = t.line
    if L.n < 2 then return nil end
    local upto = Tactics.usefulLength(game_before, ucis, L.n)
    local key = Explain.keyTactic(t, L)
    if key then
        upto = math.max(upto, math.min(L.n, key.ply + 1))
        key.caption = KEY_CAPTION[key.kind]
    end
    if t.mate then upto = L.n end
    local headline, story
    if t.mate then
        local kind = t.mate_kind == "backRankMate" and "a back-rank mate"
            or t.mate_kind == "smotheredMate" and "a smothered mate" or "checkmate"
        headline = t.mate == 1 and ("it allows " .. kind .. " in one move")
            or ("it allows " .. kind .. " in " .. t.mate .. " moves")
        story = v.Them .. " can force mate: " .. lower(Describe.line(L.boards[1], pv, L.n - 1)) .. "."
        if t.mate_kind == "backRankMate" then
            story = story .. " The king is shut in on its back rank by its own pawns."
        elseif t.mate_kind == "smotheredMate" then
            story = story .. " The king is surrounded by its own pieces, and the knight mates."
        end
    elseif key and TELL[key.kind] then
        headline, story = TELL[key.kind](key, L, v)
    end
    local won, biggest = materialResult(L, upto)
    -- a material loss alone is only worth saying when it is clear (deep in the
    -- engine's line a pawn here or there is not)
    if not t.mate and (won >= 2 or (key and won >= 1)) then
        local piece = biggest and won >= VALUES[biggest] and (biggest == "p" and "a pawn" or ("the " .. NAMES[biggest]))
        local res = cap(v.me) .. (v.me == "you" and " end up " or " ends up ") .. won .. " point"
            .. (won == 1 and "" or "s") .. " down" .. (piece and (": " .. v.me .. (v.me == "you" and " lose " or " loses ")
            .. piece) or "") .. "."
        if not story and L.moves[2].captured then
            -- no tactic: the piece is simply taken
            story = v.Them .. " takes it: " .. lower(Describe.move(L.boards[1], L.moves[2])) .. "."
        end
        story = story and (story .. " " .. res) or res
        headline = headline or (piece and ("it loses " .. piece) or "it loses material")
    else
        won = 0
    end
    if not headline then
        -- nothing to point at: what the engine expects, and the cost
        local reply = L.moves[2]
        headline = opts.positional or "the position gets worse"
        story = v.Them .. " answers " .. lower(Describe.move(L.boards[1], reply)) .. "."
            .. (opts.positional_text and (" " .. opts.positional_text) or "")
            .. (opts.cost and (" " .. cap(opts.cost) .. ".") or "")
        upto = math.min(upto, 2)
    end
    return {
        headline = headline,
        text = story,
        won = won,
        tags = t.tags,
        key = key,
        mate = t.mate,
        steps = buildSteps(L, upto, key, v),
    }
end

--[[
Why a move is good (the engine's better move, or a winning chance): the
same, from the side that plays it. `line` starts with the good move.
--]]
function Explain.idea(game_before, line, opts)
    opts = opts or {}
    if not line or #line == 0 then return nil end
    local first = game_before:moveFromUci(line[1])
    if not first then return nil end
    -- tagged like a puzzle whose first move is a pass by the other side: the
    -- good move is then the punishing side's first move (move 2)
    local g = game_before:clone()
    g.turn = Chess.opposite(g.turn)
    g.ep = nil
    local ucis = { "0000" }
    for i = 1, math.min(#line, opts.max or 9) do ucis[#ucis + 1] = line[i] end
    local t = Tactics.analyse(g, ucis)
    local L = t.line
    local upto = Tactics.usefulLength(L.boards[0], ucis, L.n)
    local key = Explain.keyTactic(t, L)
    if key then
        upto = math.max(upto, math.min(L.n, key.ply + 1))
        key.caption = KEY_CAPTION[key.kind]
    end
    if t.mate then upto = L.n end
    local v = voice(opts.you ~= false, game_before.turn)
    local name = Describe.move(game_before, first)
    local why
    if t.mate then
        why = "it forces checkmate" .. (t.mate > 1 and (" in " .. t.mate .. " moves") or "")
    elseif key then
        local words = {
            fork = "it forks two pieces", pin = "it pins a piece", skewer = "it skewers two pieces",
            discoveredAttack = "it opens a discovered attack", discoveredCheck = "it gives a discovered check",
            doubleCheck = "it gives double check", hangingPiece = "it wins an undefended piece",
            trappedPiece = "it traps a piece", deflection = "it pulls a defender away",
            attraction = "it lures a piece onto a bad square", capturingDefender = "it removes a defender",
            promotion = "it gets a pawn through", advancedPawn = "it pushes a dangerous pawn",
            intermezzo = "an in-between move wins time", attackingF2F7 = "it attacks the weak pawn next to the king",
        }
        why = words[key.kind]
    end
    local steps = {}
    for i = 2, upto do
        local m = L.moves[i]
        local arrows = { { from = m.from, to = m.to, color = i % 2 == 0 and "green" or "blue", label = i - 1 } }
        local marks = {}
        local caption = ((i % 2 == 0) and cap(v.me) or v.Them) .. ": " .. lower(Describe.move(L.boards[i - 1], m)) .. "."
        if key and key.ply == i then
            local a, mk = overlay(key, L)
            for _, x in ipairs(a) do x.color = "green"; arrows[#arrows + 1] = x end
            for s, kind in pairs(mk) do marks[s] = kind end
            caption = caption .. " " .. (key.caption or "")
        end
        if i == upto and L.boards[i]:isCheckmate() then
            local a, mk = mateOverlay(L)
            for _, x in ipairs(a) do x.color = "green"; arrows[#arrows + 1] = x end
            for s, kind in pairs(mk) do marks[s] = kind end
        end
        steps[#steps + 1] = { game = L.boards[i], move = m, arrows = arrows, marks = marks, caption = caption }
    end
    return {
        headline = name .. (why and (": " .. why) or ""),
        why = why,
        name = name,
        tags = t.tags,
        mate = t.mate,
        steps = steps,
        start = game_before,
    }
end

return Explain
