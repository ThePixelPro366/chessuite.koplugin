--[[
Lichess Practice (lichess.org/practice): the courses Lichess made for
checkmates, tactics and endgames, bundled like the Lichess mobile app does
it (chessuite/practice_data.lua, from the app's assets/practice.json).

A lesson ("chapter") is one of three kinds:
* practice: reach a goal against Stockfish; the goal ("mate in 3",
  "draw in 20", "+300cp in 4", "promotion with +100cp") is checked like
  Lichess' studyPracticeSuccess.ts, and a move is a mistake or a blunder by
  the drop in winning chances, like practiceCtrl.ts;
* gamebook: find the authored moves, with the author's comments;
* lesson: step through an annotated game.
--]]

local Chess = require("chessuite/chess")
local Store = require("chessuite/store")

local LP = {}

local data
function LP.data()
    if not data then
        local dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./chessuite/"
        local ok, d = pcall(dofile, dir .. "practice_data.lua")
        data = ok and d or { sections = {} }
    end
    return data
end

function LP.sections() return LP.data().sections end

function LP.study(id)
    for _, sec in ipairs(LP.sections()) do
        for _, s in ipairs(sec.studies) do if s.id == id then return s, sec end end
    end
end

-- Goals ------------------------------------------------------------------------

-- The goal in words, for the player of `color`.
function LP.goalText(goal, color)
    local function moves(n) return n == 1 and "1 move" or (n .. " moves") end
    if goal.result == "mate" then return "Checkmate the opponent." end
    if goal.result == "mateIn" then return "Checkmate the opponent in " .. moves(goal.moves) .. "." end
    if goal.result == "drawIn" then return "Hold the draw for " .. moves(goal.moves) .. "." end
    if goal.result == "equalIn" then return "Equalize in " .. moves(goal.moves) .. "." end
    if goal.result == "evalIn" then
        local pawns = math.abs(goal.cp) / 100
        return "Get a winning position (at least " .. (pawns == math.floor(pawns) and math.floor(pawns) or pawns)
            .. " pawn" .. (pawns == 1 and "" or "s") .. " ahead) in " .. moves(goal.moves) .. "."
    end
    if goal.result == "promotion" then return "Promote a pawn and keep a winning position." end
    return ""
end

-- Gamebooks ----------------------------------------------------------------------

-- The text of a PGN comment without its [%...] commands, and its shapes:
-- { { from = "e2", to = "e4", color = "green" }, { square = "f7", color = "red" } }
local SHAPE_COLORS = { G = "green", R = "red", B = "blue", Y = "blue" }
function LP.parseComment(c)
    local shapes = {}
    for kind, list in c:gmatch("%[%%(c[as]l)%s+([^%]]*)%]") do
        for item in list:gmatch("[^,%s]+") do
            local col, a, b = item:match("^(%u)(%l%d)(%l?%d?)$")
            if col then
                if kind == "cal" and b ~= "" then
                    shapes[#shapes + 1] = { from = a, to = b, color = SHAPE_COLORS[col] or "green" }
                else
                    shapes[#shapes + 1] = { square = a, color = SHAPE_COLORS[col] or "green" }
                end
            end
        end
    end
    local text = c:gsub("%[%%[^%]]*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return text, shapes
end

-- The shapes stored with a practice chapter: { "Gb2h8", "Ra8" }
function LP.shapesFromList(list)
    local text = {}
    for _, item in ipairs(list or {}) do
        text[#text + 1] = (#item > 3 and "[%cal " or "[%csl ") .. item .. "]"
    end
    local _, shapes = LP.parseComment(table.concat(text))
    return shapes
end

-- A chapter's PGN as its mainline: { start_comment, start_shapes, moves = { { uci, comment, shapes,
-- alts = { [uci] = comment } } } }. alts are the anticipated wrong moves and what the author says about them.
function LP.parseGamebook(chapter)
    local pgn = chapter.pgn or ""
    local body = pgn:gsub("%[%a+%s+\"[^\"]*\"%]%s*", "")
    local game = Chess.new(chapter.fen)
    local book = { moves = {}, start_comment = "", start_shapes = {} }
    local i, n = 1, #body
    local depth = 0
    local var_first -- in a variation: { ply, uci, comment } of its first move
    local var_game
    local function addComment(text, shapes)
        local target
        if depth == 0 then
            target = book.moves[#book.moves]
            if not target then
                book.start_comment = (book.start_comment ~= "" and (book.start_comment .. "\n") or "") .. text
                for _, sh in ipairs(shapes) do book.start_shapes[#book.start_shapes + 1] = sh end
                return
            end
            if text ~= "" then target.comment = (target.comment and (target.comment .. "\n") or "") .. text end
            for _, sh in ipairs(shapes) do target.shapes[#target.shapes + 1] = sh end
        elseif depth == 1 and var_first and var_first.comment == nil and text ~= "" then
            var_first.comment = text
        end
    end
    while i <= n do
        local ch = body:sub(i, i)
        if ch == "{" then
            local j = body:find("}", i, true) or n
            addComment(LP.parseComment(body:sub(i + 1, j - 1)))
            i = j + 1
        elseif ch == "(" then
            depth = depth + 1
            if depth == 1 then
                -- an alternative to the last mainline move
                local ply = #book.moves
                var_game = Chess.new(chapter.fen)
                for k = 1, ply - 1 do var_game:move(book.moves[k].uci) end
                var_first = { ply = ply }
            end
            i = i + 1
        elseif ch == ")" then
            if depth == 1 and var_first and var_first.uci then
                local target = book.moves[var_first.ply]
                if target then target.alts[var_first.uci] = var_first.comment or "" end
            end
            depth = math.max(0, depth - 1)
            if depth == 0 then var_first = nil end
            i = i + 1
        elseif ch:match("%s") then
            i = i + 1
        else
            local j = i
            while j <= n and not body:sub(j, j):match("[%s{}()]") do j = j + 1 end
            local token = body:sub(i, j - 1):gsub("^%d+%.+", "")
            i = j
            if token ~= "" and not token:match("^%$") and token ~= "*" and not token:match("^%d") then
                if depth == 0 then
                    local m = game:move(token)
                    if not m then break end
                    book.moves[#book.moves + 1] = { uci = Chess.uci(m), shapes = {}, alts = {} }
                elseif depth == 1 and var_first and not var_first.uci and var_game then
                    local m = var_game:moveFromSan(token)
                    if m then var_first.uci = Chess.uci(m) end
                end
            end
        end
    end
    return book
end

-- Progress: lessons done, by course and chapter.
function LP.done() return Store.get("lichess_practice_done") or {} end
function LP.setDone(study_id, chapter_id)
    local d = LP.done()
    d[study_id] = d[study_id] or {}
    d[study_id][chapter_id] = true
    Store.set("lichess_practice_done", d)
end
function LP.doneCount(study_id)
    local n = 0
    for _ in pairs(LP.done()[study_id] or {}) do n = n + 1 end
    return n
end
function LP.isDone(study_id, chapter_id) return (LP.done()[study_id] or {})[chapter_id] == true end

-- Lessons done out of all, and the course to resume: the first one not finished,
-- like the app's "Resume learning".
function LP.progress()
    local done, total, resume = 0, 0, nil
    for _, sec in ipairs(LP.sections()) do
        for _, st in ipairs(sec.studies) do
            local n = LP.doneCount(st.id)
            done = done + n
            total = total + #st.chapters
            if not resume and n > 0 and n < #st.chapters then resume = st end
        end
    end
    if not resume then
        for _, sec in ipairs(LP.sections()) do
            for _, st in ipairs(sec.studies) do
                if not resume and LP.doneCount(st.id) < #st.chapters then resume = st end
            end
        end
    end
    return done, total, resume
end

-- The first lesson of a course not done yet.
function LP.firstOngoing(study)
    for i, c in ipairs(study.chapters) do
        if not LP.isDone(study.id, c.id) then return i end
    end
    return 1
end

-- Judging moves ----------------------------------------------------------------------
-- Evaluations are { cp = n } or { mate = n } from White's side, like Lichess' ceval.

-- lib/ceval winningChances
local function rawChances(cp) return 2 / (1 + math.exp(-0.00368208 * cp)) - 1 end
function LP.winningChances(ev)
    if ev.mate then
        local cp = (21 - math.min(10, math.abs(ev.mate))) * 100
        return rawChances(ev.mate > 0 and cp or -cp)
    end
    return rawChances(math.max(-1000, math.min(1000, ev.cp or 0)))
end
local function povChances(color, ev)
    local c = LP.winningChances(ev)
    return color == "w" and c or -c
end

-- practiceCtrl.ts makeComment: "goodMove", "inaccuracy", "mistake" or "blunder".
-- prev/node: evaluations before and after the move, best: the engine's best move before it.
function LP.verdict(color, prev, node, played_uci, best_uci)
    if not best_uci or best_uci == played_uci then return "goodMove" end
    local shift = (povChances(color, prev) - povChances(color, node)) / 2
    if shift < 0.025 then return "goodMove" end
    if shift < 0.06 then return "inaccuracy" end
    if shift < 0.14 then return "mistake" end
    return "blunder"
end

local function isDrawish(ev) return not ev.mate and math.abs(ev.cp or 0) < 150 end
local function isWinning(ev, goal_cp, color)
    local cp = ev.mate and (ev.mate > 0 and 99999 or -99999) or ev.cp
    if color == "w" then return cp >= goal_cp end
    return cp <= goal_cp
end
local function myMateIn(ev, color)
    if not ev.mate then return false end
    local m = ev.mate * (color == "w" and 1 or -1)
    return m > 0 and m or false
end

-- studyPracticeSuccess.ts: true = goal reached, false = failed, nil = go on.
-- game: the position after the player's move; ev: its evaluation (White's side);
-- verdict: of the move; n: the player's moves so far; uci: the move.
function LP.success(goal, color, game, ev, verdict, n, uci)
    local result, reason = game:gameResult({ no_claims = true })
    if result and result ~= "1/2-1/2" then return (result == "1-0") == (color == "w") end
    if verdict == "mistake" or verdict == "blunder" then return false end
    local threefold = game:isThreefold()
    local draw_over = result == "1/2-1/2"
    local r = goal.result
    if r == "drawIn" or r == "equalIn" then
        if threefold then return true end
        if not draw_over and not isDrawish(ev) then return false end
        if n > goal.moves then return false end
        if draw_over then return true end
        if n >= goal.moves then return isDrawish(ev) end
    elseif r == "evalIn" then
        if n >= goal.moves then return isWinning(ev, goal.cp, color) end
    elseif r == "mateIn" then
        if n > goal.moves then return false end
        local m = myMateIn(ev, color)
        if not m or m + n > goal.moves then return false end
    elseif r == "promotion" then
        if #uci < 5 then return nil end
        return isWinning(ev, goal.cp, color)
    elseif r == "mate" then
        if threefold or draw_over then return false end
        if isDrawish(ev) then return false end
    end
    if draw_over then return false end -- a drawn game cannot reach the other goals
    return nil, reason
end

return LP
