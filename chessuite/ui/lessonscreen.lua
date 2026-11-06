--[[
One Lichess Practice lesson (chessuite/lichesspractice.lua), like the
Lichess app's practice chapter screens:
* practice: reach the goal against Stockfish; the computer answers with its
  best move, a mistake or blunder ends the try, the goal is checked after
  each move;
* gamebook: find the authored moves; the author's comment follows each
  move, a wrong move is taken back (with the author's note when there is one);
* lesson: step through an annotated game with ‹ ›.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local TextViewer = require("ui/widget/textviewer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BoardWidget = require("chessuite/ui/boardwidget")
local Chess = require("chessuite/chess")
local Common = require("chessuite/ui/common")
local Describe = require("chessuite/describe")
local LP = require("chessuite/lichesspractice")
local Store = require("chessuite/store")

-- Lichess counts an evaluation as solid from depth 16.
local SEARCH = { depth = 16, movetime = 6000 }
local REPLY_DELAY = 0.4

local function lower(s) return (s:gsub("^%u", string.lower)) end

local LessonScreen = Common.Page:extend{
    plugin = nil,
    study = nil,   -- a course of LichessPractice.sections()
    index = 1,     -- its lesson ("chapter") to play
}

local AUTO_DELAY = 1.0 -- an uncommented gamebook move is answered / taken back after this

function LessonScreen:init()
    self.engine = self.plugin:getEngine()
    self.lessons = self.study.chapters
    self:resetState()
    Common.Page.init(self)
    UIManager:nextTick(function() self:begin() end)
end

function LessonScreen:lesson() return self.lessons[self.index] end

function LessonScreen:resetState()
    local l = self:lesson()
    self.kind = l.kind or "practice"
    self.game = Chess.new(l.fen)
    self.color = l.orientation == "black" and "b" or "w"
    self.nb = 0          -- the player's moves so far
    self.state = "think" -- practice: think, play, reply, success, fail; gamebook: play, good, bad, success
    self.prev = nil      -- evaluation of the position the player moves in
    self.hint_level = 0
    self.wrong = nil
    self.title = self.study.name .. " · " .. self.index .. "/" .. #self.lessons
    local intro = l.description or ""
    if self.kind == "practice" then
        self:setShapes(LP.shapesFromList(l.shapes))
        self.feedback = { title = l.name, text = LP.goalText(l.goal, self.color)
            .. (intro ~= "" and ("\n" .. intro) or "") }
    else
        self.book = LP.parseGamebook(l)
        self:setShapes(self.book.start_shapes)
        local start = self.book.start_comment
        self.feedback = { title = l.name, text = intro .. ((intro ~= "" and start ~= "") and "\n\n" or "") .. start }
    end
end

-- Board circles and arrows from LP shapes.
function LessonScreen:setShapes(shapes)
    self.marks, self.arrows, self.badge = {}, {}, nil
    for _, sh in ipairs(shapes or {}) do
        if sh.square then
            self.marks[Chess.squareIndex(sh.square)] = "hint"
        else
            self.arrows[#self.arrows + 1] = { from = Chess.squareIndex(sh.from), to = Chess.squareIndex(sh.to),
                color = sh.color, thin = true }
        end
    end
end

function LessonScreen:begin()
    if self.kind == "practice" then return self:evaluateStart() end
    if self.kind == "lesson" then
        self.state = "watch"
        return self:refresh()
    end
    self.state = "play"
    if self.game.turn ~= self.color then
        -- the chapter starts with the opponent's move
        self.state = "good"
        self:scheduleAuto()
    end
    self:refresh()
end

-- Engine result -> { ev = White-side eval, best = uci }
function LessonScreen:toEval(game, res)
    local line = res and res.lines and res.lines[1]
    local sign = game.turn == "w" and 1 or -1
    local ev
    if line and line.mate then ev = { mate = line.mate * sign }
    elseif line then ev = { cp = (line.cp or 0) * sign }
    else
        -- no move: the game is over
        ev = { cp = 0 }
        if game:isCheckmate() then ev = { mate = game.turn == "w" and -1 or 1 } end
    end
    return { ev = ev, best = res and res.bestmove, pv = line and line.pv }
end

function LessonScreen:search(game, cb)
    local fen = game:fen()
    self.engine:search({ fen = fen, depth = SEARCH.depth, movetime = SEARCH.movetime }, nil, function(res)
        if self.closed or self.game:fen() ~= fen then return end
        cb(self:toEval(game, res))
    end)
end

function LessonScreen:evaluateStart()
    self.state = "think"
    self:refresh()
    local game = self.game
    self:search(game, function(e)
        if self.game ~= game then return end
        self.prev = e
        self.state = "play"
        self:refresh()
    end)
end

-- Layout ---------------------------------------------------------------------------

function LessonScreen:buildContent(width, height)
    local landscape = width > height
    local gap = Size.padding.default
    local side_w = landscape and math.floor(width * 0.42) or width
    local buttons = self:buildButtons(side_w)
    local inner = side_w - 2 * Size.padding.default - 2 * Size.border.thick
    local visual = self.state == "fail" and self.visual
    local fb = VerticalGroup:new{
        align = "left",
        Common.paragraph(self.feedback.title or "", inner, 20, { bold = true }),
        Common.paragraph(self.feedback.text or "", inner, 17, { height = Common.scale(visual and 96 or 120) }),
    }
    if visual then fb[#fb + 1] = Common.paragraph("▶ Tap here: see why on the board", inner, 15, { bold = true }) end
    local feedback = Common.box(fb)
    if visual then
        feedback = Common.TapBox:new{ feedback, callback = function()
            UIManager:show(require("chessuite/ui/explainpage"):new{ plugin = self.plugin, parts = visual,
                flipped = self.color == "b" })
        end }
    end
    local l = self:lesson()
    local status
    if self.kind == "practice" then
        status = (self.color == "w" and "You play White" or "You play Black")
            .. (l.goal and l.goal.moves and (" · move " .. self.nb .. " of " .. l.goal.moves) or "")
            .. (self.state == "think" and " · Stockfish is thinking…" or "")
    else
        status = (self.kind == "lesson" and "Step through the game" or (self.color == "w" and "You play White"
            or "You play Black")) .. " · move " .. self.nb .. " of " .. #self.book.moves
    end
    local info = Common.paragraph(status, side_w, 17, { bold = true })
    local used = feedback:getSize().h + info:getSize().h + buttons:getSize().h + 4 * gap
    local board_size = landscape and height or math.min(width, height - used)
    board_size = board_size - board_size % 8
    if not self.board or self.board.size ~= board_size then
        if self.board then self.board:free() end
        self.board = BoardWidget:new{
            size = board_size,
            plugin_dir = self.plugin.path,
            show_parent = self,
            show_legal = Store.get("show_legal_moves"),
            show_coords = Store.get("show_coordinates"),
            dark_color = Store.get("board_dark"),
            on_move = function(m) self:onBoardMove(m) end,
            on_promotion = function(_, _, cb) self:askPromotion(cb) end,
        }
    end
    self.board.game = self.game
    self.board.flipped = self.color == "b"
    self.board.player_color = self.color
    self.board.interactive = self.state == "play" and self.game.turn == self.color and self.kind ~= "lesson"
    self.board:setMarks(self.marks)
    self.board:setArrows(self.arrows)
    self.board:setBadge(self.badge and self.badge.square, self.badge and self.badge.class)
    if landscape then
        return HorizontalGroup:new{ align = "top", self.board, Common.hspace(2 * gap),
            VerticalGroup:new{ align = "left", feedback, Common.vspace(gap), info, Common.vspace(gap), buttons } }
    end
    return VerticalGroup:new{ align = "center", feedback, Common.vspace(gap), self.board, Common.vspace(gap),
        info, Common.vspace(gap), buttons }
end

function LessonScreen:buildButtons(width)
    local row
    local read = { text = "Read", callback = function() self:readText() end }
    local next_lesson = { text = "Next lesson ›", enabled = self.index < #self.lessons,
        callback = function() self:goLesson(self.index + 1) end }
    if self.kind == "lesson" then
        row = {
            read,
            { text = "‹", enabled = self.nb > 0, callback = function() self:lessonStep(-1) end },
            { text = "›", enabled = self.nb < #self.book.moves, callback = function() self:lessonStep(1) end },
            self.nb >= #self.book.moves and next_lesson or { text = "Lessons", callback = function() self:pickLesson() end },
        }
        return Common.buttonBar({ row }, width, self)
    end
    if self.kind == "gamebook" and self.state ~= "success" then
        row = { read }
        if self.state == "bad" then
            row[#row + 1] = { text = "Try again", callback = function() self:takeBackWrong() end }
        elseif self.state == "good" then
            row[#row + 1] = { text = "Next ›", enabled = not self.auto, callback = function() self:gamebookNext() end }
        else
            row[#row + 1] = { text = "Hint", callback = function() self:gamebookHint() end }
        end
        row[#row + 1] = { text = "Restart", callback = function() self:restart() end }
        row[#row + 1] = { text = "Lessons", callback = function() self:pickLesson() end }
        return Common.buttonBar({ row }, width, self)
    end
    if self.state == "success" then
        row = {
            read,
            { text = "Again", callback = function() self:restart() end },
            { text = self.index < #self.lessons and "Next lesson ›" or "Course done", enabled = self.index < #self.lessons,
              callback = function() self:goLesson(self.index + 1) end },
        }
    elseif self.state == "fail" then
        row = {
            { text = "Retry", callback = function() self:restart() end },
            { text = "Show best move", enabled = self.fail_best ~= nil, callback = function() self:showFailBest() end },
            { text = "Skip ›", enabled = self.index < #self.lessons, callback = function() self:goLesson(self.index + 1) end },
        }
    else
        row = {
            read,
            { text = "Hint", enabled = self.state == "play", callback = function() self:hint() end },
            { text = "Restart", callback = function() self:restart() end },
            { text = "Lessons", callback = function() self:pickLesson() end },
        }
    end
    return Common.buttonBar({ row }, width, self)
end

-- Playing ---------------------------------------------------------------------------

-- The whole text of the lesson, in a viewer that scrolls.
function LessonScreen:readText()
    local l = self:lesson()
    UIManager:show(TextViewer:new{
        title = l.name,
        text = (self.feedback.title and self.feedback.title ~= l.name and (self.feedback.title .. "\n\n") or "")
            .. (self.feedback.text or ""),
    })
end

-- Gamebooks and lessons -------------------------------------------------------------------

function LessonScreen:bookMove(ply) return self.book.moves[ply] end

-- After a correct move or at the start: the opponent's authored move follows on
-- its own, unless there is a comment to read first (then "Next").
function LessonScreen:scheduleAuto()
    local m = self:bookMove(self.nb + 1)
    local current = self:bookMove(self.nb)
    if not m then return end
    if current and current.comment and current.comment ~= "" then return end
    self.auto = true
    local game, nb = self.game, self.nb
    UIManager:scheduleIn(AUTO_DELAY, function()
        self.auto = false
        if self.closed or self.game ~= game or self.nb ~= nb or self.state ~= "good" then return end
        self:gamebookNext()
    end)
end

-- Plays the opponent's authored move.
function LessonScreen:gamebookNext()
    local m = self:bookMove(self.nb + 1)
    if not m then return self:gamebookDone() end
    local before = self.game:clone()
    local mv = self.game:move(m.uci)
    if not mv then return self:gamebookDone() end
    self.nb = self.nb + 1
    self:setShapes(m.shapes)
    self.feedback = { title = "Your opponent played " .. lower(Describe.move(before, mv)),
        text = m.comment or "Your move." }
    if self.nb >= #self.book.moves then return self:gamebookDone() end
    self.state = "play"
    self:refresh()
end

function LessonScreen:gamebookMove(m)
    local want = self:bookMove(self.nb + 1)
    local uci = Chess.uci(m)
    local before = self.game:clone()
    local said = Describe.move(before, m)
    local l = self:lesson()
    if want and (want.uci == uci or (want.uci:sub(1, 4) == uci:sub(1, 4) and #want.uci == 4)) then
        self.game:move(want.uci)
        self.nb = self.nb + 1
        self:setShapes(want.shapes)
        self.feedback = { title = said .. ". Good move!", text = want.comment or "" }
        if self.nb >= #self.book.moves then return self:gamebookDone() end
        self.state = "good"
        self:refresh()
        return self:scheduleAuto()
    end
    -- a wrong move stays on the board until it is taken back
    self.game:move(uci)
    self.wrong = true
    self.state = "bad"
    local note = want and want.alts[uci]
    if not note or note == "" then note = l.deviations and l.deviations[self.nb + 2] end
    self:setShapes(nil)
    self.badge = { square = m.to, class = "mistake" }
    self.feedback = { title = said .. " is not the move.", text = note or "Try again." }
    self:refresh()
    if not note or note == "" then
        local game = self.game
        UIManager:scheduleIn(AUTO_DELAY, function()
            if not self.closed and self.game == game and self.wrong then self:takeBackWrong() end
        end)
    end
end

function LessonScreen:takeBackWrong()
    if not self.wrong then return end
    self.game:undo()
    self.wrong = nil
    self.badge = nil
    self.state = "play"
    self.feedback.title = "Try again"
    self:refresh()
end

function LessonScreen:gamebookHint()
    local want = self:bookMove(self.nb + 1)
    if not want then return end
    local l = self:lesson()
    local hint = l.hints and l.hints[self.nb + 1]
    local m = self.game:moveFromUci(want.uci)
    if not m then return end
    self.hint_level = (hint and self.hint_level == 0) and 1 or 2
    if self.hint_level == 1 then
        self.feedback = { title = "Hint", text = hint }
    else
        self.arrows = { { from = m.from, to = m.to, color = "green" } }
        self.feedback = { title = "The move", text = Describe.move(self.game, m) .. "." }
    end
    self:refresh()
end

function LessonScreen:gamebookDone()
    local l = self:lesson()
    LP.setDone(self.study.id, l.id)
    self.state = "success"
    local last = self:bookMove(self.nb)
    self.feedback = { title = "Lesson complete!", text = (last and last.comment and (last.comment .. "\n\n") or "")
        .. (self.index < #self.lessons and "On to the next lesson." or "You finished the course!") }
    self:refresh()
end

-- Lesson chapters: step through the moves.
function LessonScreen:lessonStep(d)
    local target = math.max(0, math.min(#self.book.moves, self.nb + d))
    self.game = Chess.new(self:lesson().fen)
    for k = 1, target do self.game:move(self.book.moves[k].uci) end
    self.nb = target
    local m = self:bookMove(target)
    self:setShapes(m and m.shapes or self.book.start_shapes)
    self.feedback = { title = self:lesson().name .. (target > 0 and (" · move " .. target) or ""),
        text = (m and m.comment) or (target == 0 and (self:lesson().description or "")) or "" }
    if target >= #self.book.moves then LP.setDone(self.study.id, self:lesson().id) end
    self:refresh()
end

-- Practice -----------------------------------------------------------------------------

function LessonScreen:onBoardMove(m)
    if self.kind == "gamebook" then
        if self.state == "play" and self.game.turn == self.color then self:gamebookMove(m) end
        return
    end
    if self.state ~= "play" or self.game.turn ~= self.color then return end
    local before = self.game:clone()
    local prev = self.prev
    local uci = Chess.uci(m)
    self.game:move(uci)
    self.nb = self.nb + 1
    self.marks, self.arrows = nil, nil
    self.hint_level = 0
    self.state = "think"
    self.feedback = { title = Describe.move(before, m), text = "Let me see…" }
    self:refresh()
    local game = self.game
    self:search(game, function(e)
        if self.game ~= game then return end
        local verdict = LP.verdict(self.color, prev.ev, e.ev, uci, prev.best)
        local done = LP.success(self:lesson().goal, self.color, game, e.ev, verdict, self.nb, uci)
        if done == true then return self:succeed() end
        if done == false then return self:fail(before, m, verdict, prev.best, e) end
        if verdict == "inaccuracy" then self.badge = { square = m.to, class = "inaccuracy" } else self.badge = nil end
        -- the computer answers with its best move, like on Lichess
        self.state = "reply"
        self:refresh()
        UIManager:scheduleIn(REPLY_DELAY, function()
            if self.closed or self.game ~= game then return end
            local reply = e.best and self.game:moveFromUci(e.best)
            if not reply then return self:fail(before, m, verdict, prev.best, e) end
            local said = Describe.move(self.game, reply)
            self.game:move(e.best)
            self.feedback = { title = "Your move", text = "Your opponent played " .. lower(said) .. ". "
                .. LP.goalText(self:lesson().goal, self.color) }
            local result = self.game:gameResult({ no_claims = true })
            if result then
                local drawn = result == "1/2-1/2"
                local r = self:lesson().goal.result
                if drawn and (r == "drawIn" or r == "equalIn") then return self:succeed() end
                return self:fail(nil, nil, nil, nil, nil, "The game is over: " .. (drawn and "a draw." or "you lost."))
            end
            self:search(self.game, function(e2)
                self.prev = e2
                self.state = "play"
                self:refresh()
            end)
        end)
    end)
end

function LessonScreen:succeed()
    local l = self:lesson()
    LP.setDone(self.study.id, l.id)
    self.state = "success"
    self.badge = nil
    self.feedback = { title = "Success!", text = l.name .. " done. "
        .. (self.index < #self.lessons and "On to the next lesson." or "You finished the course!") }
    self:refresh()
end

function LessonScreen:fail(before, m, verdict, best, e, text)
    self.state = "fail"
    self.fail_best = nil
    self.visual = nil
    if before and best and (verdict == "mistake" or verdict == "blunder") then
        local bm = before:moveFromUci(best)
        if bm then self.fail_best = { from = bm.from, to = bm.to, text = Describe.move(before, bm) } end
        self.badge = { square = m.to, class = verdict }
        text = Describe.move(before, m) .. " is a " .. verdict .. ". Try again!"
        -- what the computer does about it, named and shown like the coach does
        local Explain = require("chessuite/explain")
        local pv = e and e.pv
        local ex = pv and Explain.punishment(before, m, pv)
        if ex and (ex.key or ex.mate or (ex.won or 0) >= 1) then
            text = Describe.move(before, m) .. " is a " .. verdict .. ": " .. ex.headline .. ". " .. ex.text .. " Try again!"
            self.visual = { { title = "Why it fails", headline = (ex.headline:gsub("^%l", string.upper)) .. ".",
                text = ex.text, steps = ex.steps, start = before } }
        end
    elseif not text then
        text = "The goal was not reached: " .. LP.goalText(self:lesson().goal, self.color):gsub("^%u", string.lower)
            .. " Try again!"
    end
    -- endgames: the exact verdict from the Lichess tablebase, when online
    if before and m then
        local NetworkMgr = require("ui/network/manager")
        local Coach = require("chessuite/coach")
        if Coach.pieceCount(before) <= 7 and NetworkMgr:isOnline() then
            local tb = Coach.tablebaseVerdict(self.plugin:lichess(), before, m)
            if tb then text = text:gsub(" Try again!$", "") .. " " .. tb .. " Try again!" end
        end
    end
    self.feedback = { title = "Not this time", text = text }
    self:refresh()
end

function LessonScreen:showFailBest()
    if not self.fail_best then return end
    self.arrows = { { from = self.fail_best.from, to = self.fail_best.to, color = "green" } }
    self.feedback.text = self.feedback.text .. " Better was " .. lower(self.fail_best.text) .. "."
    self:refresh()
end

function LessonScreen:hint()
    if self.state ~= "play" or not self.prev or not self.prev.best then return end
    local m = self.game:moveFromUci(self.prev.best)
    if not m then return end
    self.hint_level = math.min(2, self.hint_level + 1)
    if self.hint_level == 1 then
        self.marks = { [m.from] = "hint" }
        self.feedback.text = "Move the marked piece. Tap Hint again to see the move."
    else
        self.marks = nil
        self.arrows = { { from = m.from, to = m.to, color = "green" } }
        self.feedback.text = Describe.move(self.game, m) .. "."
    end
    self:refresh()
end

function LessonScreen:restart()
    self.engine:cancelAll()
    self:resetState()
    self:begin()
end

function LessonScreen:goLesson(i)
    self.index = math.max(1, math.min(#self.lessons, i))
    self:restart()
end

function LessonScreen:pickLesson()
    local dialog
    local rows = {}
    for i, l in ipairs(self.lessons) do
        rows[#rows + 1] = { {
            text = (LP.isDone(self.study.id, l.id) and "✓ " or "") .. i .. ". " .. l.name,
            callback = function() UIManager:close(dialog); self:goLesson(i) end,
        } }
    end
    dialog = ButtonDialog:new{ title = self.study.name, buttons = rows }
    UIManager:show(dialog)
end

function LessonScreen:askPromotion(cb)
    local dialog
    local function choose(p) UIManager:close(dialog); cb(p) end
    dialog = ButtonDialog:new{
        title = "Promote the pawn to",
        buttons = {
            { { text = "Queen", callback = function() choose("q") end },
              { text = "Knight", callback = function() choose("n") end } },
            { { text = "Rook", callback = function() choose("r") end },
              { text = "Bishop", callback = function() choose("b") end } },
        },
    }
    UIManager:show(dialog)
end

function LessonScreen:onClose()
    self.closed = true
    self.engine:cancelAll()
    if self.board then self.board:free() end
    return Common.Page.onClose(self)
end

return LessonScreen
