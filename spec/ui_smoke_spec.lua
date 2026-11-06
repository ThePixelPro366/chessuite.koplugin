-- Drives the real pages with stand-in KOReader widgets and the real engine:
-- home -> opponent -> game (moves, coach, hint, take back) -> review,
-- puzzles with a fake Lichess client, account page. Run from the plugin dir:
--     luajit spec/ui_smoke_spec.lua
package.path = "./spec/stubs/?.lua;./?.lua;" .. package.path
math.randomseed(7)
local Fake = require("fakeko")
local UIManager = require("ui/uimanager")

local failures = 0
local function check(name, cond)
    print((cond and "ok   " or "FAIL ") .. name)
    if not cond then failures = failures + 1 end
end

-- find widgets in a page's tree
local function find(w, pred, seen)
    seen = seen or {}
    if type(w) ~= "table" or seen[w] then return nil end
    seen[w] = true
    if pred(w) then return w end
    for k, v in pairs(w) do
        if type(v) == "table" and k ~= "show_parent" and k ~= "plugin" and k ~= "game" and k ~= "engine"
            and k ~= "__index" then
            local r = find(v, pred, seen)
            if r then return r end
        end
    end
end
local function tile(page, title)
    return find(page[1], function(x) return x.title == title and x.callback end)
end
local function run(cond, secs) UIManager:run(cond, secs or 30) end

-- The start page has four cards; most things are one card further, on a menu page.
local home
local MENU_OF = { ["Play a bot"] = "Play", ["Learn with Coach"] = "Play", ["Play a friend"] = "Play",
    ["Continue your game"] = "Play", Puzzles = "Puzzles", ["Puzzle Streak"] = "Puzzles", ["Daily puzzle"] = "Puzzles",
    ["Puzzles by opening"] = "Puzzles", Practice = "Learn", Openings = "Learn",
    ["Analysis board"] = "Analysis", ["Review my games"] = "Analysis", ["My progress"] = "Analysis" }
local function homeTile(name)
    if name == "Play" then name = "Play a bot" end
    if not MENU_OF[name] then return tile(home, name) end
    return { callback = function()
        tile(home, MENU_OF[name]).callback()
        run(nil, 0.2)
        local menu = Fake.top()
        local t = tile(menu, name)
        assert(t, "no " .. name .. " on the " .. MENU_OF[name] .. " page")
        -- the menu page goes away, the page it opened stays
        menu.closed = true
        UIManager:close(menu)
        t.callback()
    end }
end

-- load the plugin like KOReader does
local Plugin = dofile("main.lua")
local function Chess_uci(m) return require("chessuite/chess").uci(m) end
local plugin = Plugin:new{ ui = { menu = { registerToMainMenu = function() end } }, path = "." }
local menu = {}
plugin:addToMainMenu(menu)
check("main menu entry", menu.chessuite and menu.chessuite.callback)
menu.chessuite.callback()
home = Fake.top()
check("home page shown", home and home.title == "Chessuite")
check("home has X close via title bar", home.title_bar and home.title_bar.close_callback ~= nil)
check("four cards on the start page", tile(home, "Play") and tile(home, "Puzzles") and tile(home, "Learn")
    and tile(home, "Analysis") and not tile(home, "Daily puzzle"))

-- Play -> opponents
homeTile("Play").callback()
run(nil, 0.2)
local opp = Fake.top()
check("opponent page", opp.title == "Choose your opponent")
Fake.press("Beginner")
local pip = tile(Fake.top(), "Pip")
check("Pip card", pip ~= nil)
pip.callback()
Fake.choose("White")
local game = Fake.top()
check("game page vs Pip", game.bot and game.bot.id == "pip")
run(function() return game.status and game.status:find("Your move") end, 5)
check("player's turn", game.status:find("Your move") ~= nil)

-- play a few moves through the board widget
local function playerMove(uci)
    run(function() return not game.thinking and game.game.turn == "w" end, 30)
    local m = game.game:moveFromUci(uci)
    if not m then return false end
    game.board.on_move(m)
    run(function() return not game.thinking and game.game.turn == "w" end, 40)
    return true
end
check("move e2e4", playerMove("e2e4"))
check("bot answered", game.game:plyCount() == 2)
check("coach commented in words", game.coach_says and game.coach_says:find("Pawn to e4") ~= nil)
check("e4 is a book move with its name", game.coach_says:find("Pawn to e4 is a book move %(King's Pawn Game%)") ~= nil)
print("   coach:", game.coach_says)
print("   bot:", game.bot_says)
-- a blunder: queen out to be taken
local g = game.game
local blunder
for _, u in ipairs({ "d1h5", "d1g4", "d1f3" }) do if g:moveFromUci(u) then blunder = u break end end
local fen_before_blunder = g:fen()
playerMove(blunder or "g1f3")
print("   position:", fen_before_blunder, blunder)
print("   coach:", game.coach_says)
check("judgement recorded", next(game.judgements) ~= nil)

-- look at earlier moves
local live = game.game:plyCount()
Fake.press("‹")
check("back one move", game.view_ply == live - 1 and game.board.game:plyCount() == live - 1)
check("board locked while looking back", game.board.interactive == false)
print("   strip:", game:moveStripText(), "|", game:viewText())
game:onSwipe(nil, { direction = "east" })
check("swipe goes back", game.view_ply == live - 2)
game:viewPly(0)
check("first position", game.view_ply == 0 and game.board.game:plyCount() == 0)
game:onSwipe(nil, { direction = "west" })
check("swipe goes forward", game.view_ply == 1)
print("   move 1 comment:", (game.judgements[1] or {}).text)
for _ = 1, live do if game.view_ply then Fake.press("›") end end
check("back to the live game", game.view_ply == nil and game.board.game == game.game and game.board.interactive)

-- hint
Fake.press("Hint")
run(function() return game.coach_says and not game.coach_says:find("Thinking") end, 20)
print("   hint:", game.coach_says)
check("hint text", game.coach_says:find("Tap Hint again") ~= nil)

-- take back
local ply = game.game:plyCount()
Fake.press("Take back")
run(function() return not game.thinking end, 20)
check("take back two plies", game.game:plyCount() == ply - 2)

-- menu: move list and resign
game.left_icon_tap_callback()
Fake.choose("Move list")
local ml = Fake.top()
check("move list page", ml.game ~= nil)
ml:onClose()
game:refresh()
Fake.press("Resign")
-- ConfirmBox: call ok directly
local cb
for i = #Fake.shown, 1, -1 do if Fake.shown[i].ok_callback then cb = Fake.shown[i] break end end
cb.ok_callback()
UIManager:close(cb) -- the real ConfirmBox closes itself
run(nil, 0.7)
local over = Fake.top()
check("game over dialog", over.title and over.title:find("^Game over") ~= nil)
print("   dialog:", (over.title:gsub("\n", " | ")))
Fake.choose("Close")
check("game finished after resign", game.finished == true)
local Store = require("chessuite/store")
check("game stored for review", #Store.recentGames() == 1)
check("rating went down after resigning", Store.playerRating() < 1200)
print("   " .. game.coach_says:match("Your rating: [^\n]*"))
check("no saved unfinished game", Store.savedGame() == nil)

-- Review
Fake.press("Review")
local an = Fake.top()
check("analysis/review page", an.title == "Game review")
run(function() return an.reviewed and not an.reviewing end, 120)
check("review finished with a summary table", an.summary ~= nil and an.summary:find("Accuracy") ~= nil)
print("   " .. an.summary:gsub("\n", "\n   "))
Fake.press("›")
an:buildContent(an.content_width, an.content_height)
check("review badge on the board", an.board.badge and an.board.badge.class == an.reviewed[1].class)
print("   header:", an:headerText())
print("   strip:", an:moveStripText())
-- a different move makes a variation; the game stays the main line
local main_len = #an.mainline
an:goTo(1)
local alt
for _, m in ipairs(an.pos:moves()) do if Chess_uci(m) ~= an.mainline[2] then alt = m break end end
an.board.on_move(alt)
check("variation keeps the main line", an.var_from == 1 and #an.mainline == main_len and an.ply == 2)
an:backToMainLine()
check("back to the main line", an.var_from == nil and an.moves == an.mainline and an.ply == 1)
-- engine lines
if not an.engine_on then Fake.press("Engine") else an:analyse() end
run(function() return not an.engine_running end, 20)
check("engine lines", an.lines and #an.lines >= 1)
print("   panel:", (an:panelText():gsub("\n", " | ")))
-- learn from your mistakes, as the side that blundered the queen
an:startRetro("w")
run(function() return an.retro and an.retro.state ~= nil end, 5)
print("   retro:", an.retro.state, an.retro.title)
if an.retro.state == "find" then
    local best = an.pos:moveFromUci(an.evals[an.retro.ply - 1].lines[1].pv[1])
    an.board.on_move(best)
    check("best move is a good move", an.retro.state == "correct" and an.retro.title == "Good move!")
    Fake.press("Next mistake")
    check("retro done or next", an.retro.state == "done" or an.retro.state == "find")
else
    check("no white mistakes after the take back", an.retro.title == "No mistakes found for white.")
end
-- black's mistakes: try a wrong move first, then view the solution
an:exitRetro()
an:startRetro("b")
print("   retro black:", an.retro.state, an.retro.title)
if an.retro.state == "find" then
    Fake.press("View the solution")
    check("solution shows the better move", an.retro.state == "solution" and an.retro.text:find("Best was") ~= nil)
end
an:exitRetro()
-- learn from mistakes on a game with a real blunder (black allows mate in one)
an:exitRetro()
an:loadGame(require("chessuite/chess").fromPgn("1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#"), true)
run(function() return an.reviewed and not an.reviewing end, 120)
print("   summary:", (an.summary:gsub("\n", " | ")))
an:startRetro("b")
print("   retro:", an.retro.state, an.retro.title)
check("retro finds black's blunder", an.retro.state == "find" and an.retro.title:find("Knight to f6 was played") ~= nil)
an.board.on_move(an.pos:moveFromUci("g8f6"))
check("playing the same mistake again", an.retro.state == "wrong" and an.retro.title == "You can do better.")
run(function() return an.retro.state == "find" end, 3)
an.board.on_move(an.pos:moveFromUci("d8e7"))
run(function() return an.retro.state ~= "eval" end, 30)
print("   after queen to e7:", an.retro.state, an.retro.title, an.retro.text)
check("a good alternative is accepted", an.retro.state == "correct")
an:exitRetro()

-- move list: tap a move to jump
an:openMoveList()
local ml2 = Fake.top()
check("move list page with tappable moves", ml2.on_pick ~= nil)
ml2:onClose()
an:onClose()
game:onClose()
check("closing the game returns to home", Fake.top() == home)

-- Puzzles with a fake Lichess client
Store.set("lichess_token", "lip_test")
Store.set("lichess_username", "tester")
local solved_sent
plugin.lichess_client = {
    puzzleBatch = function() return true, { puzzles = {
        { game = { pgn = "e4 e5 Nf3 d5 Nxe5 dxe4 Bc4 Be6 Bxe6 fxe6 Qh5+ Ke7 d4 Qxd4 b3 Nf6 Qf7+ Kd6 Nc4+ Kc6 Qxe6+ Bd6 Be3 Qxa1" },
          puzzle = { id = "Ba42D", rating = 1716, solution = { "c4a5", "c6b5", "e6c4", "b5a5", "c4a4" }, themes = { "mateIn3" } } },
    } } end,
    solvePuzzles = function(_, angle, sols)
        solved_sent = sols
        return true, { rounds = { { id = sols[1].id, win = sols[1].win, ratingDiff = 11 } }, glicko = { rating = 1611 } }
    end,
    account = function() return true, { username = "tester", perfs = { puzzle = { rating = 1600 } } } end,
    puzzleDashboard = function() return true, { global = { nb = 3, firstWins = 2 } } end,
}
home:refreshHome()
homeTile("Puzzles").callback()
run(nil, 0.3)
local pz = Fake.top()
run(function() return pz.mode == "play" end, 5)
check("puzzle loaded, opponent's move played", pz.game ~= nil and pz.color == "w"
    and require("chessuite/chess").uci(pz.game:lastMove()) == "d4a1")
print("   " .. pz.feedback.title .. " / " .. pz.feedback.text)
local function pmove(u)
    run(function() return not pz.waiting end, 5)
    pz.board.on_move(pz.game:moveFromUci(u))
    run(function() return not pz.waiting end, 5)
end
pmove("c4a5")
pmove("e6c4")
pmove("c4a4")
run(nil, 1)
check("puzzle solved", pz.mode == "view" and pz.feedback.title == "Success!")
check("result sent to lichess", solved_sent and solved_sent[1].win == true and solved_sent[1].rated == true)
check("rating updated", Store.get("puzzle_rating") == 1611 and pz.session[1].diff == 11)
print("   " .. pz:ratingText())
Fake.press("‹")
check("step back through the solved puzzle", pz.view_ply == pz.game:plyCount() - 1)
-- a wrong move on the next puzzle (cache is empty -> refill with the same puzzle)
Fake.press("Continue training")
run(function() return pz.mode == "play" end, 5)
pz.board.on_move(pz.game:moveFromUci("e6e4") or pz.game:moves()[1])
run(function() return pz.arrows ~= nil end, 30)
run(nil, 1)
print("   " .. pz.feedback.title .. ": " .. pz.feedback.text)
check("wrong move counts as a loss right away", solved_sent[1].win == false)
check("refutation arrow and reason", pz.arrows ~= nil and (pz.feedback.text:find("your opponent can answer") ~= nil
    or pz.feedback.text:find("^Nice try, but it ") ~= nil))
check("the refutation can be seen on the board", pz.visual == nil or (pz.visual[1].steps and #pz.visual[1].steps >= 2))
local pz_ply = pz.game:plyCount()
Fake.press("Retry")
check("retry takes the move back", pz.mode == "play" and pz.game:plyCount() == pz_ply - 1 and pz.arrows == nil)
-- view the solution and step through it
pz.unlock_at = 0
pz:refresh()
Fake.press("View solution")
run(function() return not pz.waiting end, 5)
check("solution shown one move at a time", pz.mode == "view" and pz.view_ply ~= nil)
-- next puzzle: a hint makes it unrated, not failed
Fake.press("Continue training")
run(function() return pz.mode == "play" end, 5)
pz.unlock_at = 0
pz:refresh()
Fake.press("Hint")
check("hint marks the piece", pz.marks ~= nil and pz.hint_used)
pmove("c4a5")
pmove("e6c4")
pmove("c4a4")
run(nil, 1)
check("hinted puzzle is a win sent unrated", solved_sent[1].win == true and solved_sent[1].rated == false)
pz:onClose()

-- Game review by Lichess' server analysis (logged in, online)
local exports = 0
local requested
plugin.lichess_client.importGame = function() return true, { id = "abcd1234", url = "https://lichess.org/abcd1234" } end
plugin.lichess_client.requestAnalysis = function(_, id) requested = id; return true, {} end
plugin.lichess_client.exportGame = function()
    exports = exports + 1
    if exports < 7 then return true, { id = "abcd1234" } end -- not analysed yet
    return true, {
        players = { white = { analysis = { inaccuracy = 0, mistake = 0, blunder = 0, acpl = 12, accuracy = 95 } },
                    black = { analysis = { inaccuracy = 0, mistake = 0, blunder = 1, acpl = 210, accuracy = 41 } } },
        analysis = { { eval = 30 }, { eval = 35 }, { eval = 10 }, { eval = 20 }, { eval = 25 },
            { mate = 1, best = "g7g6", variation = "g6", judgment = { name = "Blunder", comment = "Blunder. g6 was best." } },
            { mate = 0 } },
    }
end
Store.setWebSession("sessionId=abc", "tester", "PhoneUA")
local AnalysisScreen = require("chessuite/ui/analysisscreen")
local la = AnalysisScreen:new{ plugin = plugin, game = require("chessuite/chess").fromPgn("1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#"),
    review = true, title = "Game review" }
UIManager:show(la)
run(function() return exports >= 5 end, 20)
check("review follows lichess on the board", la.reviewing and la.ply > 0 and la.message:find("%d+%%") ~= nil)
print("   while waiting:", la.message, "|", la:headerText())
run(function() return la.reviewed and not la.reviewing end, 60)
print("   lichess summary:", (la.summary or "?"):gsub("\n", " | "))
check("analysis requested from lichess", requested == "abcd1234")
check("lichess numbers in the summary", la.summary and la.summary:find("95%%") and la.summary:find("Analysis by Lichess"))
check("lichess judgment used", la.reviewed[6] and la.reviewed[6].class == "blunder")
la:goTo(5)
local lbest = la:shownLines()
check("best move from lichess shown", lbest and lbest[1].pv[1] == "g7g6")
-- "see why" after a Lichess review: the punishing line is worked out on demand
check("lichess blunder waits for its line", la.reviewed[6].needs_why == true)
la:showWhy(6)
run(function() return not la.reviewed[6].needs_why end, 30)
local lw = Fake.top()
print("   lichess why:", la.reviewed[6].text)
check("see why after a lichess review names the mate", lw.parts and lw.parts[1].title == "What goes wrong"
    and lw.parts[1].headline:find("checkmate") ~= nil)
lw:onClose()
la:onClose()
-- Lichess refuses: the local review takes over and says why
plugin.lichess_client.requestAnalysis = function() return false, "HTTP 403", 403 end
plugin.lichess_client.exportGame = function() return true, { id = "x" } end
local la2 = AnalysisScreen:new{ plugin = plugin, game = require("chessuite/chess").fromPgn("1. e4 e5"), review = true }
local la2_seen = {}
local show_position = la2.showReviewPosition
la2.showReviewPosition = function(screen, at_ply)
    la2_seen[#la2_seen + 1] = at_ply
    return show_position(screen, at_ply)
end
UIManager:show(la2)
run(function() return la2.reviewed and not la2.reviewing end, 120)
check("falls back to the local review and says why", la2.summary and la2.summary:find("refused with HTTP 403") ~= nil)
check("local review showed every analysed position on the board", #la2_seen >= #la2.mainline
    and la2_seen[#la2_seen] == #la2.mainline)
print("   fallback note:", la2.review_note)
la2:onClose()
Store.forgetWebSession()

-- Connect phone: the pairing page shows its QR code and can be painted
require("chessuite/pairing").localIp = function() return "192.168.1.20" end
local PairPage = require("chessuite/ui/pairpage")
local pp = PairPage:new{ plugin = plugin }
UIManager:show(pp)
run(function() return pp.state ~= "starting" end, 3)
print("   pairing:", pp.state, pp.pairing and pp.pairing.ip and pp:buildContent(pp.content_width, pp.content_height) and pp.pairing:url() or pp.error)
pp:refresh()
local paint_ok, paint_err = pcall(Fake.paint, pp[1])
check("pairing page paints without crashing", paint_ok)
if not paint_ok then print("   " .. tostring(paint_err)) end
pp:onClose()

-- Account page
home:showSettings()
Fake.choose("Lichess account")
run(nil, 0.5)
local acc = Fake.top()
check("account page logged in", acc.account and acc.account.username == "tester")
Fake.press("Log out")
check("logged out", not Store.isLoggedIn())
acc:onClose()

-- coach comments off: the box just says what the bot played
Store.set("coach_comments", false)
Store.setPlayerRating(1650)
local Bots = require("chessuite/bots")
local c = Bots.coachFor(Store.playerRating())
check("coach plays at your rating", c.elo == 1650 and c.depth == Bots.BY_ID.leo.depth and c.is_coach)
homeTile("Learn with Coach").callback()
Fake.choose("White")
local cg = Fake.top()
check("coach game at your rating", cg.bot.elo == 1650 and cg.title:find("1650") ~= nil)
run(function() return cg.status and cg.status:find("Your move") end, 5)
cg.board.on_move(cg.game:moveFromUci("d2d4"))
run(function() return not cg.thinking and cg.game.turn == "w" end, 60)
print("   comments off:", cg.coach_says)
check("no coach verdict when off", not cg.coach_says:find(" is a ") and cg.coach_says:find("Coach played") ~= nil)
cg:onClose()
Store.set("coach_comments", true)

-- plain Stockfish at 150 Elo
local sf = Bots.stockfishAt(150)
check("stockfish 150 is weak and quiet", sf.random_move > 0.35 and sf.no_personality and Bots.get("sf:150").elo == 150)
local sf1900 = Bots.stockfishAt(1900)
check("stockfish 1900 between ivy and omar", sf1900.depth >= 6 and sf1900.depth <= 7)
homeTile("Play").callback()
run(nil, 0.2)
local op = Fake.top()
Fake.press("Stockfish")
local any = tile(Fake.top(), "Stockfish at any rating")
check("any-rating tile", any ~= nil)
op:pick(sf)
Fake.choose("Black")
local sg = Fake.top()
run(function() return sg.game:plyCount() == 1 end, 30)
check("stockfish 150 opened as white", sg.game:plyCount() == 1 and sg.bot_says == nil)
sg:onClose()

homeTile("Play").callback()
run(nil, 0.2)
op = Fake.top()
Fake.press("Intermediate")
check("good match badge", tile(Fake.top(), "Leo").badge:find("good match") ~= nil
    and not tile(Fake.top(), "Nova").badge:find("good match"))
op:onClose()

-- every icon the pages use exists, in black and in white
local Common = require("chessuite/ui/common")
for _, f in ipairs({ "play", "coach", "friend", "puzzle", "streak", "daily", "opening", "practice", "analysis",
    "review", "stats", "account", "continue", "engine", "trophy", "download" }) do
    local a, b = io.open(Common.iconFile(f)), io.open(Common.iconFile(f, true))
    check("icon " .. f, a ~= nil and b ~= nil)
    if a then a:close() end
    if b then b:close() end
end
check("bot cards show pieces", Bots.pieceFor(Bots.get("pip")) == "p" and Bots.pieceFor(Bots.get("kai")) == "q")

-- Play a friend: both sides move on the board, the board turns, no engine moves
Store.set("time_control", "none")
homeTile("Play a friend").callback()
Fake.choose("Start")
local fg = Fake.top()
check("friend game", fg.friend and fg.title == "Play a friend")
run(nil, 0.3)
fg.board.on_move(fg.game:moveFromUci("e2e4"))
run(nil, 0.3)
check("friend: black to move, board turned", fg.game.turn == "b" and fg.flipped and fg.board.player_color == nil)
fg.board.on_move(fg.game:moveFromUci("e7e5"))
run(nil, 0.3)
check("friend: no bot reply", fg.game:plyCount() == 2 and fg.game.turn == "w" and not fg.flipped)
fg:takeBack()
check("friend: take back one move", fg.game:plyCount() == 1)
check("friend game saved for later", Store.savedGame().bot_id == "friend")
fg:onClose()

-- the clock: time runs for the side to move and the flag falls
Store.set("time_control", "3+2")
homeTile("Play a friend").callback()
Fake.choose("Start")
local cl = Fake.top()
check("clock in the title", cl.tc and cl.title:find("3 %+ 2") ~= nil)
run(nil, 0.3)
cl.board.on_move(cl.game:moveFromUci("e2e4"))
check("white's clock stopped, black's runs", cl.clocks.w > 170 and cl.clock_side == "b")
cl.clock_start = cl.clock_start - 500 -- black lets the time run out
run(function() return cl.finished end, 8)
check("black lost on time", cl.result == "1-0" and cl.reason == "time")
cl:onClose()
Store.set("time_control", "none")

-- Lichess Practice, bundled like the Lichess app: 5 sections, 32 courses, 316 lessons
local LP = require("chessuite/lichesspractice")
local _, lp_total = LP.progress()
check("practice: all lessons bundled", #LP.sections() == 5 and lp_total == 316)
check("practice goals in words", LP.goalText({ result = "mateIn", moves = 1 }, "w") == "Checkmate the opponent in 1 move."
    and LP.goalText({ result = "drawIn", moves = 20 }, "b") == "Hold the draw for 20 moves.")
check("practice verdicts like lichess", LP.verdict("w", { cp = 50 }, { cp = 40 }, "a", "b") == "goodMove"
    and LP.verdict("w", { cp = 300 }, { cp = -300 }, "a", "b") == "blunder"
    and LP.verdict("w", { cp = 300 }, { cp = -300 }, "b", "b") == "goodMove")
-- every gamebook and lesson can be read
local books = 0
for _, sec in ipairs(LP.sections()) do
    for _, st in ipairs(sec.studies) do
        for _, ch in ipairs(st.chapters) do
            if ch.kind ~= "practice" then
                books = books + 1
                local b = LP.parseGamebook(ch)
                if #b.moves == 0 then check("gamebook " .. ch.name .. " has moves", false) end
            end
        end
    end
end
check("37 gamebooks and lessons", books == 37)
Store.set("lichess_practice_done", nil)
local lc = plugin:lichess() -- the Lichess client, faked below
homeTile("Practice").callback()
run(nil, 0.2)
local pr = Fake.top()
check("practice page with resume", pr.title == "Practice" and tile(pr, "Resume learning") ~= nil)
-- a practice lesson: Piece Checkmates I, "Queen and rook mate" (mate)
local study = LP.study("BJy6fEDf")
local LessonScreen = require("chessuite/ui/lessonscreen")
local ls = LessonScreen:new{ plugin = plugin, study = study, index = 1 }
UIManager:show(ls)
run(function() return ls.state == "play" end, 30)
check("practice lesson: goal and description", ls.kind == "practice" and ls.feedback.text:find("Checkmate the opponent")
    and ls.feedback.text:find("restrict the king"))
ls.board.on_move(ls.game:moveFromUci("h1h5"))
run(function() return ls.state == "play" or ls.state == "fail" or ls.state == "success" end, 40)
print("   practice after Rh5:", ls.state, ls.feedback.title, ls.feedback.text)
check("practice lesson goes on", ls.state == "play" and ls.nb == 1)
ls:onClose()
-- a gamebook lesson: Knight & Bishop Mate, "Introduction"
local kb = LP.study("ByhlXnmM")
local gb = LessonScreen:new{ plugin = plugin, study = kb, index = 1 }
UIManager:show(gb)
run(nil, 0.3)
check("gamebook lesson", gb.kind == "gamebook" and gb.state == "play" and #gb.book.moves > 0)
local first = gb.book.moves[1].uci
local wrong
for _, mv in ipairs(gb.game:moves()) do
    if require("chessuite/chess").uci(mv) ~= first then wrong = mv break end
end
gb.board.on_move(wrong)
check("a wrong gamebook move is shown and taken back", gb.state == "bad")
run(function() return gb.state == "play" end, 3)
check("taken back", gb.state == "play" and gb.nb == 0)
gb.board.on_move(gb.game:moveFromUci(first))
check("the authored move is good", gb.nb == 1 and (gb.state == "good" or gb.state == "success"))
-- play the whole book: own moves on the board, the opponent's with Next or on their own
for _ = 1, 200 do
    if gb.state == "success" then break end
    if gb.state == "good" then
        run(function() return gb.state ~= "good" or not gb.auto end, 2)
        if gb.state == "good" then gb:gamebookNext() end
    elseif gb.state == "play" then
        gb.board.on_move(gb.game:moveFromUci(gb.book.moves[gb.nb + 1].uci))
    end
end
check("gamebook completed", gb.state == "success" and LP.isDone("ByhlXnmM", kb.chapters[1].id))
gb:onClose()
pr:onClose()

-- The opening explorer in the analysis board
Store.set("lichess_token", "lip_test")
lc.explorer = function(_, db, fen)
    if fen:find("^rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w") then
        return true, { white = 600, draws = 300, black = 100, opening = nil, moves = {
            { uci = "e2e4", white = 400, draws = 200, black = 50 }, { uci = "d2d4", white = 200, draws = 100, black = 50 } } }
    end
    return true, { white = 100, draws = 50, black = 50, opening = { eco = "B00", name = "King's Pawn Game" },
        moves = { { uci = "c7c5", white = 60, draws = 30, black = 30 } } }
end
homeTile("Analysis board").callback()
run(nil, 0.5)
local ab = Fake.top()
ab:openExplorer()
run(nil, 0.3)
local ex = Fake.top()
check("explorer page with masters' moves", ex.title == "Opening explorer" and ex.data and #ex.data.moves == 2)
ex:play("e2e4")
run(nil, 0.3)
check("a move from the explorer is played on the board", ab.ply == 1 and ab.moves[1] == "e2e4"
    and ex.data.opening.name == "King's Pawn Game")
ex:back()
check("and taken back", ab.ply == 0)
ex:onClose()
ab:onClose()

-- Puzzle Streak: harder puzzles, one mistake ends it
local streak_calls = {}
plugin:lichess().puzzleBatch = function(_, angle, nb, difficulty)
    streak_calls[#streak_calls + 1] = difficulty
    return true, { puzzles = { {
        game = { pgn = "e4 e5 Nf3 d5 Nxe5 dxe4 Bc4 Be6 Bxe6 fxe6 Qh5+ Ke7 d4 Qxd4 b3 Nf6 Qf7+ Kd6 Nc4+ Kc6 Qxe6+ Bd6 Be3 Qxa1" },
        puzzle = { id = "s" .. #streak_calls, rating = 1700, plays = 5,
            solution = { "c4a5", "c6b5", "e6c4", "b5a5", "c4a4" } },
    } } }
end
homeTile("Puzzle Streak").callback()
local ps = Fake.top()
run(function() return ps.mode == "play" end, 5)
check("streak asks for the easiest first", streak_calls[1] == "easiest")
for _, u in ipairs({ "c4a5", "e6c4", "c4a4" }) do
    run(function() return ps.mode == "play" and not ps.waiting end, 5)
    ps.board.on_move(ps.game:moveFromUci(u))
end
run(function() return ps.streak_count == 1 and ps.mode == "play" and not ps.waiting end, 6)
check("streak goes on", ps.streak_count == 1 and ps.mode == "play")
ps.board.on_move(ps.game:moveFromUci("c4b6"))
check("streak over after a mistake", ps.streak_over and Store.bestStreak() >= 1)
run(nil, 4)
ps:onClose()

-- My games: the Lichess tab
Store.set("lichess_username", "tester")
plugin:lichess().userGames = function(_, name)
    return true, { { id = "lg1", pgn = '[Event "x"]\n\n1. e4 e5 2. Nf3 Nc6 *', white = name, black = "Bob",
        color = "w", result = "1-0", opponent = "Bob", date = "2026-10-01", opening = "King's Knight Opening",
        speed = "blitz" } }
end
homeTile("Review my games").callback()
local gp = Fake.top()
Fake.press("On Lichess")
local lt = tile(gp, "vs Bob · You won")
check("lichess game listed", lt ~= nil)
lt.callback()
local lr = Fake.top()
check("lichess game opened for review with its id", lr.lichess_game_id == "lg1")
run(nil, 1)
lr:onClose()

-- Puzzles by opening, like the Lichess app
Store.set("lichess_token", "lip_test")
local angles_asked = {}
plugin:lichess().puzzleOpenings = function()
    return true, { openings = {
        { family = { key = "Sicilian_Defense", name = "Sicilian Defense", count = 206807 },
          openings = { { key = "Sicilian_Defense_Najdorf_Variation", name = "Najdorf Variation", count = 11173 } } },
        { family = { key = "Italian_Game", name = "Italian Game", count = 90000 }, openings = {} },
    } }
end
plugin:lichess().puzzleBatch = function(_, angle)
    angles_asked[#angles_asked + 1] = angle
    return true, { puzzles = { {
        game = { pgn = "e4 e5 Nf3 d5 Nxe5 dxe4 Bc4 Be6 Bxe6 fxe6 Qh5+ Ke7 d4 Qxd4 b3 Nf6 Qf7+ Kd6 Nc4+ Kc6 Qxe6+ Bd6 Be3 Qxa1" },
        puzzle = { id = "op" .. #angles_asked, rating = 1500, plays = 3, solution = { "c4a5", "c6b5", "e6c4", "b5a5", "c4a4" } },
    } } }
end
local angle_before = Store.get("puzzle_angle")
homeTile("Puzzles by opening").callback()
run(nil, 0.5)
local op_page = Fake.top()
check("openings listed, most played first", op_page.families and op_page.families[1].key == "Sicilian_Defense"
    and tile(op_page, "Sicilian Defense") ~= nil)
tile(op_page, "Sicilian Defense").callback()
local fam_page = Fake.top()
check("variations of the opening", fam_page.family and tile(fam_page, "Najdorf Variation") ~= nil
    and tile(fam_page, "All Sicilian Defense") ~= nil)
tile(fam_page, "Najdorf Variation").callback()
local opz = Fake.top()
run(function() return opz.mode == "play" end, 5)
check("puzzles from that opening", opz.title == "Sicilian Defense: Najdorf Variation"
    and angles_asked[#angles_asked] == "Sicilian_Defense_Najdorf_Variation")
opz:onClose()
check("the usual puzzle theme is back", Store.get("puzzle_angle") == angle_before)
fam_page:onClose()
op_page:onClose()

-- Openings (tabia's courses): learn, practice, drill with spaced repetition, hyper
local Repertoire = require("chessuite/repertoire")
check("14 openings, 78 lines", #Repertoire.openings() == 14)
local total_lines = 0
for _, rop in ipairs(Repertoire.openings()) do
    for _, l in ipairs(rop.lines) do
        total_lines = total_lines + 1
        local lg = require("chessuite/chess").new()
        for _, mv in ipairs(l.moves) do
            if not lg:move(mv[1]) then check("legal: " .. rop.id .. " " .. l.id .. " " .. mv[1], false) break end
        end
    end
end
check("all lines legal", total_lines == 78)
Store.set("repertoire_srs", nil)
local it = Repertoire.opening("italian")
local t0 = 1000000
local st = Repertoire.record("italian", "evans", true, t0)
check("a clean line comes back in a day", st.box == 1 and st.due == t0 + 86400)
st = Repertoire.record("italian", "evans", false, t0)
check("a slip brings it back now", st.box == 0)
check("new lines first, then the weakest", Repertoire.pickNext("italian", { "evans", "two-knights" }, t0 + 1) ~= nil)
homeTile("Openings").callback()
run(nil, 0.3)
local rs = Fake.top()
check("openings page", rs.title == "Openings")
rs.category = "Classical"
rs:refresh()
tile(rs, "Italian Game").callback()
local course = Fake.top()
check("opening course", course.op and course.op.id == "italian" and tile(course, "★ Giuoco Pianissimo (c3/d3)") ~= nil)
-- learn: step through with the arrow showing the next move
course:train("learn", { "giuoco-pianissimo" })
local tr = Fake.top()
run(nil, 0.2)
check("learn shows the next move", tr.arrows and tr.arrows[1] and tr.ply == 0)
tr:learnStep(1)
tr:learnStep(1)
check("learn steps", tr.ply == 2 and tr.game:plyCount() == 2)
tr:onClose()
-- practice: a wrong move is taken back, the right one is answered
course:train("practice", { "giuoco-pianissimo" })
tr = Fake.top()
run(nil, 0.2)
tr:onBoardMove(tr.game:moveFromUci("d2d4"))
check("practice: wrong move not played", tr.game:plyCount() == 0 and tr.wrong == 1)
tr:onBoardMove(tr.game:moveFromUci("e2e4"))
run(function() return not tr.waiting end, 3)
check("practice: right move answered", tr.game:plyCount() == 2 and tr.correct == 1)
tr:onClose()
-- drill: play the whole line cleanly, it moves up a box
course:train("drill", { "evans" })
tr = Fake.top()
run(nil, 0.2)
local evans = Repertoire.line(it, "evans")
for i = 1, #evans.moves, 2 do
    run(function() return not tr.waiting end, 3)
    if tr.done then break end
    tr:onBoardMove(tr.game:moveFromSan(evans.moves[i][1]))
end
run(function() return tr.done end, 5)
print("   drill:", tr.feedback.title, tr.feedback.text)
check("drill: clean line recorded", tr.done and Repertoire.mastery("italian", "evans") == 1)
tr:onClose()
-- hyper: the trainer plays random lines as the opponent (Black repertoire: it opens)
local fr = Repertoire.opening("french")
local scope = {}
for _, l in ipairs(fr.lines) do scope[#scope + 1] = l.id end
local hy
UIManager:show(require("chessuite/ui/repertoirescreen").Trainer:new{ plugin = plugin, op = fr, mode = "hyper", scope = scope })
hy = Fake.top()
run(function() return not hy.waiting and hy.game:plyCount() == 1 end, 3)
check("hyper: the trainer opens for White", hy.game:plyCount() == 1)
for _ = 1, 20 do
    run(function() return not hy.waiting end, 3)
    if hy.done then break end
    local want = hy:hyperExpected()
    if not want then break end
    hy:hyperMove(want)
end
run(function() return hy.done end, 5)
check("hyper: round held", hy.done and hy.feedback.title == "You held the line!")
hy:onClose()
course:onClose()
rs:onClose()

-- My progress
homeTile("My progress").callback()
local sp = Fake.top()
check("progress page", sp.title == "My progress" and #Store.ratingHistory() > 0)
sp:onClose()

-- "Why?": a fork explained and stepped through on a board
local Explain = require("chessuite/explain")
local fg2 = require("chessuite/chess").new("6k1/5p1p/4p3/4q3/3nN3/2Q3P1/PP3P1P/6K1 w - - 2 37")
local fe = Explain.punishment(fg2, fg2:moveFromUci("e4d2"), { "d4e2", "g1f1", "e2c3" })
local wp = require("chessuite/ui/explainpage"):new{ plugin = plugin,
    parts = { { title = "What goes wrong", headline = fe.headline, text = fe.text, steps = fe.steps, start = fg2 } } }
UIManager:show(wp)
check("why page shows the move first", wp.step == 1 and wp.board.arrows[1].label == 1)
wp:go(2)
local dashed = 0
for _, a in ipairs(wp.board.arrows) do if a.dashed then dashed = dashed + 1 end end
check("the fork drawn on step 2", dashed == 2 and next(wp.board.marks) ~= nil)
check("why page paints", pcall(Fake.paint, wp[1]))
wp:togglePlay()
run(function() return not wp.playing end, 10)
check("play goes through to the end", wp.step == #fe.steps)
wp:onClose()

home:onClose()
check("home closed", #Fake.shown == 0)
run(nil, 3)
if failures > 0 then print(failures .. " failure(s)"); os.exit(1) end
print("all passed")
