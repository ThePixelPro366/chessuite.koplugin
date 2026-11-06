--[[
Full-screen Lichess puzzle trainer, modelled on the Lichess mobile app
(lib/src/view/puzzle, lib/src/model/puzzle/puzzle_controller.dart):

* the board starts before the opponent's last move, which is then played;
* a correct move is answered after half a second ("Best move!");
* a wrong move counts as a loss right away, like on Lichess, and like on
  chess.com the board shows why: an arrow for the opponent's refutation,
  found by Stockfish, and the reason in words, with a Retry button;
* a hint marks the piece to move and makes the puzzle unrated (not failed);
* "View solution" lets you step through the solution with ‹ ›;
* when the puzzle is over you can step through it, explore on the board,
  open the analysis board or continue training.

Results are sent to Lichess (and queued while offline) and change your
Lichess puzzle rating.

Puzzle Streak (streak = true), like on Lichess: puzzles get harder every
five solved, one wrong move ends the run, one skip per run. Not rated.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BoardWidget = require("chessuite/ui/boardwidget")
local Chess = require("chessuite/chess")
local Common = require("chessuite/ui/common")
local Describe = require("chessuite/describe")
local Engine = require("chessuite/uci")
local Puzzles = require("chessuite/puzzles")
local Store = require("chessuite/store")

local OPPONENT_DELAY = 1.0  -- before the opponent's first move
local REPLY_DELAY = 0.5     -- before the opponent answers a correct move
local SOLUTION_DELAY = 0.8  -- before the first solution move is shown
local BUTTON_LOCK = 4       -- hint and solution are disabled for the first seconds

local PuzzleScreen = Common.Page:extend{
    title = "Lichess puzzles",
    plugin = nil,
    daily = false, -- the daily puzzle, unrated, no account needed
    streak = false, -- Puzzle Streak
    opening = nil,  -- { key, name }: puzzles from games in this opening (Lichess' "By openings")
}

local STREAK_STEP = 5 -- solved puzzles per difficulty step

local function lower(s) return (s:gsub("^%u", string.lower)) end

function PuzzleScreen:init()
    -- puzzles by opening use the opening as the puzzle theme while this page is open
    local before = Store.get("puzzle_angle_before_opening")
    if before then
        Store.set("puzzle_angle", before)
        Store.settings():delSetting("puzzle_angle_before_opening")
    end
    if self.opening then
        Store.set("puzzle_angle_before_opening", Store.get("puzzle_angle"))
        Store.set("puzzle_angle", self.opening.key)
        self.title = self.opening.name
        self.left_icon = nil
    elseif self.streak then
        self.title = "Puzzle Streak"
        self.streak_count = 0
        self.skip_left = 1
        self.streak_queue = {}
    else
        self.left_icon = "appbar.settings"
        self.left_icon_tap_callback = function() self:showOptions() end
    end
    self.feedback = { title = "Loading a puzzle…", text = "" }
    self.session = {} -- one entry per puzzle: { id, win, diff }
    Common.Page.init(self)
    UIManager:nextTick(function() self:nextPuzzle() end)
end

-- Layout ---------------------------------------------------------------------

function PuzzleScreen:ratingText()
    if self.daily then return "Daily puzzle · not rated" end
    if self.streak then
        return "Streak: " .. self.streak_count .. "   Best: " .. Store.bestStreak()
            .. "   Level: " .. Puzzles.DIFFICULTIES[self:streakLevel()].name
    end
    local r = Store.get("puzzle_rating")
    local t = "Rating " .. (r and tostring(r) or "?")
    local parts = {}
    for _, s in ipairs(self.session) do
        if s.diff then parts[#parts + 1] = string.format("%+d", s.diff)
        else parts[#parts + 1] = s.win and "✓" or "×" end
    end
    if #parts > 0 then t = t .. "   " .. table.concat(parts, " ") end
    local pending = #Store.pendingResults()
    if pending > 0 then t = t .. "   (" .. pending .. " to send)" end
    return t
end

function PuzzleScreen:buildContent(width, height)
    local landscape = width > height
    local gap = Size.padding.default
    local side_w = landscape and math.floor(width * 0.42) or width
    local buttons = self:buildButtons(side_w)
    local bh = buttons:getSize().h

    local inner = side_w - 2 * Size.padding.default - 2 * Size.border.thick
    local visual = self.mode == "wrong" and self.visual
    local fb = VerticalGroup:new{
        align = "left",
        Common.paragraph(self.feedback.title or "", inner, 20, { bold = true }),
        Common.paragraph(self.feedback.text or "", inner, 17, { height = Common.scale(visual and 96 or 70) }),
    }
    if visual then fb[#fb + 1] = Common.paragraph("▶ Tap here: see why on the board", inner, 15, { bold = true }) end
    local feedback = Common.box(fb)
    if visual then
        feedback = Common.TapBox:new{ feedback, callback = function()
            UIManager:show(require("chessuite/ui/explainpage"):new{ plugin = self.plugin, parts = visual,
                flipped = self.color == "b" })
        end }
    end
    local status = Common.paragraph(self:ratingText(), side_w, 17, { bold = true })
    local used = feedback:getSize().h + status:getSize().h + bh + 4 * gap
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
    local viewing = self:isViewingPast()
    self.board.game = viewing and self:positionAt(self.view_ply) or self.game
    self.board.flipped = (self.color == "b") ~= (self.flip == true)
    if self.mode == "view" then
        self.board.player_color = nil -- explore freely, both sides
        self.board.interactive = self.game ~= nil
    else
        self.board.player_color = self.color
        self.board.interactive = self.mode == "play" and not self.waiting and not viewing
    end
    if viewing then
        self.board:setMarks(nil)
        self.board:setArrows(nil)
        self.board:setBadge(nil)
    else
        self.board:setMarks(self.marks)
        self.board:setArrows(self.arrows)
        self.board:setBadge(self.badge and self.badge.square, self.badge and self.badge.class)
    end

    if landscape then
        local side = VerticalGroup:new{
            align = "left", feedback, Common.vspace(gap), status, Common.vspace(gap), buttons,
        }
        return HorizontalGroup:new{ align = "top", self.board, Common.hspace(2 * gap), side }
    end
    return VerticalGroup:new{
        align = "center",
        feedback, Common.vspace(gap), self.board, Common.vspace(gap), status, Common.vspace(gap), buttons,
    }
end

function PuzzleScreen:buildButtons(width)
    local ply, last = self:currentPly(), self.game and self.game:plyCount() or 0
    local first = self.start_ply or 0
    local nav_back = { text = "‹", enabled = self.game ~= nil and ply > first and not self.waiting,
        callback = function() self:viewPly(ply - 1) end }
    local nav_fwd = { text = "›", enabled = self.game ~= nil and ply < last and not self.waiting,
        callback = function() self:viewPly(ply + 1) end }
    local row
    if self.streak and (self.mode == "wrong" or self.streak_over) then
        row = {
            { text = "Solution", enabled = self.mode == "wrong", callback = function() self:showSolution() end },
            { text = "New streak", callback = function() self:newStreak() end },
            { text = "Close", callback = function() self:onClose() end },
            nav_back, nav_fwd,
        }
    elseif self.streak and self.mode ~= "view" then
        local unlocked = self.mode == "play" and not self.waiting
        row = {
            { text = "Skip" .. (self.skip_left > 0 and " (1 left)" or ""), enabled = unlocked and self.skip_left > 0,
              callback = function() self:skipStreakPuzzle() end },
            { text = "Give up", enabled = unlocked, callback = function() self:endStreak(); self:showSolution() end },
        }
    elseif self.mode == "wrong" then
        row = {
            { text = "Retry", callback = function() self:retry() end },
            { text = "Solution", callback = function() self:showSolution() end },
            { text = self.daily and "Close" or "Next", callback = function()
                if self.daily then self:onClose() else self:nextPuzzle() end
            end },
        }
    elseif self.mode == "view" then
        row = {
            { text = "Menu", callback = function() self:showMenu() end },
            { text = "Analysis", callback = function() self:analyze() end },
            self.daily and { text = "Close", callback = function() self:onClose() end }
                or { text = "Continue training", enabled = not self.waiting, callback = function() self:nextPuzzle() end },
            nav_back, nav_fwd,
        }
    else
        local unlocked = self.mode == "play" and not self.waiting and (self.unlock_at or 0) <= os.time()
        row = {
            { text = self.hint_shown and "★ Hint" or "Hint", enabled = unlocked,
              callback = function() self:toggleHint() end },
            { text = "View solution", enabled = unlocked, callback = function() self:showSolution() end },
            nav_back, nav_fwd,
        }
    end
    return Common.buttonBar({ row }, width, self)
end

-- Moving through the puzzle ------------------------------------------------------

function PuzzleScreen:currentPly()
    if not self.game then return 0 end
    return self.view_ply or self.game:plyCount()
end

function PuzzleScreen:isViewingPast()
    return self.view_ply ~= nil and self.game ~= nil and self.view_ply < self.game:plyCount()
end

function PuzzleScreen:positionAt(ply)
    local g = Chess.new(self.game.start_fen)
    local moves = self.game:uciHistory()
    for i = 1, math.min(ply, #moves) do g:move(moves[i]) end
    return g
end

function PuzzleScreen:viewPly(ply)
    if not self.game then return end
    ply = math.max(self.start_ply or 0, math.min(ply, self.game:plyCount()))
    self.view_ply = ply < self.game:plyCount() and ply or nil
    if self.board then self.board:clearSelection() end
    self:refresh()
end

-- Loading ---------------------------------------------------------------------

function PuzzleScreen:nextPuzzle()
    if self.closed then return end
    if self.streak then return self:nextStreakPuzzle() end
    if self.game and self.mode == "play" and self.moved and not self.daily then
        -- leaving a started puzzle counts as a loss
        self:record(false)
    end
    if self.daily then return self:loadDaily() end
    local entry = Puzzles.take()
    if entry then
        self:start(entry)
        if #Puzzles.cached() < 10 then
            -- top up quietly for offline use; failures do not matter here
            UIManager:scheduleIn(2, function() self:backgroundSync(true) end)
        end
        return
    end
    Common.whenOnline(function()
        local client = self.plugin:lichess()
        local ok, err = Common.busy("Fetching puzzles from Lichess…", function()
            Puzzles.sync(client)
            return Puzzles.refill(client)
        end)
        if self.closed then return end
        entry = ok and Puzzles.take()
        if entry then
            self:start(entry)
        else
            self.game = nil
            self.mode = nil
            self.feedback = { title = "No more puzzles",
                text = "Go online to get more. " .. (err and ("(" .. tostring(err) .. ")") or "") }
            self:refresh()
        end
    end)
end

-- Puzzle Streak -------------------------------------------------------------------

function PuzzleScreen:streakLevel()
    return math.min(#Puzzles.DIFFICULTIES, math.floor(self.streak_count / STREAK_STEP) + 1)
end

function PuzzleScreen:nextStreakPuzzle()
    local level = self:streakLevel()
    local queue = self.streak_queue
    while queue[1] and queue[1].level ~= level do table.remove(queue, 1) end
    local item = table.remove(queue, 1)
    if item then return self:start(item.entry) end
    Common.whenOnline(function()
        local client = self.plugin:lichess()
        local ok, data = Common.busy("Fetching puzzles from Lichess…", function()
            return client:puzzleBatch("mix", 10, Puzzles.DIFFICULTIES[level].id)
        end)
        if self.closed then return end
        if ok and type(data) == "table" and data.puzzles then
            for _, e in ipairs(data.puzzles) do queue[#queue + 1] = { level = level, entry = e } end
        end
        item = table.remove(queue, 1)
        if item then return self:start(item.entry) end
        -- offline: the puzzles kept for normal training
        local entry = Puzzles.take()
        if entry then return self:start(entry) end
        self.game = nil
        self.mode = nil
        self.feedback = { title = "No puzzles", text = "Puzzle Streak needs the internet. " .. tostring(data or "") }
        self:refresh()
    end)
end

function PuzzleScreen:skipStreakPuzzle()
    if self.skip_left <= 0 then return end
    self.skip_left = 0
    self:nextStreakPuzzle()
end

function PuzzleScreen:endStreak()
    if self.streak_over then return end
    self.streak_over = true
    local record = Store.noteStreak(self.streak_count)
    self.streak_text = "Streak over: " .. self.streak_count .. " puzzle" .. (self.streak_count == 1 and "" or "s")
        .. (record and self.streak_count > 0 and ". A new best!" or ".")
end

function PuzzleScreen:newStreak()
    self.streak_count = 0
    self.skip_left = 1
    self.streak_over = false
    self.streak_text = nil
    self:nextStreakPuzzle()
end

function PuzzleScreen:loadDaily()
    Common.whenOnline(function()
        local client = self.plugin:lichess()
        local ok, data = Common.busy("Fetching the daily puzzle…", function() return client:puzzleDaily() end)
        if self.closed then return end
        if ok and type(data) == "table" and data.puzzle then
            self:start(data)
        else
            self.feedback = { title = "No daily puzzle", text = "Could not get it: " .. tostring(data) }
            self:refresh()
        end
    end)
end

function PuzzleScreen:start(entry)
    local game, color, solution = Puzzles.toGame(entry)
    if not game then
        self.feedback = { title = "Broken puzzle", text = "This puzzle could not be set up." }
        self.mode = "view"
        self:refresh()
        return
    end
    self.engine_job = nil
    if self.plugin.engine then self.plugin.engine:cancelAll() end
    self.entry = entry
    self.puzzle = entry.puzzle
    self.color = color
    self.solution = solution
    self.step = 1
    self.result = nil       -- true / false once known
    self.reported = false
    self.hint_shown = false
    self.hint_used = false
    self.moved = false
    self.waiting = true
    self.view_ply = nil
    self.marks, self.arrows, self.badge = nil, nil, nil
    -- show the position before the opponent's move, then play it
    local opening = game:lastMove()
    local opening_uci = opening and Chess.uci(opening)
    if opening then game:undo() end
    self.game = game
    self.start_ply = game:plyCount()
    self.mode = "load"
    self.feedback = { title = "Your turn",
        text = "Find the best move for " .. (color == "w" and "white" or "black") .. "." }
    self:refresh("full")
    UIManager:scheduleIn(opening_uci and OPPONENT_DELAY or 0, function()
        if self.closed or self.game ~= game then return end
        if opening_uci then game:move(opening_uci) end
        self.mode = "play"
        self.waiting = false
        self.unlock_at = os.time() + BUTTON_LOCK
        self:refresh()
        UIManager:scheduleIn(BUTTON_LOCK + 0.1, function()
            if not self.closed and self.game == game and self.mode == "play" then self:refresh() end
        end)
    end)
end

-- Playing ---------------------------------------------------------------------

function PuzzleScreen:onBoardMove(m)
    if self.mode == "view" then return self:explore(m) end
    if self.mode ~= "play" or self.waiting then return end
    local uci = Chess.uci(m)
    self.moved = true
    self.marks = nil
    self.hint_shown = false
    if Puzzles.isCorrect(self.game, self.solution, self.step, uci) then
        self.game:move(uci)
        if self.game:isCheckmate() or self.step >= #self.solution then
            self:complete(self.result ~= false)
            return
        end
        self.feedback = { title = "Best move!", text = "Keep going…" }
        self.waiting = true
        self:refresh()
        local game = self.game
        UIManager:scheduleIn(REPLY_DELAY, function()
            if self.closed or self.game ~= game then return end
            local reply = self.solution[self.step + 1]
            if reply then self.game:move(reply) end
            self.step = self.step + 2
            self.waiting = false
            self:refresh()
        end)
        return
    end
    self:wrongMove(m)
end

-- A wrong move: it counts as a loss now; show the opponent's refutation.
function PuzzleScreen:wrongMove(m)
    self.visual = nil
    local before = self.game:clone()
    self.game:move(Chess.uci(m))
    self:record(false)
    self.mode = "wrong"
    self.badge = { square = m.to, class = "miss" }
    self.feedback = { title = self.streak and self.streak_text or "Incorrect",
        text = Describe.move(before, m) .. " is not the move. Looking for why…" }
    self:refresh()
    local game = self.game
    local fen = self.game:fen()
    local engine = self.plugin:getEngine()
    engine:search({ fen = fen, depth = 12, movetime = 2500, multipv = 1 }, nil, function(res)
        if self.closed or self.game ~= game or self.mode ~= "wrong" then return end
        local line = res and res.lines and res.lines[1]
        self.feedback.text = self:refutationText(before, m, line)
        -- name the tactic that refutes the move, and keep its line for "see why"
        local Explain = require("chessuite/explain")
        local e = line and line.pv and Explain.punishment(before, m, line.pv)
        if e and (e.key or e.mate or (e.won or 0) >= 1) then
            self.feedback.text = "Nice try, but " .. e.headline .. ". " .. e.text
                .. (self.streak and "" or " Tap Retry to try again.")
            self.visual = { { title = "Why it fails", headline = (e.headline:gsub("^%l", string.upper)) .. ".",
                text = e.text, steps = e.steps, start = before } }
        end
        if self.streak then self.feedback.text = self.feedback.text:gsub(" Tap Retry to try again%.", "") end
        local reply = res and res.lines and res.lines[1] and res.lines[1].pv and res.lines[1].pv[1]
        local rm = reply and game:moveFromUci(reply)
        if rm then self.arrows = { { from = rm.from, to = rm.to, color = "red" } } end
        self:refresh()
    end)
end

function PuzzleScreen:refutationText(before, m, line)
    local tried = Describe.move(before, m)
    local after = before:clone()
    after:makeMove(m)
    if after:isCheckmate() then return tried .. " is checkmate, but not the puzzle's line. Try the solution's move." end
    local reply = line and line.pv and line.pv[1] and after:moveFromUci(line.pv[1])
    if not reply then
        return "Nice try, but " .. lower(tried) .. " is not the move. Tap Retry to try again."
    end
    local text = "Nice try, but your opponent can answer " .. lower(Describe.move(after, reply))
    local why = Describe.reasons(after, reply)
    local good = {}
    for _, r in ipairs(why) do
        if r:find("^wins") or r:find("^attacks") or r:find("^gives check") then good[#good + 1] = r end
    end
    if #good > 0 then text = text .. ", which " .. Describe.joinReasons(good, 2) end
    if line.mate and line.mate > 0 then
        text = text .. (line.mate == 1 and "" or (" and checkmates in " .. line.mate .. " moves"))
    elseif line.mate and line.mate < 0 then
        text = text .. ", and you still win, but more slowly"
    elseif (Engine.lineCp(line) or 0) > 150 then
        text = text .. ", and then your opponent is better"
    elseif (Engine.lineCp(line) or 0) > -150 then
        text = text .. ", and your advantage is gone"
    end
    return text .. ". Tap Retry to try again."
end

function PuzzleScreen:retry()
    if self.plugin.engine then self.plugin.engine:cancelAll() end
    if self.game:plyCount() > (self.start_ply or 0) then self.game:undo() end
    self.mode = "play"
    self.arrows, self.badge, self.marks = nil, nil, nil
    self.feedback = { title = "Your turn",
        text = "Find the best move for " .. (self.color == "w" and "white" or "black") .. "." }
    self:refresh()
end

function PuzzleScreen:complete(win)
    self.mode = "view"
    self.waiting = false
    self.marks, self.arrows = nil, nil
    if win then self:record(true) end
    self:updateViewFeedback()
    if self.streak and win then
        self.feedback = { title = "Streak: " .. self.streak_count .. "!", text = "Next puzzle…" }
        local game = self.game
        UIManager:scheduleIn(1, function()
            if not self.closed and self.game == game and self.mode == "view" then self:nextStreakPuzzle() end
        end)
        self:refresh()
        return
    end
    if win and Store.get("puzzle_auto_next") and not self.daily then
        UIManager:scheduleIn(1, function()
            if not self.closed and self.mode == "view" then self:nextPuzzle() end
        end)
    end
    self:refresh()
end

function PuzzleScreen:updateViewFeedback()
    local p = self.puzzle or {}
    local info = "Rating: " .. (p.rating or "?") .. ". Played " .. (p.plays or "?") .. " times."
    if self.streak and self.streak_over then
        self.feedback = { title = self.streak_text, text = info }
    elseif self.result then
        self.feedback = { title = "Success!", text = info }
    else
        self.feedback = { title = "Puzzle complete!", text = info }
    end
end

-- Exploring after the puzzle: moves for both sides, from the shown position.
function PuzzleScreen:explore(m)
    local ply = self:currentPly()
    while self.game:plyCount() > ply do self.game:undo() end
    self.game:move(Chess.uci(m))
    self.view_ply = nil
    self:refresh()
end

-- Records the result once per puzzle and sends it when online.
function PuzzleScreen:record(win)
    if self.reported then return end
    self.reported = true
    self.result = win
    if self.daily then return end
    if self.streak then
        if win then self.streak_count = self.streak_count + 1 else self:endStreak() end
        return
    end
    local rated = Store.get("puzzle_rated") and not self.hint_used
    Store.recordPuzzle(win)
    Store.addPendingResult(Store.get("puzzle_angle"), { id = self.puzzle.id, win = win, rated = rated })
    self.session[#self.session + 1] = { id = self.puzzle.id, win = win }
    UIManager:scheduleIn(0.3, function() self:backgroundSync(false) end)
end

-- Send results (and top up the cache) when the network is already up.
function PuzzleScreen:backgroundSync(refill)
    local NetworkMgr = require("ui/network/manager")
    if self.closed or not NetworkMgr:isOnline() then return end
    local client = self.plugin:lichess()
    local ok, info = Puzzles.sync(client)
    if ok and info then
        for _, s in ipairs(self.session) do
            if info.diffs[s.id] then s.diff = info.diffs[s.id] end
        end
    end
    if refill then Puzzles.refill(client) end
    if not self.closed then self:refresh() end
end

function PuzzleScreen:toggleHint()
    if self.mode ~= "play" then return end
    self.hint_shown = not self.hint_shown
    if self.hint_shown then
        local expected = self.solution[self.step]
        local m = expected and self.game:moveFromUci(expected)
        if not m then return end
        self.hint_used = true -- the result will be sent as unrated, like on lichess
        self.marks = { [m.from] = "hint" }
    else
        self.marks = nil
    end
    self:refresh()
end

function PuzzleScreen:showSolution()
    if self.plugin.engine then self.plugin.engine:cancelAll() end
    -- take back a wrong move first
    if self.mode == "wrong" and self.game:plyCount() > (self.start_ply or 0) then self.game:undo() end
    self:record(false)
    local from = self.game:plyCount()
    for i = self.step, #self.solution do
        if not self.game:move(self.solution[i]) then break end
    end
    self.mode = "view"
    self.arrows, self.badge, self.marks = nil, nil, nil
    self:updateViewFeedback()
    self.feedback.text = "Step through the solution with › . " .. self.feedback.text
    -- show the position before the solution, then its first move
    self.view_ply = from < self.game:plyCount() and from or nil
    self.waiting = true
    self:refresh()
    UIManager:scheduleIn(SOLUTION_DELAY, function()
        if self.closed then return end
        self.waiting = false
        self:viewPly(from + 1)
    end)
end

function PuzzleScreen:askPromotion(cb)
    local dialog
    local function choose(p) UIManager:close(dialog); cb(p) end
    -- the order of the lichess promotion picker
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

function PuzzleScreen:showMenu()
    local dialog
    local function item(text, fn)
        return { text = text, callback = function() UIManager:close(dialog); fn() end }
    end
    dialog = ButtonDialog:new{
        title = "Puzzle " .. ((self.puzzle and self.puzzle.id) or ""),
        buttons = {
            { item("Flip board", function() self.flip = not self.flip; self:refresh() end) },
            { item("Analysis board", function() self:analyze() end) },
            { item("Settings", function() self:showOptions() end) },
        },
    }
    UIManager:show(dialog)
end

function PuzzleScreen:analyze()
    if not self.game then return end
    local AnalysisScreen = require("chessuite/ui/analysisscreen")
    -- the puzzle from its start position, with the moves played since
    local start = self:positionAt(self.start_ply or 0)
    local g = Chess.new(start:fen())
    local moves = self.game:uciHistory()
    for i = (self.start_ply or 0) + 1, #moves do g:move(moves[i]) end
    UIManager:show(AnalysisScreen:new{ plugin = self.plugin, game = g, player_color = self.color,
        title = "Puzzle analysis" })
end

-- Settings popup: theme, difficulty, rated, jump to next.
function PuzzleScreen:showOptions()
    if self.daily then return end
    local dialog
    local rows = {}
    local row = {}
    local function changed()
        -- a new selection does not count as a loss for the current puzzle
        if self.mode == "play" then self.moved = false end
        Puzzles.setCached({})
        self:nextPuzzle()
    end
    for _, t in ipairs(Puzzles.THEMES) do
        row[#row + 1] = {
            text = (Store.get("puzzle_angle") == t.id and "★ " or "") .. t.name,
            callback = function()
                UIManager:close(dialog)
                Store.set("puzzle_angle", t.id)
                changed()
            end,
        }
        if #row == 2 then rows[#rows + 1] = row; row = {} end
    end
    if #row > 0 then rows[#rows + 1] = row end
    local drow = {}
    for _, d in ipairs(Puzzles.DIFFICULTIES) do
        drow[#drow + 1] = {
            text = (Store.get("puzzle_difficulty") == d.id and "★" or "") .. d.name,
            callback = function()
                UIManager:close(dialog)
                Store.set("puzzle_difficulty", d.id)
                changed()
            end,
        }
    end
    rows[#rows + 1] = drow
    rows[#rows + 1] = { {
        text = "Rated: " .. (Store.get("puzzle_rated") and "yes" or "no"),
        callback = function() UIManager:close(dialog); Store.toggle("puzzle_rated"); self:showOptions() end,
    }, {
        text = "Jump to next puzzle immediately: " .. (Store.get("puzzle_auto_next") and "on" or "off"),
        callback = function() UIManager:close(dialog); Store.toggle("puzzle_auto_next"); self:showOptions() end,
    } }
    dialog = ButtonDialog:new{ title = "Puzzle settings", buttons = rows }
    UIManager:show(dialog)
end

function PuzzleScreen:onClose()
    if self.opening and Store.get("puzzle_angle_before_opening") then
        Store.set("puzzle_angle", Store.get("puzzle_angle_before_opening"))
        Store.settings():delSetting("puzzle_angle_before_opening")
        Store.settings():flush()
    end
    self.closed = true
    if self.plugin.engine then self.plugin.engine:cancelAll() end
    if self.board then self.board:free() end
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

return PuzzleScreen
