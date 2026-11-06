--[[
Full-screen analysis board, modelled on the Lichess mobile app
(lib/src/view/analysis, lib/src/model/analysis):

* bottom bar: Menu · Flip · Engine · ‹ · ›, everything else in the menu;
* playing a different move makes a variation, the game stays the main line;
* the engine (bundled Stockfish, or the Lichess cloud) shows its best lines;
* computer analysis (review): every move gets ?! ? ?? (Lichess' thresholds)
  and a comment in plain words, with a summary table (accuracy,
  inaccuracies, mistakes, blunders, average centipawn loss);
* "Learn from your mistakes": go back to each mistake and find a better
  move (lib/src/model/analysis/retro_controller.dart);
* show threat, continue from here against Stockfish, open on Lichess.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputDialog = require("ui/widget/inputdialog")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local BoardWidget = require("chessuite/ui/boardwidget")
local Chess = require("chessuite/chess")
local Coach = require("chessuite/coach")
local Common = require("chessuite/ui/common")
local Describe = require("chessuite/describe")
local Engine = require("chessuite/uci")
local Lichess = require("chessuite/lichess")
local Openings = require("chessuite/openings")
local Store = require("chessuite/store")

-- The review has time: it searches deeper than the coach during a game.
-- movetime is only a cap for very slow devices.
local REVIEW_MOVETIME_CAP = 10000
local BOOK_MAX_PLY = 24
-- "Learn from your mistakes": a move other than the engine's is still right
-- when it loses at most this much winning chance. Lichess uses 4 points at
-- depth 18 with a modern Stockfish; Stockfish 11 at depth 16 on an e-reader
-- wobbles more between two positions, so a little more room is given.
local RETRO_TOLERANCE = 8
local RETRO_CLASSES = { mistake = true, blunder = true, miss = true }

-- Horizontal evaluation bar: the white part is White's winning chance.
local EvalBar = Widget:extend{ width = 300, height = 20, white_percent = 50 }
function EvalBar:getSize() return Geom:new{ w = self.width, h = self.height } end
function EvalBar:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_BLACK)
    local ww = math.floor((self.width - 4) * self.white_percent / 100)
    bb:paintRect(x + 2, y + 2, ww, self.height - 4, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x + math.floor(self.width / 2), y, 2, self.height, Blitbuffer.COLOR_GRAY_7)
end

local AnalysisScreen = Common.Page:extend{
    title = "Analysis",
    plugin = nil,
    game = nil,           -- a Chess object with the moves to look at
    review = false,       -- start the computer analysis right away
    player_color = nil,   -- whose side the review and its mistakes talk to
}

local function lower(s) return (s:gsub("^%u", string.lower)) end

function AnalysisScreen:init()
    self.engine = self.plugin:getEngine()
    self.game = self.game or Chess.new()
    self.start_fen = self.game.start_fen
    self.mainline = self.game:uciHistory()
    self.moves = self.mainline
    self.var_from = nil   -- ply where the current variation leaves the main line
    self.ply = #self.moves
    self.flipped = self.player_color == "b"
    self.engine_on = Store.get("analysis_engine") ~= false
    self.left_icon = "appbar.menu"
    self.left_icon_tap_callback = function() self:showMenu() end
    self.pos = self:positionAt(self.ply)
    Common.Page.init(self)
    UIManager:nextTick(function()
        if self.review then self:startReview() else self:analyse() end
    end)
end

function AnalysisScreen:positionAt(ply)
    local g = Chess.new(self.start_fen)
    for i = 1, ply do
        if not g:move(self.moves[i]) then break end
    end
    return g
end

-- The review's verdict on the move that led to `ply`, only on the main line.
function AnalysisScreen:judgementAt(ply)
    if not self.reviewed then return nil end
    if self.var_from and ply > self.var_from then return nil end
    return self.reviewed[ply]
end

-- Text -----------------------------------------------------------------------

local function evalWords(line, turn)
    if not line then return "" end
    if line.mate then
        local white_mates = (line.mate > 0) == (turn == "w")
        local n = math.abs(line.mate)
        return (white_mates and "White" or "Black") .. " mates in " .. n
    end
    local cp = Engine.lineCp(line)
    local wp = Engine.winPercent(turn == "w" and cp or -cp)
    if wp >= 90 then return "White is winning"
    elseif wp >= 65 then return "White is better"
    elseif wp >= 56 then return "White is slightly better"
    elseif wp > 44 then return "About equal"
    elseif wp > 35 then return "Black is slightly better"
    elseif wp > 10 then return "Black is better" end
    return "Black is winning"
end

-- "+0.32", "#3", "#-3" from White's side, like lichess.
local function score(line, turn)
    if not line then return "" end
    local sign = turn == "w" and 1 or -1
    if line.mate then return "#" .. (line.mate * sign) end
    return string.format("%+.2f", (line.cp or 0) * sign / 100)
end

function AnalysisScreen:whitePercent()
    local lines = self:shownLines()
    local l = lines and lines[1]
    if not l then return 50 end
    local cp = Engine.lineCp(l)
    if self.pos.turn == "b" then cp = -cp end
    return Engine.winPercent(cp)
end

-- The engine lines to show: the live engine's, else those of the computer
-- analysis for this position (so every reviewed move shows its best line at once).
function AnalysisScreen:shownLines()
    if self.lines and #self.lines > 0 then return self.lines, self.source end
    if self.evals and not (self.var_from and self.ply > self.var_from) then
        local e = self.evals[self.ply]
        if e and e.lines and #e.lines > 0 then
            return e.lines, (e.lines[1].cloud and "cloud" or e.lines[1].lichess and "lichess" or "review")
        end
    end
    return nil
end

function AnalysisScreen:lineText(l)
    local words = Store.get("move_words")
    local text
    if words then
        text = Describe.line(self.pos, l.pv, 3)
    else
        local g = self.pos:clone()
        local parts = {}
        for i = 1, math.min(#l.pv, 8) do
            local m = g:moveFromUci(l.pv[i])
            if not m then break end
            parts[#parts + 1] = g:san(m)
            g:makeMove(m)
        end
        text = table.concat(parts, " ")
    end
    return score(l, self.pos.turn) .. "  " .. text
end

-- The text panel: retro feedback, review summary or comment, engine lines.
function AnalysisScreen:panelText()
    local parts = {}
    if self.retro then
        parts[#parts + 1] = self.retro.title
        if self.retro.text then parts[#parts + 1] = self.retro.text end
        return table.concat(parts, "\n")
    end
    if self.message then parts[#parts + 1] = self.message end
    if self.ply == 0 and self.summary and not self.var_from then parts[#parts + 1] = self.summary end
    local j = self:judgementAt(self.ply)
    if j and j.text then parts[#parts + 1] = j.text end
    if self.threat then parts[#parts + 1] = self.threat end
    local lines, source = self:shownLines()
    if lines then
        local head = evalWords(lines[1], self.pos.turn)
        head = head .. " · " .. (source == "cloud" and "Lichess cloud" or source == "lichess" and "Lichess analysis"
            or "Stockfish")
        if lines[1].depth then head = head .. ", depth " .. lines[1].depth end
        parts[#parts + 1] = "Best moves: " .. head
        for _, l in ipairs(lines) do
            if l.pv and #l.pv > 0 then parts[#parts + 1] = self:lineText(l) end
        end
    end
    if self.engine_running and not (self.lines and #self.lines > 0) then
        parts[#parts + 1] = "Stockfish is thinking…"
    end
    local result, reason = self.pos:gameResult()
    if result then parts[#parts + 1] = "Game over: " .. result .. " by " .. reason .. "." end
    if #parts == 0 then
        parts[1] = self.engine_on and "" or "Engine is off. Tap Engine to analyse this position."
    end
    return table.concat(parts, "\n")
end

-- "Italian Game · Move 5, White: Knight to f3 ?! inaccuracy"
function AnalysisScreen:headerText()
    local parts = {}
    local opening = Openings.current(self.pos)
    if opening then parts[#parts + 1] = opening end
    if self.ply == 0 then
        parts[#parts + 1] = "Start position"
    else
        local prev = self:positionAt(self.ply - 1)
        local m = prev:moveFromUci(self.moves[self.ply])
        local t = "Move " .. prev.fullmove .. (prev.turn == "w" and ", White: " or ", Black: ")
            .. (m and Describe.move(prev, m) or self.moves[self.ply])
        local j = self:judgementAt(self.ply)
        if j then t = t .. "  " .. Coach.tag(j.class) end
        parts[#parts + 1] = t
    end
    if self.var_from then parts[#parts + 1] = "(variation)" end
    return table.concat(parts, " · ")
end

-- The moves around the current one, with review symbols; [ ] marks the current move.
function AnalysisScreen:moveStripText()
    if #self.moves == 0 then return "" end
    local words = Store.get("move_words")
    local replay = Chess.new(self.start_fen)
    local parts = {}
    for i = 1, #self.moves do
        local m = replay:moveFromUci(self.moves[i])
        if not m then break end
        local text = words and Describe.move(replay, m, { no_check = true }) or replay:san(m)
        local j = self:judgementAt(i)
        if j and Coach.symbol(j.class) ~= "" and Coach.PROBLEMS[j.class] then text = text .. Coach.symbol(j.class) end
        if replay.turn == "w" then text = replay.fullmove .. ". " .. text
        elseif i == 1 then text = replay.fullmove .. "… " .. text end
        if i == self.ply then text = "[" .. text .. "]" end
        parts[#parts + 1] = text
        replay:makeMove(m)
    end
    local before, after = words and 1 or 4, words and 1 or 4
    local first = math.max(1, self.ply - before)
    local last = math.min(#parts, math.max(self.ply, 1) + after)
    return (first > 1 and "… " or "") .. table.concat(parts, "  ", first, last) .. (last < #parts and " …" or "")
end

-- Layout ---------------------------------------------------------------------

function AnalysisScreen:buildContent(width, height)
    local landscape = width > height
    local gap = Size.padding.default
    local side_w = landscape and math.floor(width * 0.42) or width
    local buttons = self:buildButtons(side_w)
    local bh = buttons:getSize().h
    local head = Common.paragraph(self:headerText(), side_w, 16, { bold = true })
    local bar = EvalBar:new{ width = side_w, height = Common.scale(12), white_percent = self:whitePercent() }
    local strip = Common.paragraph(self:moveStripText(), side_w, 16, { height = Common.scale(44) })
    local panel_min = Common.scale(120)
    local used = head:getSize().h + bar:getSize().h + strip:getSize().h + bh + 6 * gap
    local board_size = landscape and height or math.min(width, height - used - panel_min)
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
    self.board.game = self.pos
    self.board.flipped = self.flipped
    if self.retro then
        self.board.interactive = self.retro.state == "find" and self.pos.turn == self.retro.side
        self.board.player_color = self.retro.side
    else
        self.board.interactive = not self.reviewing
        self.board.player_color = nil
    end
    local marks, arrows = {}, {}
    if self.retro then
        for _, a in ipairs(self.retro.arrows or {}) do arrows[#arrows + 1] = a end
    else
        -- Stockfish's recommended moves, like the lichess analysis board: the best
        -- one thick, the next ones thinner
        if not self.reviewing then
            for k, l in ipairs(self:shownLines() or {}) do
                local m = l.pv and l.pv[1] and self.pos:moveFromUci(l.pv[1])
                if m then
                    arrows[#arrows + 1] = { from = m.from, to = m.to, color = k == 1 and "blue" or "green",
                        thin = k > 1 }
                end
                if k >= 3 then break end
            end
        end
        if self.threat_arrow then arrows[#arrows + 1] = self.threat_arrow end
    end
    self.board:setMarks(marks)
    self.board:setArrows(arrows)
    local j = not self.retro and self:judgementAt(self.ply)
    local last = self.moves[self.ply]
    self.board:setBadge(j and last and Chess.squareIndex(last:sub(3, 4)), j and j.class)

    local panel_h = (landscape and height or (height - board_size)) - used
        - 2 * Size.padding.default - 2 * Size.border.thick
    local inner_w = side_w - 2 * Size.padding.default - 2 * Size.border.thick
    -- a reviewed move with an explanation: tap the panel to see it on the board
    local visual = j and (j.visual or j.needs_why)
    local panel_group = VerticalGroup:new{ align = "left" }
    local why_line
    if visual then
        why_line = Common.paragraph("▶ Tap here: see why on the board", inner_w, 15, { bold = true })
        panel_h = panel_h - why_line:getSize().h
    end
    panel_group[#panel_group + 1] = Common.paragraph(self:panelText(), inner_w, 16,
        { height = math.max(panel_h, Common.scale(40)) })
    if why_line then panel_group[#panel_group + 1] = why_line end
    local panel = Common.box(panel_group)
    if visual then
        local ply = self.ply
        panel = Common.TapBox:new{ panel, callback = function() self:showWhy(ply) end }
    end
    if landscape then
        local side = VerticalGroup:new{
            align = "left", head, Common.vspace(gap), bar, Common.vspace(gap), strip, Common.vspace(gap),
            panel, Common.vspace(gap), buttons,
        }
        return HorizontalGroup:new{ align = "top", self.board, Common.hspace(2 * gap), side }
    end
    return VerticalGroup:new{
        align = "center",
        head, Common.vspace(gap), bar, Common.vspace(gap), self.board, Common.vspace(gap),
        strip, Common.vspace(gap), panel, Common.vspace(gap), buttons,
    }
end

function AnalysisScreen:buildButtons(width)
    if self.retro then return self:retroButtons(width) end
    local busy = self.reviewing
    local row = {
        { text = "Menu", callback = function() self:showMenu() end },
        { text = "Explorer", enabled = not busy, callback = function() self:openExplorer() end },
        busy and { text = "Stop", callback = function() self:stopReview() end }
            or { text = self.engine_on and "★ Engine" or "Engine", callback = function() self:toggleEngine() end },
        { text = "‹", enabled = not busy and self.ply > 0, callback = function() self:goTo(self.ply - 1) end },
        { text = "›", enabled = not busy and self.ply < #self.moves, callback = function() self:goTo(self.ply + 1) end },
    }
    return Common.buttonBar({ row }, width, self)
end

-- Navigation -----------------------------------------------------------------

function AnalysisScreen:goTo(ply)
    ply = math.max(0, math.min(ply, #self.moves))
    self.ply = ply
    self.pos = self:positionAt(ply)
    self.lines = nil
    self.message = nil
    self.threat, self.threat_arrow = nil, nil
    self.board:clearSelection()
    if self.engine_on and not self.reviewing and not self.retro then
        self:analyse()
    else
        self:refresh()
    end
end

-- A move on the board: follow the line, or start a variation (the game
-- itself stays the main line).
function AnalysisScreen:onBoardMove(m)
    if self.retro then return self:retroMove(m) end
    local uci = Chess.uci(m)
    if self.moves[self.ply + 1] == uci then return self:goTo(self.ply + 1) end
    if self.ply == #self.moves and not self.var_from and not self.reviewed then
        -- extending the game at its end
        self.mainline[#self.mainline + 1] = uci
        self.moves = self.mainline
    else
        local base = self.var_from and self.moves or self.mainline
        local line = {}
        for i = 1, self.ply do line[i] = base[i] end
        line[#line + 1] = uci
        if not self.var_from then self.var_from = self.ply end
        self.moves = line
    end
    self:goTo(self.ply + 1)
end

function AnalysisScreen:backToMainLine()
    if not self.var_from then return end
    local ply = math.min(self.var_from, #self.mainline)
    self.moves = self.mainline
    self.var_from = nil
    self:goTo(ply)
end

-- Engine ------------------------------------------------------------------------

function AnalysisScreen:toggleEngine()
    self.engine_on = not self.engine_on
    Store.set("analysis_engine", self.engine_on)
    if self.engine_on then
        self:analyse()
    else
        self.engine:cancelAll()
        self.engine_running = false
        self.lines = nil
        self:refresh()
    end
end

function AnalysisScreen:analyse()
    if not self.engine_on or self.pos:gameResult() then
        self.engine_running = false
        self:refresh()
        return
    end
    self.engine_running = true
    self.source = "local"
    local fen = self.pos:fen()
    local seconds = Store.get("analysis_seconds") or 8
    self:refresh()
    self.engine:search({ fen = fen, movetime = seconds * 1000, multipv = 3 }, function(_, lines)
        if self.closed or self.pos:fen() ~= fen then return end
        local list = {}
        for k = 1, 3 do if lines[k] then list[#list + 1] = lines[k] end end
        self.lines = list
        -- e-ink: repaint at most every two seconds while the engine thinks
        if not self.repaint_pending then
            self.repaint_pending = true
            UIManager:scheduleIn(2, function()
                self.repaint_pending = false
                if not self.closed then self:refresh() end
            end)
        end
    end, function(res, err)
        if self.closed then return end
        self.engine_running = false
        if res and res.lines and #res.lines > 0 and self.pos:fen() == fen then
            self.lines = res.lines
        elseif err then
            self.message = "The engine could not run: " .. tostring(err)
        end
        self:refresh()
    end)
end

-- What the opponent would do if it were their move again (lichess "show threat").
function AnalysisScreen:showThreat()
    if self.pos:inCheck() then
        Common.info("No threat to show while in check.", 2)
        return
    end
    local g = self.pos:clone()
    g.turn = Chess.opposite(g.turn)
    g.ep = nil
    local fen = g:fen()
    self.engine:cancelAll()
    self.engine_running = false
    self.threat = "Looking for the threat…"
    self:refresh()
    self.engine:search({ fen = fen, depth = 12, movetime = 3000, multipv = 1 }, nil, function(res)
        if self.closed then return end
        local l = res and res.lines and res.lines[1]
        local m = l and l.pv and g:moveFromUci(l.pv[1])
        if m then
            local why = Describe.joinReasons(Describe.reasons(g, m), 2)
            self.threat = "Threat: " .. lower(Describe.move(g, m)) .. (why and (", which " .. why) or "") .. "."
            self.threat_arrow = { from = m.from, to = m.to, color = "red" }
        else
            self.threat = "No threat found."
        end
        self:refresh()
    end)
end

-- Lichess ------------------------------------------------------------------------

function AnalysisScreen:cloudEval()
    self.engine:cancelAll()
    self.engine_running = false
    local fen = self.pos:fen()
    Common.whenOnline(function()
        local client = self.plugin:lichess()
        local ok, data = Common.busy("Asking Lichess…", function() return client:cloudEval(fen, 3) end)
        if self.closed then return end
        local lines = ok and Lichess.cloudLines(data, self.pos.turn)
        if lines then
            self.lines = lines
            self.source = "cloud"
            self.message = nil
        else
            self.message = "Lichess has no cloud evaluation for this position (only common positions are stored)."
        end
        self:refresh()
    end)
end

function AnalysisScreen:currentPgn()
    local g = Chess.new(self.start_fen)
    for _, u in ipairs(self.mainline) do g:move(u) end
    return g:pgn({ Event = "KOReader analysis" })
end

function AnalysisScreen:openOnLichess()
    Common.whenOnline(function()
        local client = self.plugin:lichess()
        local ok, data = Common.busy("Uploading the game to Lichess…", function()
            return client:importGame(self:currentPgn())
        end)
        local url
        if ok and type(data) == "table" and data.url then
            url = data.url
        else
            url = Lichess.analysisUrl(self.pos:fen())
        end
        local QRMessage = require("ui/widget/qrmessage")
        UIManager:show(QRMessage:new{ text = url })
        Common.info((ok and "Game uploaded. " or "") .. "Scan the code to open it on Lichess. "
            .. "There you can request a full computer analysis.\n\n" .. url)
    end)
end

-- Computer analysis (review) --------------------------------------------------------

-- Computer analysis: Lichess' own server analysis when logged in and online
-- (like "Request a computer analysis"), else Stockfish on this device.
function AnalysisScreen:startReview(then_fn)
    self.review_note = nil
    local NetworkMgr = require("ui/network/manager")
    if Store.get("review_source") == "lichess" and NetworkMgr:isOnline() and #self.mainline > 0 then
        -- a game from Lichess may already have its analysis there
        if Store.webSession() or self.lichess_game_id then return self:startLichessReview(then_fn) end
        self.review_note = "Tip: connect your phone (Lichess account → Connect phone) and Lichess will "
            .. "analyse your games on its servers, much faster than this device."
    end
    return self:startLocalReview(then_fn)
end

-- Waiting for Lichess, as the mod app does it (LichessServerReview.java): ask
-- every 2.5 s, give up after 5 minutes, and show progress as the time waited
-- out of the usual 45 s (at most 95 % until the analysis is there), stepping
-- the board through the game with it like chess.com's review screen.
local LICHESS_POLL_SECONDS = 2.5
local LICHESS_POLL_TRIES = 120
local LICHESS_USUAL_SECONDS = 45

function AnalysisScreen:startLichessReview(then_fn)
    self:backToMainLine()
    self.engine:cancelAll()
    self.engine_running = false
    self.reviewing = true
    self.reviewed, self.evals, self.summary = nil, nil, nil
    self.lines = nil
    self.review_note = nil
    self.message = "Uploading the game to Lichess…"
    self:refresh()
    local function fallback(reason)
        if self.closed or not self.reviewing then return end
        self.reviewing = false
        self.review_note = "Lichess could not analyse this game: " .. reason
            .. " The review is made by Stockfish on this device instead (slower). Details: Menu → Lichess log."
        self:startLocalReview(then_fn)
    end
    local function hasAnalysis(data)
        return type(data) == "table" and type(data.analysis) == "table" and #data.analysis >= #self.mainline
    end
    UIManager:nextTick(function()
        if self.closed or not self.reviewing then return end
        local client = self.plugin:lichess()
        local okc, err = pcall(function()
            local id = self.lichess_game_id
            if not id then
                local ok, data = client:importGame(self:currentPgn())
                if not ok or type(data) ~= "table" or not data.id then
                    return fallback("uploading the game failed with " .. tostring(data) .. ".")
                end
                id = data.id
                self.lichess_game_id = id
            end
            self.message = "Game uploaded to Lichess (lichess.org/" .. id .. "). Asking for the analysis…"
            self:refresh("ui")
            local ok, data = client:exportGame(id)
            if ok and hasAnalysis(data) then return self:lichessReviewDone(data, then_fn) end
            local ok2, err2 = client:requestAnalysis(id, Store.webSession())
            if not ok2 then
                return fallback("the analysis request was refused with " .. tostring(err2) .. ".")
            end
            local tries = 0
            local function poll()
                if self.closed or not self.reviewing then return end
                tries = tries + 1
                local okp, d = client:exportGame(id)
                if okp and hasAnalysis(d) then return self:lichessReviewDone(d, then_fn) end
                if tries >= LICHESS_POLL_TRIES then
                    return fallback("no analysis arrived after " .. tries * LICHESS_POLL_SECONDS .. " seconds.")
                end
                local done = okp and type(d) == "table" and type(d.analysis) == "table" and #d.analysis or 0
                local n = #self.mainline
                local fraction = math.min(0.95, tries * LICHESS_POLL_SECONDS / LICHESS_USUAL_SECONDS)
                if done > 0 and done / n > fraction then fraction = done / n end -- a real partial analysis
                self:showReviewPosition(math.floor(fraction * n + 0.5))
                self.message = "Lichess is analysing the game… " .. math.floor(fraction * 100 + 0.5) .. "%"
                self:refresh("ui")
                UIManager:scheduleIn(LICHESS_POLL_SECONDS, poll)
            end
            self.message = "Lichess is analysing the game. This usually takes less than a minute…"
            self:refresh()
            UIManager:scheduleIn(LICHESS_POLL_SECONDS, poll)
        end)
        if not okc then fallback("an error happened: " .. tostring(err) .. ".") end
    end)
end

-- Turns Lichess' analysis (one eval per move, from White's side; the best move
-- and a judgment for inaccurate moves) into the same data a local review has.
function AnalysisScreen:lichessReviewDone(data, then_fn)
    local positions = {}
    for i = 0, #self.mainline do positions[i] = self:positionAt(i) end
    local evals = {}
    local judgments = {}
    local function line(entry, pos)
        local sign = pos.turn == "w" and 1 or -1
        local l = { lichess = true, depth = nil, pv = {} }
        if entry and entry.mate then l.mate = entry.mate * sign
        else l.cp = ((entry and entry.eval) or 20) * sign end
        return l
    end
    evals[0] = { lines = { line(nil, positions[0]) } }
    for i = 1, #self.mainline do
        local a = data.analysis[i] or {}
        evals[i] = { lines = { line(a, positions[i]) } }
        -- the best move of the position before this move, when Lichess gives it,
        -- and its whole line (SAN) when Lichess sends that too
        if a.best then evals[i - 1].lines[1].pv = { a.best } end
        if a.variation and a.variation ~= "" then
            local g = positions[i - 1]:clone()
            local pv = {}
            for san in a.variation:gmatch("%S+") do
                local m = g:moveFromSan(san)
                if not m then break end
                pv[#pv + 1] = Chess.uci(m)
                g:makeMove(m)
            end
            if #pv > 0 then evals[i - 1].lines[1].pv = pv end
        end
        if a.judgment and a.judgment.name then judgments[i] = a.judgment.name:lower() end
    end
    local players = data.players or {}
    local summary = {}
    for side, key in pairs({ w = "white", b = "black" }) do
        local pa = players[key] and players[key].analysis
        if pa then summary[side] = pa end
    end
    self.review_note = "Analysis by Lichess."
    self:finishReview(positions, evals, 0, { judgments = judgments, summary = summary })
    -- Lichess does not send the line that punishes a mistake: it is worked out
    -- on this device when "see why" is tapped (AnalysisScreen:showWhy)
    for ply, j in pairs(self.reviewed or {}) do
        if Coach.PROBLEMS[j.class] and j.class ~= "miss" then j.needs_why = true end
    end
    if then_fn then then_fn() end
end

function AnalysisScreen:startLocalReview(then_fn)
    self:backToMainLine()
    if #self.mainline == 0 then
        self.message = "There are no moves to analyse."
        self:refresh()
        return
    end
    self.engine:cancelAll()
    self.engine_running = false
    self.reviewing = true
    self.reviewed = nil
    self.summary = nil
    self.lines = nil
    local evals = {}
    local positions = {}
    for i = 0, #self.mainline do positions[i] = self:positionAt(i) end
    local n = #self.mainline
    local NetworkMgr = require("ui/network/manager")
    local use_cloud = Store.get("review_cloud") and NetworkMgr:isOnline()
    local cloud_count = 0
    local function step(i)
        if self.closed or not self.reviewing then return end
        if i > n then
            self:finishReview(positions, evals, cloud_count)
            if then_fn then then_fn() end
            return
        end
        -- say which engine works, and why it is not Lichess when that failed
        self.message = (self.review_note and (self.review_note .. "\n\n") or "")
            .. "Analysing on this device: move " .. math.max(1, i) .. " of " .. n .. "…"
        -- show the position being analysed, like the progress of a lichess review
        self:showReviewPosition(i)
        self:refresh("ui")
        if positions[i]:gameResult() then
            evals[i] = { lines = {} }
            return step(i + 1)
        end
        -- deep evaluations from the Lichess cloud while it knows the positions
        if use_cloud then
            local lines = self:cloudReviewLines(positions[i])
            if lines then
                evals[i] = { lines = lines }
                cloud_count = cloud_count + 1
                return UIManager:nextTick(function() step(i + 1) end)
            end
            use_cloud = false -- the game left the well-known positions: local engine from here
            local prev = evals[i - 1]
            if prev and prev.lines and prev.lines[1] and prev.lines[1].cloud then
                -- judge the move into this position with two local scores, not one of each
                cloud_count = cloud_count - 1
                return self.engine:search({ fen = positions[i - 1]:fen(), depth = Store.get("review_depth"),
                    movetime = REVIEW_MOVETIME_CAP, multipv = 2 }, nil, function(res)
                    evals[i - 1] = res or { lines = {} }
                    step(i)
                end)
            end
        end
        self.engine:search({ fen = positions[i]:fen(), depth = Store.get("review_depth"), movetime = REVIEW_MOVETIME_CAP,
            multipv = 2 }, nil, function(res)
            evals[i] = res or { lines = {} }
            step(i + 1)
        end)
    end
    self:refresh()
    step(0)
end

-- During a review: the board shows the position being analysed.
function AnalysisScreen:showReviewPosition(ply)
    self.ply = math.max(0, math.min(ply, #self.mainline))
    self.pos = self:positionAt(self.ply)
end

function AnalysisScreen:cloudReviewLines(pos)
    local ok, data = pcall(function() return select(2, self.plugin:lichess():cloudEval(pos:fen(), 2)) end)
    if not ok then return nil end
    return Lichess.cloudLines(data, pos.turn)
end

function AnalysisScreen:stopReview()
    self.reviewing = false
    self.engine:cancelAll()
    self.reviewed = nil
    self.message = "Computer analysis stopped."
    self:refresh()
end

function AnalysisScreen:finishReview(positions, evals, cloud_count, lichess)
    self.reviewing = false
    self.reviewed = {}
    self.evals = evals
    local acc = { w = {}, b = {} }
    local counts = { w = {}, b = {} }
    local loss = { w = 0, b = 0 }
    local nmoves = { w = 0, b = 0 }
    local level = Store.get("coach_level")
    local prev_class
    for ply = 1, #self.mainline do
        local before_game = positions[ply - 1]
        local m = before_game:moveFromUci(self.mainline[ply])
        if m then
            local j = Coach.classify(before_game, m, evals[ply - 1], evals[ply], {
                opponent_prev_class = prev_class,
                is_book = ply <= BOOK_MAX_PLY and Openings.isBook(positions[ply]),
            })
            if lichess then
                -- Lichess' verdict decides the label; the coach still explains the move
                local verdict = lichess.judgments[ply]
                if verdict then
                    j.class = verdict
                elseif Coach.PROBLEMS[j.class] then
                    j.class = "good"
                end
            end
            j.text, j.visual = Coach.explain(before_game, m, evals[ply - 1], evals[ply], j, level)
            self.reviewed[ply] = j
            prev_class = j.class
            local side = before_game.turn
            if j.accuracy then acc[side][#acc[side] + 1] = j.accuracy end
            counts[side][j.class] = (counts[side][j.class] or 0) + 1
            nmoves[side] = nmoves[side] + 1
            if j.cp_loss and not Engine.isMateScore(j.cp_loss) then
                loss[side] = loss[side] + math.min(j.cp_loss, 1000)
            end
        end
    end
    local function pct(side) local a = Coach.gameAccuracy(acc[side]); return a and (math.floor(a + 0.5) .. "%") or "-" end
    local function c(side, k) return counts[side][k] or 0 end
    local function acpl(side) return nmoves[side] > 0 and math.floor(loss[side] / nmoves[side] + 0.5) or "-" end
    local ls = lichess and lichess.summary
    if ls and ls.w and ls.b then
        -- Lichess' own numbers
        pct = function(side) return ls[side].accuracy and (ls[side].accuracy .. "%") or "-" end
        c = function(side, k) return ls[side][k] or 0 end
        acpl = function(side) return ls[side].acpl or "-" end
    end
    -- the lichess summary table, as text
    self.summary = table.concat({
        "Computer analysis          White · Black",
        "Accuracy:  " .. pct("w") .. " · " .. pct("b"),
        "?! Inaccuracies:  " .. c("w", "inaccuracy") .. " · " .. c("b", "inaccuracy"),
        "? Mistakes:  " .. c("w", "mistake") .. " · " .. c("b", "mistake"),
        "?? Blunders:  " .. c("w", "blunder") .. " · " .. c("b", "blunder"),
        "Average centipawn loss:  " .. acpl("w") .. " · " .. acpl("b"),
    }, "\n") .. ((cloud_count or 0) > 0 and ("\n(" .. cloud_count .. " positions from the Lichess cloud)") or "")
        .. (self.review_note and ("\n" .. self.review_note) or "")
        .. "\nMenu → Learn from your mistakes, or step through with ‹ ›."
    self.message = nil
    self.ply = 0
    self.pos = self:positionAt(0)
    self.lines = nil
    -- a full (flashing) refresh clears the ghosting the many board updates leave on e-ink
    self:refresh("full")
    self:positionalPass(positions, evals)
end

-- Mistakes no tactic explains get the reason from Stockfish's evaluation
-- (what got worse: king safety, passed pawns, ...), one after the other.
function AnalysisScreen:positionalPass(positions, evals)
    local todo = {}
    for ply = 1, #self.mainline do
        local j = self.reviewed and self.reviewed[ply]
        local after = evals[ply] and evals[ply].lines and evals[ply].lines[1]
        if j and Coach.PROBLEMS[j.class] and j.class ~= "miss" and not (j.visual and j.visual[1]
            and j.visual[1].title == "What goes wrong") and after and after.pv and after.pv[1] then
            todo[#todo + 1] = ply
        end
    end
    local reviewed = self.reviewed
    local i = 0
    local function nextOne()
        i = i + 1
        local ply = todo[i]
        if not ply or self.closed or self.reviewed ~= reviewed then return end
        local before_game = positions[ply - 1]
        local m = before_game:moveFromUci(self.mainline[ply])
        local reply = evals[ply].lines[1].pv[1]
        local g2 = positions[ply]:clone()
        local rm = g2:moveFromUci(reply)
        if not m or not rm then return nextOne() end
        g2:makeMove(rm)
        self.engine:evalTerms(before_game:fen(), function(tb)
            self.engine:evalTerms(g2:fen(), function(ta)
                if self.closed or self.reviewed ~= reviewed then return end
                local j = reviewed[ply]
                local text, part = Coach.addPositional(j.text, before_game, m, reply, tb, ta)
                if text then
                    j.text = text
                    -- the positional view first, the better move after it
                    local parts = { part }
                    for _, p in ipairs(j.visual or {}) do parts[#parts + 1] = p end
                    j.visual = parts
                    if self.ply == ply then self:refresh() end
                end
                nextOne()
            end)
        end)
    end
    nextOne()
end

-- "See why" for the move at `ply`. After a Lichess review the line that
-- punishes the mistake is not known yet: Stockfish works it out now, for this
-- one move, then names the tactic (or the positional reason) like a local review.
function AnalysisScreen:showWhy(ply)
    local j = self.reviewed and self.reviewed[ply]
    if not j then return end
    local function open()
        if not j.visual then return end
        UIManager:show(require("chessuite/ui/explainpage"):new{ plugin = self.plugin, parts = j.visual,
            flipped = self.flipped, on_close = function()
                if not self.closed and self.engine_on and not self.reviewing then self:analyse() end
            end })
    end
    if not j.needs_why then return open() end
    local before_game = self:positionAt(ply - 1)
    local m = before_game:moveFromUci(self.mainline[ply])
    if not m then return end
    local after_game = self:positionAt(ply)
    self.engine:cancelAll()
    self.engine_running = false
    self.message = "Looking at this move with Stockfish…"
    self:refresh("ui")
    self.engine:search({ fen = after_game:fen(), depth = 14, movetime = 6000, multipv = 1 }, nil, function(res)
        if self.closed then return end
        local line = res and res.lines and res.lines[1]
        local pv = line and line.pv
        local function done()
            j.needs_why = nil
            self.message = nil
            self:refresh()
            open()
        end
        local Explain = require("chessuite/explain")
        local e = pv and #pv > 0 and Explain.punishment(before_game, m, pv,
            { cost = Coach.costWords(j.cp_loss) })
        if e and (e.key or e.mate or (e.won or 0) >= 1) then
            j.text = j.text:gsub("^(.- is [^%.:]-)%.", "%1: " .. e.headline .. ".", 1)
            local parts = { { title = "What goes wrong", headline = e.headline:gsub("^%l", string.upper) .. ".",
                text = e.text, steps = e.steps, start = before_game } }
            for _, p in ipairs(j.visual or {}) do parts[#parts + 1] = p end
            j.visual = parts
            return done()
        end
        if not (pv and pv[1]) then return done() end
        -- no tactic: what Stockfish's evaluation says the move gave away
        local g2 = after_game:clone()
        g2:move(pv[1])
        self.engine:evalTerms(before_game:fen(), function(tb)
            self.engine:evalTerms(g2:fen(), function(ta)
                if self.closed then return end
                local text, part = Coach.addPositional(j.text, before_game, m, pv[1], tb, ta)
                if text then
                    j.text = text
                    local parts = { part }
                    for _, p in ipairs(j.visual or {}) do parts[#parts + 1] = p end
                    j.visual = parts
                end
                done()
            end)
        end)
    end)
end

function AnalysisScreen:nextMistake()
    if not self.reviewed then return end
    local start_turn = Chess.new(self.start_fen).turn
    for ply = self.ply + 1, #self.mainline do
        local j = self.reviewed[ply]
        local mover = ((ply % 2 == 1) == (start_turn == "w")) and "w" or "b"
        if j and Coach.PROBLEMS[j.class] and (not self.player_color or self.player_color == mover) then
            self:backToMainLine()
            return self:goTo(ply)
        end
    end
    self.message = "No more mistakes after this move."
    self:refresh()
end

-- Learn from your mistakes --------------------------------------------------------

function AnalysisScreen:startRetro(side)
    if not self.reviewed then
        -- needs the computer analysis first
        return self:startReview(function() self:startRetro(side) end)
    end
    self:backToMainLine()
    self.engine:cancelAll()
    self.engine_running = false
    local start_turn = Chess.new(self.start_fen).turn
    local list = {}
    for ply = 1, #self.mainline do
        local mover = ((ply % 2 == 1) == (start_turn == "w")) and "w" or "b"
        local j = self.reviewed[ply]
        local best = self.evals and self.evals[ply - 1] and self.evals[ply - 1].lines and self.evals[ply - 1].lines[1]
        if mover == side and j and RETRO_CLASSES[j.class] and best and best.pv and best.pv[1] then
            list[#list + 1] = ply
        end
    end
    local name = side == "w" and "white" or "black"
    self.retro = { side = side, list = list, index = 0, name = name }
    self.flipped = side == "b"
    if #list == 0 then
        self.retro.state = "done"
        self.retro.title = "No mistakes found for " .. name .. "."
        self:refresh()
        return
    end
    self:retroNext()
end

function AnalysisScreen:retroNext()
    local r = self.retro
    r.index = r.index + 1
    r.arrows = nil
    local ply = r.list[r.index]
    if not ply then
        r.state = "done"
        r.title = "Done reviewing " .. r.name .. " mistakes."
        r.text = nil
        self:refresh()
        return
    end
    r.ply = ply
    self.ply = ply - 1
    self.pos = self:positionAt(ply - 1)
    local played = self.pos:moveFromUci(self.mainline[ply])
    r.state = "find"
    r.title = (played and Describe.move(self.pos, played) or "?") .. " was played. Find a better move for "
        .. r.name .. "."
    r.text = "Mistake " .. r.index .. " of " .. #r.list .. "."
    self:refresh()
end

function AnalysisScreen:retroBest()
    local e = self.evals[self.retro.ply - 1]
    return e.lines[1]
end

function AnalysisScreen:retroMove(m)
    local r = self.retro
    if r.state ~= "find" then return end
    local uci = Chess.uci(m)
    local best = self:retroBest()
    local before = self.pos:clone()
    self.pos:move(uci)
    local bm = before:moveFromUci(best.pv[1])
    if bm and Chess.uci(bm) == uci then return self:retroCorrect(before, m) end
    local second = self.evals[r.ply - 1].lines[2]
    local sm = second and second.pv and before:moveFromUci(second.pv[1])
    if sm and Chess.uci(sm) == uci and Engine.winPercent(Engine.lineCp(best))
        - Engine.winPercent(Engine.lineCp(second)) < RETRO_TOLERANCE then
        return self:retroCorrect(before, m)
    end
    if uci == self.mainline[r.ply] then return self:retroIncorrect(before) end
    -- another move: is it (nearly) as good as the best one?
    r.state = "eval"
    r.title = "Evaluating your move…"
    r.text = nil
    self:refresh()
    self.engine:search({ fen = self.pos:fen(), depth = Store.get("review_depth"), movetime = REVIEW_MOVETIME_CAP,
        multipv = 1 }, nil, function(res)
        if self.closed or self.retro ~= r then return end
        local reply = res and res.lines and res.lines[1]
        if not reply then return self:retroIncorrect(before) end
        local mine = 100 - Engine.winPercent(Engine.lineCp(reply))
        local wanted = Engine.winPercent(Engine.lineCp(best))
        if mine - wanted > -RETRO_TOLERANCE then
            self:retroCorrect(before, m)
        else
            self:retroIncorrect(before)
        end
    end)
end

function AnalysisScreen:retroCorrect(before, m)
    local r = self.retro
    r.state = "correct"
    r.title = "Good move!"
    local best = self:retroBest()
    local bm = before:moveFromUci(best.pv[1])
    if bm and Chess.uci(bm) ~= Chess.uci(m) then
        r.text = "Best was " .. lower(Describe.move(before, bm)) .. "."
    else
        local why = Describe.joinReasons(Describe.reasons(before, m), 2)
        r.text = why and ("It " .. why .. ".") or nil
    end
    self:refresh()
end

function AnalysisScreen:retroIncorrect(before)
    local r = self.retro
    r.state = "wrong"
    r.title = "You can do better."
    r.text = "Try another move for " .. r.name .. "."
    self:refresh()
    UIManager:scheduleIn(0.5, function()
        if self.closed or self.retro ~= r or r.state ~= "wrong" then return end
        self.pos = before
        r.state = "find"
        self:refresh()
    end)
end

function AnalysisScreen:retroSolution()
    local r = self.retro
    self.pos = self:positionAt(r.ply - 1)
    local best = self:retroBest()
    local bm = self.pos:moveFromUci(best.pv[1])
    r.state = "solution"
    r.title = "Solution"
    if bm then
        r.text = "Best was " .. lower(Describe.move(self.pos, bm)) .. "."
        local why = Describe.joinReasons(Describe.reasons(self.pos, bm), 2)
        if why then r.text = r.text .. " It " .. why .. "." end
        r.arrows = { { from = bm.from, to = bm.to, color = "green" } }
    end
    self:refresh()
end

function AnalysisScreen:retroButtons(width)
    local r = self.retro
    local row
    if r.state == "done" then
        row = { { text = "Close mistakes review", callback = function() self:exitRetro() end } }
    elseif r.state == "correct" or r.state == "solution" then
        row = {
            { text = "Do it again", enabled = r.state == "solution", callback = function()
                r.index = r.index - 1; self:retroNext() end },
            { text = "Next mistake", callback = function() self:retroNext() end },
            { text = "Stop", callback = function() self:exitRetro() end },
        }
    else
        row = {
            { text = "View the solution", enabled = r.state ~= "eval", callback = function() self:retroSolution() end },
            { text = "Skip this move", enabled = r.state ~= "eval", callback = function() self:retroNext() end },
            { text = "Stop", callback = function() self:exitRetro() end },
        }
    end
    return Common.buttonBar({ row }, width, self)
end

function AnalysisScreen:exitRetro()
    self.engine:cancelAll()
    local ply = self.retro and self.retro.ply or self.ply
    self.retro = nil
    self:goTo(ply or 0)
end

-- Menu ------------------------------------------------------------------------

function AnalysisScreen:showMenu()
    local dialog
    local rows = {}
    local function add(text, fn, enabled)
        rows[#rows + 1] = { { text = text, enabled = enabled ~= false,
            callback = function() UIManager:close(dialog); fn() end } }
    end
    if self.reviewing then
        add("Stop computer analysis", function() self:stopReview() end)
    else
        add(self.reviewed and "Computer analysis again" or "Request computer analysis", function() self:startReview() end,
            #self.mainline > 0)
    end
    rows[#rows + 1] = {
        { text = "Learn from mistakes: White", enabled = #self.mainline > 0 and not self.reviewing,
          callback = function() UIManager:close(dialog); self:startRetro("w") end },
        { text = "Black", enabled = #self.mainline > 0 and not self.reviewing,
          callback = function() UIManager:close(dialog); self:startRetro("b") end },
    }
    if self.reviewed then add("Next mistake", function() self:nextMistake() end) end
    add("Flip board", function() self.flipped = not self.flipped; self:refresh() end)
    add("Show threat", function() self:showThreat() end, not self.reviewing)
    add("Lichess cloud evaluation", function() self:cloudEval() end, not self.reviewing)
    add("Continue from here (play Stockfish)", function() self:continueFromHere() end, not self.pos:gameResult())
    if self.var_from then add("Back to main line", function() self:backToMainLine() end) end
    rows[#rows + 1] = {
        { text = "« First move", callback = function() UIManager:close(dialog); self:goTo(0) end },
        { text = "Last move »", callback = function() UIManager:close(dialog); self:goTo(#self.moves) end },
    }
    add("Move list", function() self:openMoveList() end)
    add("Open on Lichess (QR code)", function() self:openOnLichess() end)
    add("Lichess log (requests and errors)", function()
        UIManager:show(require("chessuite/ui/logpage"):new{})
    end)
    rows[#rows + 1] = {
        { text = "My games", callback = function() UIManager:close(dialog); self:loadRecent() end },
        { text = "PGN file", callback = function() UIManager:close(dialog); self:loadPgnFile() end },
        { text = "FEN", callback = function() UIManager:close(dialog); self:enterFen() end },
        { text = "Empty board", callback = function() UIManager:close(dialog); self:loadGame(Chess.new()) end },
    }
    dialog = ButtonDialog:new{ title = "Analysis", buttons = rows }
    UIManager:show(dialog)
end

-- The Lichess opening explorer for the position on the board; a move picked
-- there is played here, like in the Lichess app's explorer.
function AnalysisScreen:openExplorer()
    local ExplorerPage = require("chessuite/ui/explorerpage")
    UIManager:show(ExplorerPage:new{
        plugin = self.plugin,
        game = self.pos:clone(),
        on_move = function(uci)
            local m = self.pos:moveFromUci(uci)
            if m then self:onBoardMove(m) end
            return self.pos:clone()
        end,
        on_back = function()
            if self.ply > 0 then self:goTo(self.ply - 1) end
            return self.pos:clone()
        end,
    })
end

function AnalysisScreen:openMoveList()
    local MoveListPage = require("chessuite/ui/movelistpage")
    local g = Chess.new(self.start_fen)
    for _, u in ipairs(self.moves) do g:move(u) end
    local judgements = {}
    for ply = 1, #self.moves do judgements[ply] = self:judgementAt(ply) end
    UIManager:show(MoveListPage:new{
        game = g,
        judgements = judgements,
        current = self.ply,
        title = self.var_from and "Moves (variation)" or "Moves",
        on_pick = function(ply) self:goTo(ply) end,
    })
end

function AnalysisScreen:continueFromHere()
    local Bots = require("chessuite/bots")
    local GameScreen = require("chessuite/ui/gamescreen")
    self.engine:cancelAll()
    local bot = Bots.stockfishAt(Store.get("stockfish_elo") or Store.playerRating())
    UIManager:show(GameScreen:new{
        plugin = self.plugin,
        bot = bot,
        player_color = self.pos.turn,
        resume = { start_fen = self.pos:fen(), moves = {}, color = self.pos.turn },
    })
end

function AnalysisScreen:askPromotion(cb)
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

-- Loading ---------------------------------------------------------------------

function AnalysisScreen:loadGame(g, review, lichess_id)
    self.engine:cancelAll()
    self.retro = nil
    self.lichess_game_id = lichess_id -- another game: not the one uploaded before
    self.start_fen = g.start_fen
    self.mainline = g:uciHistory()
    self.moves = self.mainline
    self.var_from = nil
    self.reviewed, self.evals, self.summary = nil, nil, nil
    self.lines = nil
    self.message = nil
    self.ply = review and 0 or #self.moves
    self.pos = self:positionAt(self.ply)
    if review then self:startReview() else self:goTo(self.ply) end
end

function AnalysisScreen:loadRecent()
    local GamesPage = require("chessuite/ui/gamespage")
    UIManager:show(GamesPage:new{ plugin = self.plugin,
        on_pick = function(entry)
            local g = Chess.fromPgn(entry.pgn)
            if g then
                self.player_color = entry.color
                self.flipped = entry.color == "b"
                self:loadGame(g, true, entry.lichess_id)
            end
        end,
    })
end

function AnalysisScreen:loadPgnFile()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false,
        path = Store.gamesDir(),
        file_filter = function(f) return f:lower():match("%.pgn$") ~= nil end,
        onConfirm = function(path)
            local f = io.open(path, "r")
            if not f then return end
            local text = f:read("*a")
            f:close()
            -- the first game of the file
            local first = text:match("^(.-\n%s*\n.-)\n%s*\n%[") or text
            local g, err = Chess.fromPgn(first)
            if not g then
                Common.info("Could not read this PGN: " .. tostring(err))
                return
            end
            self:loadGame(g)
        end,
    })
end

function AnalysisScreen:enterFen()
    local dialog
    dialog = InputDialog:new{
        title = "Position in FEN notation",
        input = self.pos:fen(),
        buttons = {
            {
                { text = "Cancel", id = "close", callback = function() UIManager:close(dialog) end },
                { text = "Load", is_enter_default = true, callback = function()
                    local g, err = Chess.new(dialog:getInputText())
                    if not g then
                        Common.info("Not a valid position: " .. tostring(err))
                        return
                    end
                    UIManager:close(dialog)
                    self:loadGame(g)
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AnalysisScreen:onClose()
    self.closed = true
    self.engine:cancelAll()
    if self.board then self.board:free() end
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

return AnalysisScreen
