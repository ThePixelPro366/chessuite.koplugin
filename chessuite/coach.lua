--[[
The coach: judges a move with Stockfish's evaluation before and after it,
labels it (best, excellent, good, inaccuracy, mistake, blunder, ...) and
explains it in plain words ("Rook takes knight on e5 is a mistake. It lets
your opponent win your queen. Pawn to e4 was better.").

The classification thresholds, accuracy formula and the rule-based wording
are ported from the open-source chess-app project by Arunav Rajkhowa
(https://github.com/ArunavRajkhowa/chess-app, AGPL-3.0), whose coach is an
open alternative to chess.com's game review and coach: every sentence is a
fact the engine or the rules have checked.
--]]

local Chess = require("chessuite/chess")
local Describe = require("chessuite/describe")
local Engine = require("chessuite/uci")
local Explain = require("chessuite/explain")

local Coach = {}

-- win% drop thresholds, mover's view (chess-app backend/review/classify.py)
local EXCELLENT_MAX_DROP = 2.0
local GOOD_MAX_DROP = 5.0
-- inaccuracy, mistake and blunder start where lichess puts them: a loss of
-- 5, 10 and 15 points of winning chance (lila Advice: 0.1 / 0.2 / 0.3 of
-- the -1..1 winning chances)
local INACCURACY_MAX_DROP = 10.0
local MISTAKE_MAX_DROP = 15.0
local GREAT_SECOND_LINE_GAP = 10.0
local MISS_MIN_BEST_WIN = 85.0
local MISS_MIN_DROP = 10.0
local MISS_MIN_WIN_AFTER = 50.0
local BRILLIANT_MAX_DROP = 2.0
local BRILLIANT_MIN_WIN_AFTER = 40.0
local BRILLIANT_MAX_WIN_BEFORE = 92.0

Coach.LABELS = {
    brilliant = "a brilliant move",
    great = "a great move",
    best = "the best move",
    excellent = "an excellent move",
    good = "a good move",
    book = "a book move",
    inaccuracy = "an inaccuracy",
    mistake = "a mistake",
    miss = "a missed chance",
    blunder = "a blunder",
    forced = "the only move",
}

-- Badges like a game review: symbol, colour (for colour screens) and grey
-- level (for black and white screens).
Coach.BADGES = {
    brilliant  = { symbol = "!!", rgb = { 0x26, 0xC2, 0xA3 }, gray = 0x33 },
    great      = { symbol = "!",  rgb = { 0x5C, 0x8B, 0xB0 }, gray = 0x33 },
    best       = { symbol = "★",  rgb = { 0x81, 0xB6, 0x4C }, gray = 0x55 },
    excellent  = { symbol = "✓",  rgb = { 0x96, 0xBC, 0x4B }, gray = 0x77 },
    good       = { symbol = "✓",  rgb = { 0x96, 0xAF, 0x8B }, gray = 0x88 },
    book       = { symbol = "B",  rgb = { 0xA8, 0x88, 0x65 }, gray = 0x88 },
    forced     = { symbol = "·",  rgb = { 0x97, 0x97, 0x97 }, gray = 0x88 },
    inaccuracy = { symbol = "?!", rgb = { 0xF7, 0xC6, 0x31 }, gray = 0x00 },
    mistake    = { symbol = "?",  rgb = { 0xFF, 0xA4, 0x59 }, gray = 0x00 },
    miss       = { symbol = "×",  rgb = { 0xFF, 0x77, 0x69 }, gray = 0x00 },
    blunder    = { symbol = "??", rgb = { 0xFA, 0x41, 0x2D }, gray = 0x00 },
}

function Coach.symbol(class)
    local b = Coach.BADGES[class]
    return b and b.symbol or ""
end

-- "?! inaccuracy"
function Coach.tag(class)
    if not class then return "" end
    return Coach.symbol(class) .. " " .. class
end

local PROBLEMS = { inaccuracy = true, mistake = true, blunder = true, miss = true }
Coach.PROBLEMS = PROBLEMS

function Coach.moveAccuracy(win_before, win_after)
    local drop = math.max(0, win_before - win_after)
    return math.max(0, math.min(100, 103.1668 * math.exp(-0.04354 * drop) - 3.1669))
end

local function materialFor(game, color)
    local b = game:materialBalance()
    return color == "w" and b or -b
end

--[[
Classify a move.
  game_before: position before the move (not modified)
  move: the move (from game_before:moves())
  before: engine result for game_before ({lines = {...}}), multipv >= 2 preferred
  after: engine result for the position after the move
Returns a table { class, win_before, win_after, cp_loss, best_uci, accuracy }
--]]
function Coach.classify(game_before, move, before, after, opts)
    opts = opts or {}
    local best = before and before.lines and before.lines[1]
    local second = before and before.lines and before.lines[2]
    local reply = after and after.lines and after.lines[1]
    local res = { best_uci = best and best.pv and best.pv[1] }
    local legal_count = #game_before:moves()
    if legal_count == 1 then
        res.class = "forced"
        res.accuracy = 100
        return res
    end
    local cp_before = Engine.lineCp(best) or 0
    local cp_after
    if reply then
        cp_after = -Engine.lineCp(reply)
    else
        -- no reply line: the game ended with this move
        local g = game_before:clone()
        g:makeMove(move)
        local result = g:gameResult()
        if result == "1/2-1/2" then cp_after = 0
        elseif result then cp_after = Engine.MATE_CP
        else cp_after = cp_before end
    end
    local win_before = Engine.winPercent(cp_before)
    local win_after = Engine.winPercent(cp_after)
    local second_win = second and Engine.winPercent(Engine.lineCp(second))
    local uci = Chess.uci(move)
    local is_best = res.best_uci == uci
    local cp_loss = math.max(0, cp_before - cp_after)
    local drop = math.max(0, win_before - win_after)
    res.win_before, res.win_after, res.cp_loss = win_before, win_after, cp_loss
    res.accuracy = Coach.moveAccuracy(win_before, win_after)
    res.mate_before = best and best.mate
    res.mate_after = reply and reply.mate -- from the opponent's view

    if opts.is_book and drop <= MISTAKE_MAX_DROP then
        res.class = "book"
        return res
    end
    if is_best or cp_loss <= 0 then
        -- a sound sacrifice: material given up, engine still happy
        local g = game_before:clone()
        local mover = g.turn
        local mat_before = materialFor(g, mover)
        g:makeMove(move)
        local mat_after_reply = materialFor(g, mover)
        if reply and reply.pv and reply.pv[1] then
            local rm = g:moveFromUci(reply.pv[1])
            if rm then
                g:makeMove(rm)
                mat_after_reply = materialFor(g, mover)
            end
        end
        local sacrificed = mat_before - mat_after_reply
        if sacrificed >= 2 and drop <= BRILLIANT_MAX_DROP and win_after >= BRILLIANT_MIN_WIN_AFTER
            and win_before <= BRILLIANT_MAX_WIN_BEFORE and not game_before:inCheck() and not move.promotion
            and not (second_win and second_win >= 95) then
            res.class = "brilliant"
            return res
        end
        local only_move = second_win and (win_before - second_win) >= GREAT_SECOND_LINE_GAP
        local punish = opts.opponent_prev_class and (opts.opponent_prev_class == "mistake"
            or opts.opponent_prev_class == "blunder" or opts.opponent_prev_class == "miss")
        if (only_move or punish) and win_before >= 45 then
            res.class = "great"
            return res
        end
        res.class = "best"
        return res
    end
    local mate_missed = best and best.mate and best.mate > 0 and not (reply and reply.mate and reply.mate < 0)
    res.mate_missed = mate_missed
    if mate_missed and win_after >= MISS_MIN_WIN_AFTER then
        res.class = "miss"
    elseif win_before >= MISS_MIN_BEST_WIN and drop >= MISS_MIN_DROP
        and win_after >= MISS_MIN_WIN_AFTER and win_after < MISS_MIN_BEST_WIN then
        res.class = "miss"
    elseif drop <= EXCELLENT_MAX_DROP then
        res.class = "excellent"
    elseif drop <= GOOD_MAX_DROP then
        res.class = "good"
    elseif drop <= INACCURACY_MAX_DROP then
        res.class = "inaccuracy"
    elseif drop <= MISTAKE_MAX_DROP then
        res.class = "mistake"
    else
        res.class = "blunder"
    end
    -- On a slow e-reader the search is short and its score wobbles by a few
    -- tenths of a pawn between two positions; only call it a problem when the
    -- loss is also real in pawns.
    if res.class == "blunder" and cp_loss < 200 then res.class = "mistake" end
    if res.class == "mistake" and cp_loss < 90 then res.class = "inaccuracy" end
    if res.class == "inaccuracy" and cp_loss < 40 then res.class = "good" end
    return res
end

local function lower(s) return (s:gsub("^%u", string.lower)) end
local function cap(s) return (s:gsub("^%l", string.upper)) end

local function mateIn(n) return n == 1 and "right away" or ("in " .. n .. " moves") end

--[[
Explain a judged move in plain words.
  game_before, move, before, after: as for classify()
  judgement: result of classify()
  level: "beginner" keeps it short
--]]
--  opts.hide_best: during a game, explain what went wrong (the opponent's
--  answer, what it costs) without telling which move to play instead.
-- Also returns the explanation to see on the board (for the "Why?" page): a
-- list of parts { title, headline, text, steps } (chessuite/explain.lua), or nil.
function Coach.explain(game_before, move, before, after, judgement, level, opts)
    local hide_best = opts and opts.hide_best
    local parts = {}
    local g = game_before:clone()
    local desc = Describe.move(g, move)
    local class = judgement.class
    local mover = g.turn
    local beginner = level == "beginner"

    g:makeMove(move)
    local _, reason = g:gameResult()
    if reason == "checkmate" then
        return desc .. ". Checkmate! Well done."
    end
    g:unmakeMove()

    if class == "book" then
        local Openings = require("chessuite/openings")
        local name = Openings.current(g:clone():playMove(move))
        return desc .. " is a book move" .. (name and (" (" .. name .. ")") or "") .. "."
    end
    parts[#parts + 1] = desc .. " is " .. (Coach.LABELS[class] or class) .. "."

    local reasons = Describe.reasons(g, move)
    local reply = after and after.lines and after.lines[1]
    local best = before and before.lines and before.lines[1]

    local visual = {}
    if PROBLEMS[class] then
        local after_game = g:clone()
        after_game:makeMove(move)
        -- name the tactic that punishes the move (Lichess' puzzle themes), with its line
        local e = class ~= "miss" and reply and reply.pv
            and Explain.punishment(g, move, reply.pv, { cost = Coach.costWords(judgement.cp_loss) })
        if e and (e.key or e.mate or (e.won or 0) >= 1) then
            parts[#parts] = desc .. " is " .. (Coach.LABELS[class] or class) .. ": " .. e.headline .. "."
            parts[#parts + 1] = beginner and (e.text:match("^.-[%.!]%s") or e.text):gsub("%s+$", "") or e.text
            visual[#visual + 1] = { title = "What goes wrong", headline = cap(e.headline) .. ".", text = e.text,
                steps = e.steps, start = g }
        elseif reply and reply.mate and reply.mate > 0 then
            local line = ""
            if reply.mate <= 3 and reply.pv and #reply.pv > 0 then
                line = ": " .. lower(Describe.line(after_game, reply.pv, reply.mate * 2 - 1))
            end
            parts[#parts + 1] = "This lets your opponent checkmate you " .. mateIn(reply.mate) .. line .. "."
        elseif judgement.mate_missed and best and best.mate then
            parts[#parts + 1] = "You could have checkmated " .. mateIn(best.mate) .. "!"
        elseif class == "miss" and hide_best then
            local cost = Coach.costWords(judgement.cp_loss)
            parts[#parts + 1] = "You missed a winning chance" .. (cost and (": " .. cost) or "") .. "."
        elseif class == "miss" and best and best.pv and best.pv[1] then
            -- say what the winning chance was, not what the opponent does next
            local bm = g:moveFromUci(best.pv[1])
            if bm then
                local idea = Explain.idea(g, best.pv)
                local line = #best.pv >= 3 and lower(Describe.line(g, best.pv, 3)) or lower(Describe.move(g, bm))
                local cost = Coach.costWords(judgement.cp_loss)
                parts[#parts + 1] = "You had a winning chance: " .. line
                    .. (idea and idea.why and (" (" .. idea.why .. ")") or "")
                    .. (cost and (". By missing it " .. cost) or "") .. "."
                if idea and #idea.steps > 0 then
                    visual[#visual + 1] = { title = "What you missed", headline = cap(idea.headline) .. ".",
                        text = "You had a winning chance here. " .. cap(line) .. ".", steps = idea.steps, start = g }
                end
            end
        else
            local problems = {}
            local hanging_before = {}
            for _, h in ipairs(Describe.hangingPieces(g, mover)) do hanging_before[h.square] = true end
            for _, h in ipairs(Describe.hangingPieces(after_game, mover)) do
                -- the moved piece, or a piece that was safe before the move
                if not hanging_before[h.square] or h.square == move.to then
                    problems[#problems + 1] = "it leaves your " .. Describe.pieceOn(after_game, h.square) .. " unprotected"
                    break
                end
            end
            if reply and reply.pv and reply.pv[1] then
                local rm = after_game:moveFromUci(reply.pv[1])
                local j
                for _, r in ipairs(rm and Describe.reasons(after_game, rm) or {}) do
                    -- only a reply that hurts is worth quoting (not "trades pawns")
                    if r:find("^wins") or r:find("^attacks") or r:find("^gives check") then j = r break end
                end
                if j then
                    -- only worth saying when the reply actually does something
                    problems[#problems + 1] = "your opponent can answer with "
                        .. lower(Describe.move(after_game, rm)) .. ", which " .. j
                end
            end
            if #problems > 0 then
                parts[#parts + 1] = "The problem: " .. table.concat(problems, "; ", 1, beginner and 1 or #problems) .. "."
            elseif reply and reply.pv and reply.pv[1] then
                -- nothing simple to point at: say what the engine expects and what it costs
                -- during a game only the opponent's answer, not your own next move
                local line = lower(Describe.line(after_game, reply.pv, hide_best and 1 or 3))
                local cost = Coach.costWords(judgement.cp_loss)
                parts[#parts + 1] = (hide_best and "Why: your opponent can answer with " or "Why: the engine expects ")
                    .. line .. (cost and (", and " .. cost) or "") .. "."
            end
        end
        if not hide_best and best and best.pv and best.pv[1] and not (class == "miss" and not judgement.mate_missed) then
            local bm = g:moveFromUci(best.pv[1])
            if bm then
                local text = Describe.move(g, bm) .. " was better"
                local j = Describe.joinReasons(Describe.reasons(g, bm), 2)
                local idea = Explain.idea(g, best.pv)
                if idea and idea.why then j = idea.why:gsub("^it ", "") end
                if idea and #idea.steps > 0 then
                    visual[#visual + 1] = { title = "Better", headline = cap(Describe.move(g, bm)) .. " was better"
                        .. (idea.why and (": " .. idea.why) or "") .. ".",
                        text = "The engine's line: " .. lower(Describe.line(g, best.pv, math.min(#best.pv, 5))) .. ".",
                        steps = idea.steps, start = g }
                end
                if j then
                    text = text .. ": it " .. j
                elseif not beginner and #best.pv >= 3 then
                    text = text .. ". The engine's plan: " .. lower(Describe.line(g, best.pv, 3))
                end
                parts[#parts + 1] = text .. "."
            end
        end
    else
        local j = Describe.joinReasons(reasons, 2)
        if j then parts[#parts + 1] = "It " .. j .. "." end
        if class == "excellent" or class == "good" then
            if not hide_best and best and best.pv and best.pv[1] and best.pv[1] ~= Chess.uci(move) and not beginner then
                local bm = g:moveFromUci(best.pv[1])
                if bm then parts[#parts + 1] = "The engine liked " .. lower(Describe.move(g, bm)) .. " a little more." end
            end
        end
    end

    local lesson = Coach.lesson(class, g, move, reply)
    if lesson then parts[#parts + 1] = lesson end
    return table.concat(parts, " "), #visual > 0 and visual or nil
end

-- Positional reason ------------------------------------------------------------------

--[[
When no tactic explains a problem move: what Stockfish 11's evaluation says
got worse (chessuite/positional.lua), from the terms before the move and
after the opponent's best answer. Returns the text with the reason added and
a part for the "Why?" page, or nil.
--]]
function Coach.addPositional(text, game_before, move, reply_uci, terms_before, terms_after)
    local Positional = require("chessuite/positional")
    local g1 = game_before:clone()
    g1:makeMove(move)
    local g2 = g1:clone()
    local reply = reply_uci and g2:moveFromUci(reply_uci)
    if reply then g2:makeMove(reply) end
    local color = game_before.turn
    local reason = Positional.worst(terms_before, terms_after, color, g2)
    if not reason then return nil end
    local sentence = Positional.sentence(reason, g2, color)
    local new_text, n = text:gsub("^(.- is [^%.:]-)%.", "%1: " .. sentence .. ".", 1)
    if n == 0 then new_text = text .. " " .. cap(sentence) .. "." end
    local marks = Positional.squares(reason, g2, color)
    local steps = {
        { game = g1, move = move, caption = "You play " .. lower(Describe.move(game_before, move)) .. ".",
          arrows = { { from = move.from, to = move.to, color = "blue", label = 1 } } },
    }
    if reply then
        steps[#steps + 1] = { game = g2, move = reply, marks = marks,
            caption = "Your opponent: " .. lower(Describe.move(g1, reply)) .. ". " .. cap(sentence) .. ".",
            arrows = { { from = reply.from, to = reply.to, color = "red", label = 2 } } }
    end
    return new_text, { title = "What goes wrong", headline = cap(sentence) .. ".",
        text = "No tactic here, but Stockfish's evaluation shows what the move gives away: " .. sentence
            .. " (about " .. string.format("%.1f", reason.loss) .. " pawns in its count).",
        steps = steps, start = game_before }
end

-- Endgame verdict ----------------------------------------------------------------------

local function pieceCount(game)
    local n = 0
    for sq = 0, 119 do
        if Chess.onBoard(sq) and game.board[sq] then n = n + 1 end
    end
    return n
end
Coach.pieceCount = pieceCount

local INVERT = { win = "loss", loss = "win", draw = "draw", ["cursed-win"] = "blessed-loss",
    ["blessed-loss"] = "cursed-win" }
local function outcome(category)
    if category == "win" then return "win" end
    if category == "loss" then return "loss" end
    return "draw" -- a "cursed" win cannot be won within the fifty-move rule
end

--[[
With 7 pieces or fewer: what the Lichess tablebase says the move changed,
e.g. "With perfect play this was a win, and now it is only a draw (Lichess
endgame tablebase)." `client` is the Lichess client; returns nil when there
is nothing to say or no answer (offline).
--]]
function Coach.tablebaseVerdict(client, game_before, move)
    if pieceCount(game_before) > 7 or not client or not client.tablebase then return nil end
    local after = game_before:clone()
    after:makeMove(move)
    -- pcall returns its own ok, then the request's ok and data
    local _, ok1, b = pcall(client.tablebase, client, game_before:fen())
    if not ok1 or type(b) ~= "table" or not b.category then return nil end
    local _, ok2, a = pcall(client.tablebase, client, after:fen())
    if not ok2 or type(a) ~= "table" or not a.category then return nil end
    local before = outcome(b.category)
    local now = outcome(INVERT[a.category] or a.category)
    local words = { win = "a win", draw = "a draw", loss = "lost" }
    if before == now then return nil end
    if before == "win" then
        return "With perfect play this was " .. words.win .. ", and now it is "
            .. (now == "draw" and "only a draw" or "lost") .. " (Lichess endgame tablebase)."
    elseif before == "draw" and now == "loss" then
        return "With perfect play this was a draw, and now it is lost (Lichess endgame tablebase)."
    end
    return nil
end

-- "you lose about 1.5 pawns of advantage"
function Coach.costWords(cp_loss)
    if not cp_loss or cp_loss < 50 or Engine.isMateScore(cp_loss) then return nil end
    if cp_loss >= 800 then return "you lose a lot of material or position" end
    local pawns = math.floor(cp_loss / 50 + 0.5) / 2
    local n = pawns == math.floor(pawns) and string.format("%d", pawns) or string.format("%.1f", pawns)
    return "you lose about " .. n .. (pawns == 1 and " pawn" or " pawns") .. " of advantage"
end

function Coach.lesson(class, game_before, move, reply)
    -- only a tip that follows from the position, never a generic one
    if class == "blunder" or class == "mistake" then
        local g = game_before:clone()
        g:makeMove(move)
        if #Describe.hangingPieces(g, game_before.turn) > 0 and not (reply and reply.mate) then
            return "Tip: before you move, check which of your pieces could be taken for free."
        end
    end
    return nil
end

-- What the opponent's last move does, as a warning for the player.
function Coach.warnAbout(game_before, move)
    local reasons = Describe.reasons(game_before, move)
    local desc = Describe.move(game_before, move)
    for _, r in ipairs(reasons) do
        if r:find("^attacks") or r:find("checkmate") or r:find("^gives check") then
            return "Your opponent played " .. lower(desc) .. ". Watch out: it " .. Describe.joinReasons(reasons, 2) .. "."
        end
    end
    return nil
end

--[[
Hints, from vague to concrete (chess-app backend/coach/fallback.py hint_text).
  game: current position (player to move)
  best: engine line for it
  hint_level: 1 idea, 2 which piece, 3 the move
Returns text, and the squares to highlight.
--]]
function Coach.hint(game, best, hint_level)
    if not best or not best.pv or not best.pv[1] then
        return "No hint available right now."
    end
    local m = game:moveFromUci(best.pv[1])
    if not m then return "No hint available right now." end
    if hint_level >= 3 then
        return "Try " .. lower(Describe.move(game, m)) .. ".", { m.from, m.to }
    end
    if hint_level == 2 then
        return "Your " .. Describe.pieceOn(game, m.from) .. " wants to move.", { m.from }
    end
    if best.mate and best.mate > 0 then
        return "You can checkmate " .. mateIn(best.mate) .. ". Look at checks first!"
    end
    local them = Chess.opposite(game.turn)
    local loose = Describe.hangingPieces(game, them)
    if #loose > 0 and m.to == loose[1].square then
        return "Look for a loose piece: the " .. Describe.pieceOn(game, loose[1].square) .. " is not defended well."
    end
    local mine = Describe.hangingPieces(game, game.turn)
    if #mine > 0 and (m.from == mine[1].square) then
        return "Your " .. Describe.pieceOn(game, mine[1].square) .. " is in danger. Save it!"
    end
    local reasons = Describe.reasons(game, m)
    for _, r in ipairs(reasons) do
        if r:find("fork") then return "There is a move that attacks two pieces at once." end
        if r:find("^gives check") then return "Look for a strong check." end
        if r:find("^wins") then return "You can win material. Look at captures." end
        if r:find("^attacks") then return "Look for a move that makes a threat your opponent must answer." end
    end
    if m.flags == "castle_k" or m.flags == "castle_q" then
        return "Think about the safety of your king."
    end
    if game.fullmove <= 10 then
        local t = Chess.typeOf(m.piece)
        if t == "n" or t == "b" then return "Development: bring a knight or bishop into play." end
    end
    return "Look for checks, captures and threats, in that order."
end

-- Accuracy for one side of a game from its move accuracies (harmonic + mean blend).
function Coach.gameAccuracy(accuracies)
    if #accuracies == 0 then return nil end
    local sum, inv = 0, 0
    for _, a in ipairs(accuracies) do
        sum = sum + a
        inv = inv + 1 / math.max(a, 0.01)
    end
    local mean = sum / #accuracies
    local harmonic = #accuracies / inv
    return math.floor((mean + harmonic) / 2 * 10 + 0.5) / 10
end

return Coach
