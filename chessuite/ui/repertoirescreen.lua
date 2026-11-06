--[[
Opening trainer, after tabia (https://github.com/daxaur/tabia, MIT) and
chess.com's opening practice: openings in folders (gambits, classical,
defences, systems), each with its lines, and four ways to train them:

* Learn: walk through a line with ‹ ›; the next move is drawn as an arrow
  and the coach explains it.
* Practice: play your side, the trainer answers; a wrong move is taken back,
  try as often as you like. Nothing is scored.
* Drill: the scored one, with spaced repetition: a line played cleanly comes
  back later, a slip brings it back sooner. Due lines come first.
* Hyper: the trainer plays a random line of the opening as your opponent;
  answer with your repertoire, round after round.
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
local Repertoire = require("chessuite/repertoire")
local Store = require("chessuite/store")

local REPLY_DELAY = 0.6 -- before the trainer answers
local NEXT_DELAY = 1.5  -- before the next line in Drill

local function lower(s) return (s:gsub("^%u", string.lower)) end
local function sideName(c) return c == "w" and "White" or "Black" end

local MODES = {
    { id = "learn", name = "Learn", about = "Walk through a line with ‹ ›. The next move is shown as an arrow." },
    { id = "practice", name = "Practice", about = "Play your side; wrong moves are taken back. Nothing is scored." },
    { id = "drill", name = "Drill", about = "Scored, with spaced repetition: clean lines come back later, slips sooner." },
    { id = "hyper", name = "Hyper", about = "The trainer plays a random line as your opponent. Hold your repertoire." },
}

-- Pages of tiles that fit the screen, with ‹ › to turn pages.
local function pagedTiles(page, entries, header, width, height)
    local nav_h = Common.scale(60)
    local probe = Common.Tile:new{ width = width, title = "X", subtitle = "X\nX", icon = "opening" }
    local tile_h = probe:getSize().h + Common.scale(8)
    local per_page = math.max(1, math.floor((height - header:getSize().h - nav_h) / tile_h))
    local pages = math.max(1, math.ceil(#entries / per_page))
    page.page = math.max(1, math.min(page.page or 1, pages))
    local tiles = {}
    for i = (page.page - 1) * per_page + 1, math.min(#entries, page.page * per_page) do
        local e = entries[i]
        e.width = width
        e.show_parent = page
        tiles[#tiles + 1] = Common.Tile:new(e)
    end
    local list = VerticalGroup:new{ align = "left", header, Common.tileGrid(tiles, width, 1, Common.scale(8)) }
    if pages > 1 then
        list[#list + 1] = Common.vspace(Common.scale(8))
        list[#list + 1] = Common.buttonBar({ {
            { text = "‹", enabled = page.page > 1, callback = function() page.page = page.page - 1; page:refresh() end },
            { text = page.page .. " / " .. pages, enabled = false },
            { text = "›", enabled = page.page < pages, callback = function() page.page = page.page + 1; page:refresh() end },
        } }, width, page)
    end
    return list
end

-- The openings -------------------------------------------------------------------------

local RepertoireScreen = Common.Page:extend{
    title = "Openings",
    plugin = nil,
}

function RepertoireScreen:init()
    self.category = Store.get("repertoire_category") or Repertoire.categories()[1]
    Common.Page.init(self)
end

function RepertoireScreen:buildContent(width, height)
    local tabs = {}
    for _, c in ipairs(Repertoire.categories()) do
        tabs[#tabs + 1] = { text = (self.category == c and "★ " or "") .. c, callback = function()
            self.category = c
            self.page = 1
            Store.set("repertoire_category", c)
            self:refresh()
        end }
    end
    local header = VerticalGroup:new{
        align = "left",
        Common.paragraph("Learn an opening line by line, then drill it until it sticks.", width, 17),
        Common.vspace(Common.scale(8)),
        Common.buttonBar({ tabs }, width, self),
        Common.vspace(Common.scale(10)),
    }
    local entries = {}
    for _, op in ipairs(Repertoire.openings()) do
        if op.category == self.category then
            local s = Repertoire.summary(op)
            local status = sideName(op.color) .. " · " .. s.total .. " lines"
                .. (s.seen > 0 and (" · " .. s.mastered .. " mastered") or "")
            entries[#entries + 1] = {
                title = op.name,
                badge = s.seen > 0 and s.due > 0 and (s.due .. " due") or nil,
                subtitle = status .. "\n" .. (op.oneLiner or ""),
                icon = s.mastered == s.total and "trophy" or "opening",
                callback = function()
                    UIManager:show(RepertoireScreen.Course:new{ plugin = self.plugin, op = op,
                        on_close = function() if not self.closed then self:refresh() end end })
                end,
            }
        end
    end
    return pagedTiles(self, entries, header, width, height)
end

function RepertoireScreen:onClose()
    self.closed = true
    return Common.Page.onClose(self)
end

-- One opening: its lines and the modes -----------------------------------------------------

local Course = Common.Page:extend{
    plugin = nil,
    op = nil,
}
RepertoireScreen.Course = Course

function Course:init()
    self.title = self.op.name
    Common.Page.init(self)
end

function Course:buildContent(width, height)
    local op = self.op
    local s = Repertoire.summary(op)
    local modes = {}
    for _, m in ipairs(MODES) do
        modes[#modes + 1] = { text = m.name, callback = function() self:train(m.id) end }
    end
    local header = VerticalGroup:new{
        align = "left",
        Common.paragraph((op.oneLiner or "") .. "\nYou play " .. sideName(op.color) .. " · " .. s.total .. " lines · "
            .. s.mastered .. " mastered" .. (s.seen > 0 and s.due > 0 and (" · " .. s.due .. " due") or ""), width, 16),
        Common.vspace(Common.scale(8)),
        Common.paragraph("Train all lines:", width, 16, { bold = true }),
        Common.buttonBar({ modes }, width, self),
        Common.vspace(Common.scale(10)),
    }
    local entries = {}
    for _, l in ipairs(op.lines) do
        local st = Repertoire.state(op.id, l.id)
        local seen = st.seen > 0 or st.disc
        local group = op.groups and op.groups[l.group]
        entries[#entries + 1] = {
            title = (l.star and "★ " or "") .. l.name,
            badge = seen and (Repertoire.isDue(op.id, l.id) and "due" or Repertoire.dots(st.box)) or "new",
            subtitle = (group and (group.label .. ": ") or "") .. (l.idea or ""),
            icon = st.box >= Repertoire.MASTERED_BOX and "trophy" or "opening",
            callback = function() self:pickMode(l) end,
        }
    end
    return pagedTiles(self, entries, header, width, height)
end

-- A line: learn it first, drill it once it has been seen.
function Course:pickMode(line)
    local dialog
    local rows = {}
    for _, m in ipairs(MODES) do
        if m.id ~= "hyper" then
            rows[#rows + 1] = { { text = m.name .. ": " .. m.about, callback = function()
                UIManager:close(dialog)
                self:train(m.id, { line.id })
            end } }
        end
    end
    dialog = ButtonDialog:new{ title = line.name, buttons = rows }
    UIManager:show(dialog)
end

function Course:train(mode, scope)
    if not scope then
        scope = {}
        for _, l in ipairs(self.op.lines) do scope[#scope + 1] = l.id end
    end
    UIManager:show(RepertoireScreen.Trainer:new{ plugin = self.plugin, op = self.op, mode = mode, scope = scope,
        on_close = function() if not self.closed then self:refresh() end end })
end

function Course:onClose()
    self.closed = true
    return Common.Page.onClose(self)
end

-- The board ------------------------------------------------------------------------

local Trainer = Common.Page:extend{
    plugin = nil,
    op = nil,
    mode = "learn",
    scope = nil, -- line ids to train
}
RepertoireScreen.Trainer = Trainer

function Trainer:init()
    self.color = self.op.color
    self.correct, self.wrong, self.rounds = 0, 0, 0
    self.ply, self.hint_level = 0, 0
    self.game = Chess.new()
    self.feedback = { title = self.op.name, text = "" }
    self:setTitle()
    Common.Page.init(self)
    UIManager:nextTick(function() self:start() end)
end

function Trainer:setTitle()
    for _, m in ipairs(MODES) do
        if m.id == self.mode then self.title = self.op.name .. " · " .. m.name end
    end
end

function Trainer:start()
    if self.mode == "hyper" then return self:newRound() end
    self:nextLine()
end

-- The next line: the due and weakest first (in Drill), else in order.
function Trainer:nextLine()
    local id
    if self.mode == "drill" then
        id = Repertoire.pickNext(self.op.id, self.scope)
    else
        local idx = 0
        for i, s in ipairs(self.scope) do if self.line and s == self.line.id then idx = i end end
        id = self.scope[idx % #self.scope + 1]
    end
    self:beginLine(Repertoire.line(self.op, id))
end

function Trainer:beginLine(line)
    self.line = line
    self.ply = 0
    self.mistake = false
    self.hint_level = 0
    self.done = false
    self.game = Chess.new()
    self.marks, self.arrows, self.badge = nil, nil, nil
    Repertoire.discover(self.op.id, line.id)
    if self.mode == "learn" then
        self.feedback = { title = line.name, text = Repertoire.say("learn") .. " " .. (line.idea or "") }
        self:showNextArrow()
        return self:refresh()
    end
    self.feedback = { title = line.name, text = line.idea or "" }
    if self.game.turn ~= self.color then return self:opponentMove() end
    self.feedback.text = self.feedback.text .. "\n" .. Repertoire.say("start")
    self:refresh()
end

-- The move of the line at the current ply (a move table), or nil at its end.
function Trainer:expected()
    local m = self.line and self.line.moves[self.ply + 1]
    return m and self.game:moveFromSan(m[1]), m and m[2]
end

function Trainer:showNextArrow()
    local m = self:expected()
    self.arrows = m and { { from = m.from, to = m.to, color = "green" } } or nil
end

-- Layout -----------------------------------------------------------------------

function Trainer:buildContent(width, height)
    local landscape = width > height
    local gap = Size.padding.default
    local side_w = landscape and math.floor(width * 0.42) or width
    local buttons = self:buildButtons(side_w)
    local inner = side_w - 2 * Size.padding.default - 2 * Size.border.thick
    local feedback = Common.box(VerticalGroup:new{
        align = "left",
        Common.paragraph(self.feedback.title or "", inner, 19, { bold = true }),
        Common.paragraph(self.feedback.text or "", inner, 16, { height = Common.scale(96) }),
    })
    local status
    if self.mode == "hyper" then
        status = "Round " .. self.rounds .. " · you play " .. sideName(self.color)
    else
        local idx = 0
        for i, s in ipairs(self.scope) do if self.line and s == self.line.id then idx = i end end
        local box = self.line and Repertoire.mastery(self.op.id, self.line.id) or 0
        status = "Line " .. idx .. " of " .. #self.scope .. " · " .. Repertoire.dots(box)
            .. ((self.mode ~= "learn") and ("   ✓ " .. self.correct .. "  ✗ " .. self.wrong) or "")
    end
    local info = Common.paragraph(status, side_w, 16, { bold = true })
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
            on_promotion = function(_, _, cb) cb("q") end,
        }
    end
    self.board.game = self.game
    self.board.flipped = (self.color == "b") ~= (self.color_view == true)
    self.board.player_color = self.mode ~= "learn" and self.color or nil
    self.board.interactive = not self.done and not self.waiting
        and (self.mode == "learn" or self.game.turn == self.color)
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

function Trainer:buildButtons(width)
    local more = { text = "More", callback = function() self:showMenu() end }
    local row
    if self.mode == "learn" then
        row = {
            { text = "‹", enabled = self.ply > 0, callback = function() self:learnStep(-1) end },
            { text = "›", enabled = self.line ~= nil and self.ply < #self.line.moves, callback = function() self:learnStep(1) end },
            { text = #self.scope > 1 and "Next line" or "Again", callback = function()
                if #self.scope > 1 then self:nextLine() else self:beginLine(self.line) end
            end },
            more,
        }
    elseif self.mode == "hyper" then
        row = {
            { text = "Hint", enabled = not self.done and not self.waiting, callback = function() self:hint() end },
            { text = "New round", callback = function() self:newRound() end },
            more,
        }
    else
        row = {
            { text = "Hint", enabled = not self.done and not self.waiting, callback = function() self:hint() end },
            { text = self.done and "Next line" or (self.mode == "drill" and "Skip" or "Restart"), callback = function()
                if self.done or self.mode == "drill" then self:nextLine() else self:beginLine(self.line) end
            end },
            more,
        }
    end
    return Common.buttonBar({ row }, width, self)
end

function Trainer:showMenu()
    local dialog
    local rows = {}
    for _, m in ipairs(MODES) do
        rows[#rows + 1] = { { text = (m.id == self.mode and "★ " or "") .. m.name .. ": " .. m.about, callback = function()
            UIManager:close(dialog)
            self.mode = m.id
            self:setTitle()
            self:start()
        end } }
    end
    rows[#rows + 1] = { { text = "Play on from here against Stockfish", enabled = self.game:plyCount() > 0, callback = function()
        UIManager:close(dialog)
        self:playOn()
    end } }
    rows[#rows + 1] = { { text = "Flip board", callback = function()
        UIManager:close(dialog)
        self.color_view = not self.color_view
        self:refresh()
    end } }
    dialog = ButtonDialog:new{ title = self.op.name, buttons = rows }
    UIManager:show(dialog)
end

-- Learn ----------------------------------------------------------------------------

function Trainer:learnStep(dir)
    if not self.line then return end
    if dir > 0 then
        local m, note = self:expected()
        if not m then return end
        local said = Describe.move(self.game, m)
        self.game:move(Chess.uci(m))
        self.ply = self.ply + 1
        self.feedback = { title = (m.piece == m.piece:upper() and "White: " or "Black: ") .. said,
            text = note or "" }
        if self.ply >= #self.line.moves then
            self.feedback.text = (note and (note .. "\n") or "")
                .. "That's the whole line. Switch to Practice (More) to play it yourself."
        end
    else
        if self.ply <= 0 then return end
        self.game:undo()
        self.ply = self.ply - 1
        local prev = self.line.moves[self.ply]
        self.feedback = { title = self.line.name, text = (prev and prev[2]) or self.line.idea or "" }
    end
    self:showNextArrow()
    self:refresh()
end

-- Practice and drill -----------------------------------------------------------------------

function Trainer:onBoardMove(m)
    if self.mode == "hyper" then return self:hyperMove(m) end
    local want, note = self:expected()
    if not want then return end
    local same = m.from == want.from and m.to == want.to
    if self.mode == "learn" then
        if same then return self:learnStep(1) end
        self.feedback = { title = "Not that one", text = "The next move is " .. lower(Describe.move(self.game, want))
            .. ". Play it, or tap ›." }
        return self:refresh()
    end
    if self.game.turn ~= self.color then return end
    local said = Describe.move(self.game, m)
    if same then
        if self.hint_level == 0 then self.correct = self.correct + 1 end
        self.game:move(Chess.uci(want))
        self.ply = self.ply + 1
        self.hint_level = 0
        self.marks, self.arrows, self.badge = nil, nil, nil
        self.feedback = { title = said, text = Repertoire.say("correct", nil, self.line.messages)
            .. (note and (" " .. note) or "") }
        return self:afterUserMove()
    end
    -- a wrong move
    local exp = lower(Describe.move(self.game, want))
    self.mistake = true
    self.wrong = self.wrong + 1
    self.feedback = { title = said .. "?", text = Repertoire.say("wrong", { exp = exp }, self.line.messages) }
    if self.mode == "practice" then
        -- try again as often as you like
        self.board:clearSelection()
        return self:refresh()
    end
    -- drill: the right move is shown and played, and the line goes on
    self.feedback.text = self.feedback.text .. (self.feedback.text:find(exp, 1, true) and "" or (" The move is " .. exp .. "."))
    self.arrows = { { from = want.from, to = want.to, color = "green" } }
    self.waiting = true
    self:refresh()
    local game = self.game
    UIManager:scheduleIn(1.2, function()
        if self.closed or self.game ~= game then return end
        self.game:move(Chess.uci(want))
        self.ply = self.ply + 1
        self.arrows = nil
        self.waiting = false
        self:afterUserMove()
    end)
end

function Trainer:afterUserMove()
    if self.ply >= #self.line.moves then return self:finishLine() end
    self:opponentMove()
end

function Trainer:opponentMove()
    self.waiting = true
    self:refresh()
    local game = self.game
    UIManager:scheduleIn(REPLY_DELAY, function()
        if self.closed or self.game ~= game then return end
        local m, note = self:expected()
        self.waiting = false
        if not m then return self:finishLine() end
        local said = Describe.move(self.game, m)
        self.game:move(Chess.uci(m))
        self.ply = self.ply + 1
        -- keep the verdict on your move, then the answer
        local verdict = self.feedback.title ~= self.line.name and self.feedback.text:match("^[^%.!]*[%.!]") or nil
        self.feedback = { title = "Your move", text = (verdict and (verdict .. " ") or "") .. "Your opponent: "
            .. lower(said) .. "." .. (note and (" " .. note) or "") }
        if self.ply >= #self.line.moves then return self:finishLine() end
        self:refresh()
    end)
end

function Trainer:finishLine()
    self.done = true
    self.waiting = false
    local ok = not self.mistake
    if self.mode == "drill" then
        local st = Repertoire.record(self.op.id, self.line.id, ok)
        local days = math.floor(Repertoire.INTERVALS[st.box] / 86400 + 0.5)
        self.feedback = { title = ok and "Line complete!" or "Line complete, with a slip",
            text = Repertoire.say(ok and "done" or "doneMiss", nil, self.line.messages)
                .. (days > 0 and (" Next review in " .. days .. (days == 1 and " day." or " days.")) or " It comes back now.") }
        self:refresh()
        if #self.scope > 1 then
            local line = self.line
            UIManager:scheduleIn(NEXT_DELAY, function()
                if not self.closed and self.line == line and self.done and self.mode == "drill" then self:nextLine() end
            end)
        end
        return
    end
    self.feedback = { title = "Line complete!", text = ok and "Played without a slip. Ready to Drill it (More)."
        or "Play it again until it is clean, then Drill it (More)." }
    self:refresh()
end

function Trainer:hint()
    local want
    if self.mode == "hyper" then want = self:hyperExpected() else want = self:expected() end
    if not want then return end
    self.hint_level = math.min(2, self.hint_level + 1)
    if self.hint_level == 1 then
        self.marks = { [want.from] = "hint" }
        self.feedback = { title = "Hint", text = "Move the marked piece." }
    else
        self.marks = nil
        self.arrows = { { from = want.from, to = want.to, color = "green" } }
        self.feedback = { title = "Hint", text = Describe.move(self.game, want) .. "." }
    end
    self:refresh()
end

-- Hyper: the trainer plays a random line ------------------------------------------------------

function Trainer:newRound()
    self.rounds = self.rounds + 1
    self.game = Chess.new()
    self.hyper_ply = 0
    self.candidates = {}
    for _, id in ipairs(self.scope) do self.candidates[#self.candidates + 1] = Repertoire.line(self.op, id) end
    self.done = false
    self.hint_level = 0
    self.line = nil
    self.marks, self.arrows, self.badge = nil, nil, nil
    if self.game.turn ~= self.color then
        self.feedback = { title = "Round " .. self.rounds, text = "I open as White; answer with your repertoire." }
        return self:hyperBot()
    end
    self.feedback = { title = "Round " .. self.rounds, text = "You're " .. sideName(self.color)
        .. ". Play your repertoire and I'll answer." }
    self:refresh()
end

local function sanAt(line, ply) return line.moves[ply] and line.moves[ply][1] end

function Trainer:hyperExpected()
    for _, l in ipairs(self.candidates or {}) do
        local san = sanAt(l, self.hyper_ply + 1)
        if san then return self.game:moveFromSan(san) end
    end
end

-- Lines that go on with this move (a move table) at the next ply.
function Trainer:matching(m)
    local out = {}
    for _, l in ipairs(self.candidates) do
        local san = sanAt(l, self.hyper_ply + 1)
        local lm = san and self.game:moveFromSan(san)
        if lm and lm.from == m.from and lm.to == m.to then out[#out + 1] = l end
    end
    return out
end

function Trainer:hyperMove(m)
    if self.done or self.game.turn ~= self.color then return end
    local matching = self:matching(m)
    if #matching == 0 then
        local exp = self:hyperExpected()
        self.feedback = { title = Describe.move(self.game, m) .. "?", text = exp
            and Repertoire.say("offBook", { exp = lower(Describe.move(self.game, exp)) }, { offBook = self.op.offBook })
            or "That leaves your repertoire." }
        self.board:clearSelection()
        return self:refresh()
    end
    self.candidates = matching
    self.feedback = { title = Describe.move(self.game, m), text = "Good. My turn…" }
    self.game:move(Chess.uci(m))
    self.hyper_ply = self.hyper_ply + 1
    self.hint_level = 0
    self.marks, self.arrows = nil, nil
    if not self:hyperGoesOn() then return self:hyperWin() end
    self:hyperBot()
end

function Trainer:hyperGoesOn()
    for _, l in ipairs(self.candidates) do if sanAt(l, self.hyper_ply + 1) then return true end end
    return false
end

function Trainer:hyperBot()
    self.waiting = true
    self:refresh()
    local game = self.game
    UIManager:scheduleIn(REPLY_DELAY, function()
        if self.closed or self.game ~= game then return end
        self.waiting = false
        local cands = {}
        for _, l in ipairs(self.candidates) do if sanAt(l, self.hyper_ply + 1) then cands[#cands + 1] = l end end
        if #cands == 0 then return self:hyperWin() end
        local pick = cands[math.random(#cands)]
        local m = self.game:moveFromSan(sanAt(pick, self.hyper_ply + 1))
        if not m then return self:hyperWin() end
        self.candidates = self:matching(m)
        local said = Describe.move(self.game, m)
        self.game:move(Chess.uci(m))
        self.hyper_ply = self.hyper_ply + 1
        if not self:hyperGoesOn() then return self:hyperWin() end
        self.feedback = { title = "Your move", text = "I played " .. lower(said) .. "." }
        self:refresh()
    end)
end

function Trainer:hyperWin()
    self.done = true
    self.waiting = false
    local line = self.candidates[1]
    if line then Repertoire.record(self.op.id, line.id, true) end
    self.feedback = { title = "You held the line!", text = (line and ("That was the " .. line.name .. ". ") or "")
        .. "Tap New round to face another." }
    self:refresh()
end

-- Play on --------------------------------------------------------------------------

function Trainer:playOn()
    local GameScreen = require("chessuite/ui/gamescreen")
    local Bots = require("chessuite/bots")
    Store.clearSavedGame()
    local moves = self.game:uciHistory()
    local on_close = self.on_close
    self.on_close = nil
    self:onClose()
    UIManager:show(GameScreen:new{ plugin = self.plugin, bot = Bots.stockfishAt(Store.playerRating()),
        player_color = self.color, start_moves = moves, on_close = on_close })
end

function Trainer:onClose()
    self.closed = true
    if self.board then self.board:free() end
    return Common.Page.onClose(self)
end

return RepertoireScreen
