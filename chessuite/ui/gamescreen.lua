--[[
Full-screen game against a bot or a Stockfish level, with the coach
commenting on your moves in plain words. Also used for games with a friend
on the same device (bot.human), games from a position (start_moves) and
games with a chess clock.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Bots = require("chessuite/bots")
local Chess = require("chessuite/chess")
local Coach = require("chessuite/coach")
local Common = require("chessuite/ui/common")
local Describe = require("chessuite/describe")
local Engine = require("chessuite/uci")
local Openings = require("chessuite/openings")
local Store = require("chessuite/store")
local BoardWidget = require("chessuite/ui/boardwidget")

-- A fixed depth keeps the scores comparable from move to move; the time is
-- only a safety cap for very slow devices.
local COACH_SEARCH = { depth = 12, movetime = 4000, multipv = 2 }
local BOOK_MAX_PLY = 24

local function now()
    local ok, socket = pcall(require, "socket")
    if ok and socket.gettime then return socket.gettime() end
    return os.time()
end

local function clockText(secs)
    secs = math.max(0, secs)
    if secs < 20 then return string.format("%.1f", math.floor(secs * 10) / 10) end
    secs = math.floor(secs)
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

local GameScreen = Common.Page:extend{
    plugin = nil,
    bot = nil,
    player_color = "w",
    resume = nil, -- saved game table to continue
    start_moves = nil, -- moves from the start position already played (opening trainer)
}

function GameScreen:init()
    self.engine = self.plugin:getEngine()
    if self.bot.is_coach then self.bot = Bots.coachFor(Store.playerRating()) end
    self.friend = self.bot.human
    self.game = Chess.new(self.resume and self.resume.start_fen or Chess.START_FEN)
    self.judgements = {}
    for _, u in ipairs(self.start_moves or {}) do self.game:move(u) end
    if self.resume then
        for _, u in ipairs(self.resume.moves or {}) do self.game:move(u) end
        self.player_color = self.resume.color or self.player_color
    end
    if self.friend then self.player_color = self.game.turn end
    self.flipped = self.player_color == "b"
    if self.friend and not Store.get("friend_flip") then self.flipped = false end
    self.coach_on = Store.get("coach_comments") and not self.friend
    -- the clock: from the saved game, or the time control chosen before the game
    local saved_clock = self.resume and self.resume.clock
    local tc = saved_clock and Store.timeControl(saved_clock.id) or (not self.resume and Store.timeControl())
    if tc then
        self.tc = tc
        self.clocks = { w = saved_clock and saved_clock.w or tc.base, b = saved_clock and saved_clock.b or tc.base }
    end
    self.title = self.bot.name .. (self.bot.elo and (" · " .. self.bot.elo) or "")
    if self.friend then self.title = "Play a friend" end
    if self.tc then self.title = self.title .. " · " .. self.tc.name end
    self.left_icon = "appbar.menu"
    self.left_icon_tap_callback = function() self:showMenu() end
    self.bot_says = self.resume and "Let's continue." or (self.bot.greeting or "Good luck!")
    if self.bot.no_personality then self.bot_says = nil end
    self.coach_says = nil
    self.status = ""
    self.hint_level = 0
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = function()
            return self.board and self.board.dimen or Geom:new{ w = 0, h = 0 }
        end } },
    }
    Common.Page.init(self)
    UIManager:nextTick(function() self:startTurn() end)
end

-- Layout ---------------------------------------------------------------------

function GameScreen:buildContent(width, height)
    local landscape = width > height
    local gap = Size.padding.default
    local side_w = landscape and math.floor(width * 0.42) or width
    local buttons = self:buildButtons(side_w)
    local bh = buttons:getSize().h
    local viewing = self.view_ply ~= nil
    local shown = viewing and self:positionAt(self.view_ply) or self.game

    -- the moves played so far, ending at the move shown (like the lichess move strip)
    local strip = Common.paragraph(self:moveStripText(), side_w, 16, { height = Common.scale(24) })
    -- opponent: name, rating, "thinking", material; with a personality also the speech bubble
    local material = shown:materialBalance()
    local function materialText(color)
        local m = color == "w" and material or -material
        return m > 0 and ("  +" .. m) or ""
    end
    local bot_color = self.player_color == "w" and "b" or "w"
    local name = self.bot.name .. (self.bot.elo and (" · " .. self.bot.elo) or "")
        .. (self.thinking and "   thinking…" or "") .. materialText(bot_color) .. self:clockLabel(bot_color)
    local you_text = "You · " .. Store.playerRating() .. materialText(self.player_color)
        .. self:clockLabel(self.player_color)
    if self.friend then
        -- the colour at the top of the board above it, the other one below
        local top = self.flipped and "w" or "b"
        local bottom = top == "w" and "b" or "w"
        local function side(c)
            return (c == "w" and "White" or "Black") .. materialText(c) .. self:clockLabel(c)
                .. (shown.turn == c and not self.finished and "  ← to move" or "")
        end
        name, you_text = side(top), side(bottom)
    end
    local opponent
    if self.bot.no_personality or self.friend then
        opponent = Common.paragraph(name, side_w, 19, { bold = true })
    else
        local asize = Common.scale(48)
        local text_w = side_w - asize - Common.scale(16)
        opponent = HorizontalGroup:new{
            align = "center",
            Common.Avatar:new{ letter = self.bot.name:sub(1, 1), piece = Bots.pieceFor(self.bot),
                icon = self.bot.is_coach and "coach" or nil, size = asize, inverted = true },
            Common.hspace(),
            VerticalGroup:new{
                align = "left",
                Common.paragraph(name, text_w, 18, { bold = true }),
                Common.paragraph(self.bot_says or "", text_w, 16, { height = Common.scale(22) }),
            },
        }
    end
    local you = Common.paragraph(you_text .. "   " .. (viewing and self:viewText() or self.status or ""),
        side_w, 18, { bold = true })

    -- room for the coach's words (more of them since it names the tactics)
    local coach_min = Common.scale(self.coach_on and 150 or 110)
    local used = strip:getSize().h + opponent:getSize().h + you:getSize().h + bh + 6 * gap
    local board_size = landscape and height or math.min(width, height - used - coach_min)
    board_size = board_size - board_size % 8
    if not self.board or self.board.size ~= board_size then
        if self.board then self.board:free() end
        self.board = BoardWidget:new{
            size = board_size,
            game = self.game,
            flipped = self.flipped,
            plugin_dir = self.plugin.path,
            show_parent = self,
            player_color = self.player_color,
            show_legal = Store.get("show_legal_moves"),
            show_coords = Store.get("show_coordinates"),
            dark_color = Store.get("board_dark"),
            on_move = function(m) self:onPlayerMove(m) end,
            on_promotion = function(from, to, cb) self:askPromotion(cb) end,
        }
    end
    self.board.game = shown
    self.board.flipped = self.flipped
    self.board.player_color = not self.friend and self.player_color or nil
    self.board.interactive = not viewing and not self.finished and self.game.turn == self.player_color
        and not self.thinking
    if viewing then
        -- an earlier move: its badge, no hints
        local j = self.judgements[self.view_ply]
        local u = self.game:uciHistory()[self.view_ply]
        self.board:setMarks(nil)
        self.board:setBadge(j and u and Chess.squareIndex(u:sub(3, 4)), j and j.class)
    else
        self.board:setMarks(self.live_marks)
        self.board:setBadge(self.live_badge and self.live_badge.square, self.live_badge and self.live_badge.class)
    end

    local coach_text = self.coach_says or (self.coach_on and "I will comment on your moves. Tap Hint if you are stuck."
        or "Coach comments are off. Tap Hint if you are stuck.")
    if self.friend and not self.coach_says then
        coach_text = "Take turns on this device." .. (Store.get("friend_flip") and " The board turns to the player to move."
            or "")
    end
    if viewing then
        local j = self.judgements[self.view_ply]
        coach_text = j and j.text or "Looking at an earlier move. Tap › to go forward."
    end
    -- the explanation on the board, for the move shown
    local visual = self.live_visual
    if viewing then
        local j = self.judgements[self.view_ply]
        visual = j and j.visual
    end
    local coach_h = (landscape and height or (height - board_size)) - used
        - 2 * Size.padding.default - 2 * Size.border.thick
    local inner_w = side_w - 2 * Size.padding.default - 2 * Size.border.thick
    local coach_group = VerticalGroup:new{ align = "left" }
    local why_line
    if visual then
        why_line = Common.paragraph("▶ Tap here: see why on the board", inner_w, 16, { bold = true })
        coach_h = coach_h - why_line:getSize().h
    end
    coach_group[#coach_group + 1] = Common.paragraph(coach_text, inner_w, 18, { height = math.max(coach_h, Common.scale(40)) })
    if why_line then coach_group[#coach_group + 1] = why_line end
    local coach = Common.box(coach_group)
    if visual then
        coach = Common.TapBox:new{ coach, callback = function() self:showWhy(visual) end }
    end

    if landscape then
        local side = VerticalGroup:new{
            align = "left",
            strip, Common.vspace(gap), opponent, Common.vspace(gap), you, Common.vspace(gap),
            coach, Common.vspace(gap), buttons,
        }
        return HorizontalGroup:new{ align = "top", self.board, Common.hspace(2 * gap), side }
    end
    return VerticalGroup:new{
        align = "center",
        strip, Common.vspace(gap),
        opponent, Common.vspace(gap),
        self.board, Common.vspace(gap),
        you, Common.vspace(gap),
        coach, Common.vspace(gap),
        buttons,
    }
end

-- "12. Knight to f3 · Pawn to d6  13. …", the tail that fits, up to the move shown.
function GameScreen:moveStripText()
    local upto = self.view_ply or self.game:plyCount()
    if upto == 0 then return self.view_ply and "Start position" or "" end
    local words = Store.get("move_words")
    local replay = Chess.new(self.game.start_fen)
    local moves = self.game:uciHistory()
    local parts = {}
    for i = 1, upto do
        local m = replay:moveFromUci(moves[i])
        local text = words and Describe.move(replay, m) or replay:san(m)
        if replay.turn == "w" then text = replay.fullmove .. ". " .. text
        elseif i == 1 then text = replay.fullmove .. "… " .. text end
        parts[#parts + 1] = text
        replay:makeMove(m)
    end
    -- the last few moves are what matters
    local first = math.max(1, #parts - (words and 2 or 7))
    return (first > 1 and "… " or "") .. table.concat(parts, "  ", first)
end

function GameScreen:buildButtons(width)
    local ply, last = self.view_ply or self.game:plyCount(), self.game:plyCount()
    local can_undo = not self.thinking and self.game:plyCount() > 0 and not self.finished
    local row = {
        { text = "Menu", callback = function() self:showMenu() end },
        self.finished
            and { text = "Review", callback = function() self:openAnalysis(true) end }
            or { text = "Resign", enabled = self.game:plyCount() > 0, callback = function() self:resign() end },
        { text = "Take back", enabled = can_undo, callback = function() self:takeBack() end },
        { text = "Hint", enabled = not self.thinking and not self.finished, callback = function() self:hint() end },
        { text = "‹", enabled = ply > 0, callback = function() self:viewPly(ply - 1) end },
        { text = "›", enabled = ply < last, callback = function() self:viewPly(ply + 1) end },
    }
    return Common.buttonBar({ row }, width, self)
end

-- Looking at earlier moves -------------------------------------------------------

function GameScreen:positionAt(ply)
    local g = Chess.new(self.game.start_fen)
    local moves = self.game:uciHistory()
    for i = 1, math.min(ply, #moves) do g:move(moves[i]) end
    return g
end

-- Shows the position after `ply` half-moves; the last one means the live game.
function GameScreen:viewPly(ply)
    ply = math.max(0, math.min(ply, self.game:plyCount()))
    if ply == self.game:plyCount() then self.view_ply = nil else self.view_ply = ply end
    self.board:clearSelection()
    self:refresh()
end

function GameScreen:viewText()
    if self.view_ply == 0 then return "(start position)" end
    local before = self:positionAt(self.view_ply - 1)
    local m = before:moveFromUci(self.game:uciHistory()[self.view_ply])
    local j = self.judgements[self.view_ply]
    return "(move " .. before.fullmove .. (before.turn == "w" and ", White" or ", Black")
        .. (j and (" " .. Coach.tag(j.class)) or "") .. (m and "" or "") .. ")"
end

function GameScreen:onSwipe(_, ges)
    if not ges or not ges.direction then return false end
    local ply = self.view_ply or self.game:plyCount()
    if ges.direction == "east" then
        self:viewPly(ply - 1)
    elseif ges.direction == "west" then
        self:viewPly(ply + 1)
    else
        return false
    end
    return true
end

-- Game flow --------------------------------------------------------------------

function GameScreen:startTurn()
    if self.closed then return end
    if self:checkEnd() then return end
    if self.friend then
        self.player_color = self.game.turn
        if Store.get("friend_flip") then self.flipped = self.game.turn == "b" end
        self.status = ""
        self.thinking = false
        self.hint_level = 0
        self:startClock(self.game.turn)
        self:refresh()
        return
    end
    if self.game.turn == self.player_color then
        self.status = "Your move (" .. (self.player_color == "w" and "White" or "Black") .. ")"
        self.thinking = false
        self.hint_level = 0
        self:startClock(self.player_color)
        self:refresh()
        self:analyseForPlayer()
    else
        self:botMove()
    end
end

-- Background analysis of the player's position: used for hints and for
-- judging the player's next move.
function GameScreen:analyseForPlayer(cb)
    local fen = self.game:fen()
    if self.before and self.before.fen == fen and self.before.result then
        if cb then cb(self.before.result) end
        return
    end
    self.before = { fen = fen, waiting = cb and { cb } or {} }
    local entry = self.before
    self.engine:search({ fen = fen, depth = COACH_SEARCH.depth, movetime = COACH_SEARCH.movetime,
        multipv = COACH_SEARCH.multipv }, nil, function(res)
        entry.result = res
        for _, f in ipairs(entry.waiting) do f(res) end
        entry.waiting = {}
    end)
end

function GameScreen:onPlayerMove(m)
    if self.thinking or self.finished then return end
    local before_game = self.game:clone()
    local before_entry = self.before
    local played = self.game:move(m)
    if not played then return end
    if not self:stopClock(true) then return end
    if self.friend then
        self.live_marks = nil
        self.coach_says = nil
        self.before = nil
        self:saveProgress()
        return self:startTurn()
    end
    self.thinking = true
    self.hint_level = 0
    self.live_marks = nil
    self.live_badge = nil
    self.live_visual = nil
    self.status = self.bot.name .. " is thinking…"
    self.coach_says = self.coach_on and "Let me look at your move…" or self.coach_says
    self:saveProgress()
    self:refresh()

    local function continueWithBot(after)
        if self.closed then return end
        local judged
        if self.coach_on and after ~= false then
            local function judge(before)
                local j = Coach.classify(before_game, played, before, after, {
                    opponent_prev_class = self.last_bot_class,
                    is_book = self.game:plyCount() <= BOOK_MAX_PLY and Openings.isBook(self.game),
                })
                self.judgements[self.game:plyCount()] = j
                -- the game is still going: say what went wrong, not what to play
                self.coach_says, j.visual = Coach.explain(before_game, played, before, after, j,
                    Store.get("coach_level"), { hide_best = true })
                j.text = self.coach_says
                self.live_visual = j.visual
                self.live_badge = { square = played.to, class = j.class }
                judged = j
            end
            if before_entry and before_entry.fen == before_game:fen() and before_entry.result then
                judge(before_entry.result)
            end
        end
        local function proceed()
            if self.closed then return end
            if self:checkEnd() then return end
            self:botMove()
        end
        -- endgames with 7 pieces or fewer: the exact verdict from the Lichess tablebase, when online
        if judged and Coach.PROBLEMS[judged.class] and Coach.pieceCount(before_game) <= 7 then
            local NetworkMgr = require("ui/network/manager")
            if NetworkMgr:isOnline() then
                local verdict = Coach.tablebaseVerdict(self.plugin:lichess(), before_game, played)
                if verdict then
                    judged.text = judged.text .. " " .. verdict
                    self.coach_says = judged.text
                end
            end
        end
        -- a mistake with no tactic behind it: ask Stockfish's evaluation what it gave away
        local reply = after and after.lines and after.lines[1] and after.lines[1].pv and after.lines[1].pv[1]
        if judged and Coach.PROBLEMS[judged.class] and judged.class ~= "miss" and not judged.visual and reply then
            local j = judged
            local g2 = self.game:clone()
            local rm = g2:moveFromUci(reply)
            if rm then g2:makeMove(rm) end
            self.engine:evalTerms(before_game:fen(), function(tb)
                self.engine:evalTerms(g2:fen(), function(ta)
                    if self.closed then return end
                    local text, part = Coach.addPositional(j.text, before_game, played, reply, tb, ta)
                    if text then
                        j.text, j.visual = text, { part }
                        if self.judgements[self.game:plyCount()] == j then
                            self.coach_says, self.live_visual = text, j.visual
                        end
                    end
                    proceed()
                end)
            end)
            return
        end
        proceed()
    end

    if not self.coach_on then
        return continueWithBot(false)
    end
    local function analyseAfter()
        local res_game = self.game:gameResult()
        if res_game then return continueWithBot(nil) end
        self.engine:search({ fen = self.game:fen(), depth = COACH_SEARCH.depth, movetime = COACH_SEARCH.movetime,
            multipv = 1 }, nil, function(after)
            continueWithBot(after)
        end)
    end
    -- make sure the position before the move has been judged
    if before_entry and before_entry.fen == before_game:fen() and before_entry.result then
        analyseAfter()
    else
        self.engine:search({ fen = before_game:fen(), depth = COACH_SEARCH.depth, movetime = COACH_SEARCH.movetime,
            multipv = COACH_SEARCH.multipv }, nil, function(res)
            before_entry = { fen = before_game:fen(), result = res }
            analyseAfter()
        end)
    end
end

function GameScreen:botMove()
    if self.closed or self.finished then return end
    self.thinking = true
    self.status = self.bot.name .. " is thinking…"
    self:startClock(self.game.turn)
    self:refresh()
    local before_bot = self.game:clone()
    local player_move = self.game:lastMove()
    Bots.chooseMove(self.engine, self.game, self.bot, function(uci, info)
        if self.closed then return end
        if self.finished then return end
        local m = uci and self.game:move(uci)
        if m and not self:stopClock(true) then return end
        if not m then
            self.thinking = false
            if info and info.error then
                self.coach_says = "The chess engine could not run on this device: " .. tostring(info.error)
            end
            self:refresh()
            return
        end
        self.thinking = false
        local eval_bot
        if info and info.lines and info.lines[1] then eval_bot = Engine.lineCp(info.lines[1]) end
        local chat = not self.bot.no_personality
            and Bots.chatEvent(self.bot, self.game, before_bot.turn, player_move, m, eval_bot)
        if chat then self.bot_says = chat end
        if self.coach_on then
            local warn = Coach.warnAbout(before_bot, m)
            if warn then
                self.coach_says = (self.coach_says and (self.coach_says .. "\n\n") or "") .. warn
            end
        else
            self.coach_says = self.bot.name .. " played " .. Describe.move(before_bot, m):gsub("^%u", string.lower) .. "."
        end
        self:saveProgress()
        self:startTurn()
    end)
end

function GameScreen:checkEnd()
    local result, reason = self.game:gameResult({ no_claims = true })
    if not result then
        self:offerDrawClaim()
        return false
    end
    self:endGame(result, reason)
    return true
end

-- Threefold repetition and the fifty-move rule end the game only when the
-- player claims the draw (lichess asks the same way).
function GameScreen:offerDrawClaim()
    local claim = self.game:claimableDraw()
    if not claim or self.declined_claim == self.game:plyCount() then return end
    self.declined_claim = self.game:plyCount()
    UIManager:show(ConfirmBox:new{
        text = (claim == "threefold repetition" and "Threefold repetition" or "Fifty moves without a capture or pawn move")
            .. ". Claim a draw?",
        ok_text = "Claim draw",
        cancel_text = "Play on",
        ok_callback = function()
            if self.closed or self.finished then return end
            self.engine:cancelAll()
            self:endGame("1/2-1/2", claim)
        end,
    })
end

function GameScreen:endGame(result, reason)
    self.finished = true
    self.thinking = false
    self.view_ply = nil
    self.clock_side = nil
    self.result, self.reason = result, reason
    local won = (result == "1-0" and self.player_color == "w") or (result == "0-1" and self.player_color == "b")
    local draw = result == "1/2-1/2"
    local title, headline
    if self.friend then
        title = draw and "Draw" or (result == "1-0" and "White wins" or "Black wins")
        headline = draw and ("Draw by " .. reason .. ".")
            or ((result == "1-0" and "White" or "Black") .. " won by " .. reason .. "!")
    elseif draw then
        title, headline = "Draw", "Draw by " .. reason .. "."
        self.bot_says = self.bot.on_draw
    elseif won then
        title, headline = "Victory", "You won by " .. reason .. "!"
        self.bot_says = self.bot.on_loss
    else
        title, headline = "Game over", "You lost by " .. reason .. "."
        self.bot_says = self.bot.on_win
    end
    self.status = headline
    self.coach_says = (self.coach_says and (self.coach_says .. "\n\n") or "") .. headline
    self:finishGame(result)
    self:refresh()
    UIManager:scheduleIn(0.5, function()
        if self.closed then return end
        local dialog
        dialog = ButtonDialog:new{
            title = title .. "\n" .. headline .. (self.rating_change and ("\n" .. self.rating_change) or ""),
            buttons = { {
                { text = "Close", callback = function() UIManager:close(dialog) end },
                { text = "Analysis", callback = function() UIManager:close(dialog); self:openAnalysis(true) end },
                { text = "New game", callback = function() UIManager:close(dialog); self:newGame() end },
            } },
        }
        UIManager:show(dialog)
    end)
end

function GameScreen:finishGame(result)
    Store.clearSavedGame()
    local won = (result == "1-0" and self.player_color == "w") or (result == "0-1" and self.player_color == "b")
    local score = result == "1/2-1/2" and 0.5 or (won and 1 or 0)
    if not self.friend and self.game:plyCount() >= 2 then Store.recordGame(self.player_color, score) end
    if self.bot.elo and not self.friend and self.game:plyCount() >= 2 then
        local new, diff = Store.ratePlayerGame(self.bot.elo, score)
        self.rating_change = string.format("Your rating: %d (%+d)", new, diff)
        self.coach_says = (self.coach_says or "") .. "\n\n" .. self.rating_change .. "."
    end
    local white = self.player_color == "w" and "You" or self.bot.name
    local black = self.player_color == "b" and "You" or self.bot.name
    if self.friend then white, black = "White", "Black" end
    Store.addRecentGame{
        pgn = self.game:pgn({ White = white, Black = black, Result = result }),
        date = os.date("%Y-%m-%d %H:%M"),
        opponent = self.friend and "a friend" or self.bot.name,
        result = result,
        color = self.friend and "w" or self.player_color,
        friend = self.friend or nil,
    }
end

function GameScreen:saveProgress()
    if self.finished then return end
    Store.saveGame{
        bot_id = self.bot.id,
        color = self.player_color,
        start_fen = self.game.start_fen,
        moves = self.game:uciHistory(),
        date = os.date("%Y-%m-%d %H:%M"),
        clock = self.tc and { id = self.tc.id, w = self:timeLeft("w"), b = self:timeLeft("b") } or nil,
    }
end

-- Chess clock -----------------------------------------------------------------

function GameScreen:timeLeft(color)
    if not self.clocks then return nil end
    local t = self.clocks[color]
    if self.clock_side == color then t = t - (now() - self.clock_start) end
    return math.max(0, t)
end

function GameScreen:clockLabel(color)
    if not self.clocks then return "" end
    return "   ⏱ " .. clockText(self:timeLeft(color))
end

function GameScreen:startClock(color)
    if not self.clocks or self.finished then return end
    if self.clock_side == color then return end
    self:stopClock(false)
    self.clock_side = color
    self.clock_start = now()
    self:scheduleTick()
end

-- Stops the running clock; with `increment` the move was made, so its
-- seconds are added. Returns false when the flag fell (the game is over).
function GameScreen:stopClock(increment)
    local side = self.clock_side
    if not side then return true end
    local left = self:timeLeft(side)
    self.clock_side = nil
    self.clocks[side] = left
    if left <= 0 then
        self:flagFell(side)
        return false
    end
    if increment then self.clocks[side] = left + self.tc.inc end
    return true
end

-- Repaints the running clock: rarely while there is time, every second when it runs out.
function GameScreen:scheduleTick()
    if self.tick_scheduled then return end
    local side = self.clock_side
    local left = self:timeLeft(side)
    local delay = left > 60 and 5 or (left > 20 and 2 or 1)
    delay = math.max(0.2, math.min(delay, left))
    self.tick_scheduled = true
    UIManager:scheduleIn(delay, function()
        self.tick_scheduled = false
        if self.closed or self.finished or not self.clock_side then return end
        if self:timeLeft(self.clock_side) <= 0 then
            local s = self.clock_side
            self.clock_side = nil
            self.clocks[s] = 0
            self.engine:cancelAll()
            return self:flagFell(s)
        end
        self:refresh("ui")
        self:scheduleTick()
    end)
end

-- Lost on time, unless the other side has nothing left to mate with.
function GameScreen:flagFell(color)
    local other = color == "w" and "b" or "w"
    local can_mate = false
    for sq = 0, 127 do
        if sq % 16 < 8 then
            local p = self.game:get(sq)
            if p and Chess.colorOf(p) == other and p:lower() ~= "k" then can_mate = true end
        end
    end
    self.thinking = false
    if can_mate then
        self:endGame(other == "w" and "1-0" or "0-1", "time")
    else
        self:endGame("1/2-1/2", "time out with no mating material")
    end
end

-- Actions ---------------------------------------------------------------------

function GameScreen:takeBack()
    if self.thinking then return end
    self.engine:cancelAll()
    self:stopClock(false)
    if self.friend then
        self.game:undo()
        self.view_ply = nil
        self.board:clearSelection()
        self.live_marks = nil
        self.coach_says = "Move taken back."
        self:saveProgress()
        return self:startTurn()
    end
    -- back to the player's previous turn
    self.game:undo()
    if self.game.turn ~= self.player_color and self.game:plyCount() > 0 then self.game:undo() end
    if self.game.turn ~= self.player_color then
        -- the bot started the game: let it move again
        self.before = nil
        self:saveProgress()
        self:botMove()
        return
    end
    self.live_marks = nil
    self.live_badge = nil
    self.live_visual = nil
    self.view_ply = nil
    self.board:clearSelection()
    self.coach_says = "Move taken back. Try again!"
    self.before = nil
    self:saveProgress()
    self:startTurn()
end

function GameScreen:hint()
    if self.finished or self.game.turn ~= self.player_color then return end
    self.view_ply = nil
    self.hint_level = math.min(self.hint_level + 1, 3)
    local level = self.hint_level
    self.coach_says = "Thinking about a hint…"
    self:refresh()
    self:analyseForPlayer(function(res)
        if self.closed then return end
        local text, squares = Coach.hint(self.game, res and res.lines and res.lines[1], level)
        local marks = {}
        for _, s in ipairs(squares or {}) do marks[s] = "hint" end
        self.live_marks = marks
        if level < 3 then text = text .. "\n\n(Tap Hint again for more help.)" end
        self.coach_says = text
        self:refresh()
    end)
end

function GameScreen:askPromotion(cb)
    local dialog
    local function choose(p)
        UIManager:close(dialog)
        cb(p)
    end
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

function GameScreen:showMenu()
    local dialog
    local function item(text, fn, enabled)
        return { text = text, enabled = enabled ~= false, callback = function() UIManager:close(dialog); fn() end }
    end
    dialog = ButtonDialog:new{
        title = "Game",
        buttons = {
            { item("Flip board", function() self.flipped = not self.flipped; self:refresh() end) },
            { item("Analysis board", function() self:openAnalysis(self.finished) end) },
            { item("Move list", function() self:showMoveList() end) },
            { item(self.coach_on and "Turn coach comments off" or "Turn coach comments on", function()
                self.coach_on = not self.coach_on
                Store.set("coach_comments", self.coach_on)
                self.coach_says = self.coach_on and "Coach comments are on." or "Coach comments are off."
                self:refresh()
            end) },
            { item("Save game as PGN", function() self:savePgn() end) },
            { item("Rematch (same opponent)", function() self:rematch() end) },
            { item("New game", function() self:newGame() end) },
        },
    }
    UIManager:show(dialog)
end

-- "Why?": the explanation stepped through on a board.
function GameScreen:showWhy(visual)
    local ExplainPage = require("chessuite/ui/explainpage")
    UIManager:show(ExplainPage:new{ plugin = self.plugin, parts = visual, flipped = self.flipped })
end

function GameScreen:showMoveList()
    local MoveListPage = require("chessuite/ui/movelistpage")
    UIManager:show(MoveListPage:new{ game = self.game, judgements = self.judgements,
        current = self.view_ply or self.game:plyCount(),
        title = "Moves vs " .. self.bot.name,
        on_pick = function(ply) self:viewPly(ply) end })
end

function GameScreen:savePgn()
    local white = self.player_color == "w" and "You" or self.bot.name
    local black = self.player_color == "b" and "You" or self.bot.name
    local path = Store.gamesDir() .. "/" .. os.date("%Y-%m-%d_%H%M") .. "_" .. self.bot.id .. ".pgn"
    local f = io.open(path, "w")
    if not f then
        Common.info("Could not write " .. path)
        return
    end
    f:write(self.game:pgn({ White = white, Black = black, Result = self.result or "*" }), "\n")
    f:close()
    Common.info("Saved to " .. path, 3)
end

function GameScreen:resign()
    UIManager:show(ConfirmBox:new{
        text = "Resign this game?",
        ok_text = "Resign",
        ok_callback = function()
            self.engine:cancelAll()
            self:endGame(self.player_color == "w" and "0-1" or "1-0", "resignation")
        end,
    })
end

-- New game: back to the opponent list, like the lichess "new game" sheet.
function GameScreen:newGame()
    self.engine:cancelAll()
    if not self.finished then Store.clearSavedGame() end
    if self.friend then return self:rematch() end
    self.closed = true
    UIManager:close(self)
    local OpponentScreen = require("chessuite/ui/opponentscreen")
    UIManager:show(OpponentScreen:new{ plugin = self.plugin, on_close = self.on_close })
end

function GameScreen:rematch()
    self.engine:cancelAll()
    Store.clearSavedGame()
    if self.friend then
        self.closed = true
        UIManager:close(self)
        UIManager:show(GameScreen:new{ plugin = self.plugin, bot = self.bot, player_color = "w",
            on_close = self.on_close })
        return
    end
    local ColorPicker = require("chessuite/ui/colorpicker")
    ColorPicker.ask(self.bot, function(color)
        self.closed = true
        UIManager:close(self)
        UIManager:show(GameScreen:new{ plugin = self.plugin, bot = self.bot, player_color = color,
            on_close = self.on_close })
    end)
end

function GameScreen:openAnalysis(review)
    local AnalysisScreen = require("chessuite/ui/analysisscreen")
    self.engine:cancelAll()
    self:stopClock(false)
    self.thinking = false
    local g = Chess.new(self.game.start_fen)
    for _, u in ipairs(self.game:uciHistory()) do g:move(u) end
    UIManager:show(AnalysisScreen:new{
        plugin = self.plugin,
        game = g,
        review = review,
        player_color = self.player_color,
        title = review and "Game review" or "Analysis",
        on_close = function()
            if not self.closed and not self.finished then
                self.before = nil
                self:startTurn()
            end
        end,
    })
end

function GameScreen:onClose()
    if not self.finished and self.clock_side then
        self:stopClock(false)
        self:saveProgress()
    end
    self.closed = true
    self.engine:cancelAll()
    if self.board then self.board:free() end
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

return GameScreen
