-- Plays against the real bundled Stockfish (x86_64) through the plugin's
-- UCI bridge, bots and coach. Run from the plugin directory:
--     luajit spec/engine_spec.lua
package.path = "./spec/stubs/?.lua;./?.lua;" .. package.path
math.randomseed(42)
local UIManager = require("ui/uimanager")
local Engine = require("chessuite/uci")
local Chess = require("chessuite/chess")
local Bots = require("chessuite/bots")
local Coach = require("chessuite/coach")
local Describe = require("chessuite/describe")

local engine = Engine:new{ path = "./bin/" .. Engine.bundledBinaryName() }
engine.maia = Engine:new{ path = "./bin/" .. Engine.bundledBinaryName("maia3") }
local failures = 0
local function check(name, cond)
    print((cond and "ok   " or "FAIL ") .. name)
    if not cond then failures = failures + 1 end
end

-- 1. plain search with multipv
local result
engine:search({ fen = Chess.START_FEN, depth = 10, multipv = 3 }, nil, function(r) result = r end)
UIManager:run(function() return result end, 20)
check("search returns bestmove", result and result.bestmove ~= nil)
check("multipv 3 lines", result and #result.lines == 3)

-- 2. cancel a running search, the next one must still answer
local got_first, second
engine:search({ fen = Chess.START_FEN, infinite = true }, nil, function() got_first = true end)
engine:search({ fen = "rn5r/ppp3pp/2kbQn2/8/2N1p3/1P2B3/P1P2PPP/qN2K2R w K - 0 1", depth = 12 }, nil,
    function(r) second = r end)
UIManager:run(function() return second end, 20)
check("cancelled search callback not called", not got_first)
check("puzzle mate found (c4a5)", second and second.bestmove == "c4a5")
check("mate score", second and second.lines[1].mate == 3)

-- 3. every bot plays a legal move
local g = Chess.new()
g:playLine("e4 e5 Nf3 Nc6 Bc4")
for _, b in ipairs(Bots.ROSTER) do
    if b.id ~= "stockfish" and b.id ~= "kai" and b.id ~= "arjun" then
        local mv, source
        Bots.chooseMove(engine, g, b, function(u, info) mv = u or "none"; source = info and info.source end)
        UIManager:run(function() return mv end, 30)
        check("bot " .. b.id .. " plays legal move " .. tostring(mv), mv and g:moveFromUci(mv) ~= nil)
        if b.maia then check("bot " .. b.id .. " plays with Maia3", source == "maia") end
    end
end

-- 3b. Maia3: human move probabilities that depend on the rating
local function maiaLines(fen, elo)
    local r
    local pos = Chess.new(fen)
    local ucis = {}
    for i, m in ipairs(pos:moves()) do ucis[i] = Chess.uci(m) end
    engine.maia:search({ fen = fen, depth = 1, multipv = #ucis, searchmoves = ucis, options = { Elo = elo } }, nil,
        function(x) r = x end)
    UIManager:run(function() return r end, 20)
    return r and r.lines or {}
end
local back_rank = "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1"
local strong, weak = maiaLines(back_rank, 1500), maiaLines(back_rank, 100)
check("maia lists every legal move", #strong == #Chess.new(back_rank):moves())
check("maia 1500 sees the back-rank mate", strong[1].pv[1] == "d1d8" and strong[1].prob > 0.8)
check("maia 100 often misses it", weak[1].prob < 0.5)
local sum = 0
for _, l in ipairs(weak) do sum = sum + l.prob end
check("maia probabilities add up to 1", math.abs(sum - 1) < 0.01)
local sf300 = Bots.stockfishAt(300)
check("plain engine below 1000 is Maia", sf300.maia and sf300.name == "Maia" and not Bots.stockfishAt(1200).maia)

-- 3c. without a working Maia3 binary the beginner bots still play (Stockfish fallback)
local real_maia = engine.maia
engine.maia = Engine:new{ path = "./bin/does-not-exist" }
local fb, fb_source
Bots.chooseMove(engine, g, Bots.BY_ID.pip, function(u, info) fb = u or "none"; fb_source = info and info.source end)
UIManager:run(function() return fb end, 30)
check("fallback move without Maia3 " .. tostring(fb), fb and g:moveFromUci(fb) ~= nil and fb_source ~= "maia")
check("broken Maia3 is remembered", engine.maia.failed)
engine.maia = real_maia
local lvl
Bots.chooseMove(engine, g, Bots.levelBot(1), function(u) lvl = u end)
UIManager:run(function() return lvl end, 10)
check("level 1 legal move", lvl and g:moveFromUci(lvl) ~= nil)

-- 4. the coach
local function analyse(fen, mpv)
    local r
    engine:search({ fen = fen, depth = 12, multipv = mpv or 2 }, nil, function(x) r = x end)
    UIManager:run(function() return r end, 20)
    return r
end
local function judge(pos, uci)
    local before = analyse(pos:fen())
    local mv = pos:moveFromUci(uci)
    local g2 = pos:clone()
    g2:makeMove(mv)
    local after = analyse(g2:fen())
    local j = Coach.classify(pos, mv, before, after)
    return j, Coach.explain(pos, mv, before, after, j), before,
        Coach.explain(pos, mv, before, after, j, nil, { hide_best = true })
end

local pos = Chess.new()
pos:playLine("e4 e5 Nf3 Nc6 Bc4 Nf6")
local j, text = judge(pos, "e1g1")
print("   O-O:", j.class, text)
check("castling is not a mistake", j.class ~= "mistake" and j.class ~= "blunder")

local p2 = Chess.new()
p2:playLine("e4 e5 Qh5 Nc6 Bc4")
local j2, t2, b2 = judge(p2, "g8f6")
print("   Nf6??:", j2.class, t2)
check("Nf6 is a blunder", j2.class == "blunder")
check("mentions checkmate", t2:find("checkmate in one move") ~= nil or t2:find("checkmate you right away") ~= nil)
check("no SAN in text", not t2:find("Nf6") and not t2:find("Qxf7"))

local p3 = Chess.new()
p3:playLine("e4 d5")
local j3, t3 = judge(p3, "d1g4")
print("   Qg4??:", j3.class, t3)
check("Qg4 is a blunder", j3.class == "blunder")
check("mentions unprotected queen", t3:find("leaves your queen unprotected") ~= nil
    or t3:find("queen on g4 unprotected") ~= nil)

print("   hint 1:", Coach.hint(p2, b2.lines[1], 1))
print("   hint 2:", Coach.hint(p2, b2.lines[1], 2))
print("   hint 3:", Coach.hint(p2, b2.lines[1], 3))
local w = Chess.new("r1bqkbnr/pppp1ppp/2n5/4p2Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 2 3")
print("   warn:", Coach.warnAbout(w, w:moveFromUci("f1c4")))
local pr = Chess.new("4k3/P7/8/8/8/8/8/4K3 w - - 0 1")
print("   describe:", Describe.move(pr, pr:moveFromUci("a7a8q")))

-- lichess cloud scores are from White's side
local Lichess = require("chessuite/lichess")
local cl = Lichess.cloudLines({ depth = 40, pvs = { { moves = "e7e5 g1f3", cp = 22 }, { moves = "c7c5", mate = 3 } } }, "b")
check("cloud lines turned to side to move", cl[1].cp == -22 and cl[2].mate == -3 and cl[1].pv[2] == "g1f3")
check("cost words", Coach.costWords(150) == "you lose about 1.5 pawns of advantage" and Coach.costWords(30) == nil)

-- every problem move gets a reason
for _, case in ipairs({ { "e4 Nc6", "d1h5" }, { "d4 d5 c4 e6 Nc3 Nf6", "c4d5" }, { "e4 e5 Nf3 Nc6", "f3g5" } }) do
    local p = Chess.new()
    p:playLine(case[1])
    local jj, tt, _, hidden = judge(p, case[2])
    print("   " .. case[2] .. ":", jj.class, tt)
    print("   in game:", hidden)
    check("in-game comment names no better move for " .. case[2],
        not hidden:find("better") and not hidden:find("plan") and not hidden:find("liked"))
    if Coach.PROBLEMS[jj.class] then
        check("reason given for " .. case[2], tt:find("The problem") or tt:find("Why:") or tt:find("checkmate")
            or tt:find(" is [^:]+: it ") or tt:find(" is [^:]+: your ") or tt:find(" is [^:]+: a "))
    end
end

-- Stockfish 11's evaluation terms, and a positional reason from them
local terms_done
engine:evalTerms("r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4", function(t) terms_done = t end)
UIManager:run(function() return terms_done ~= nil end, 10)
check("eval terms from Stockfish 11", terms_done and terms_done["King safety"] and terms_done["Mobility"]
    and terms_done["King safety"].white[1] ~= nil)
local pk = Chess.new("r1bq1rk1/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQ1RK1 w - - 1 6")
local pmove = pk:moveFromUci("g2g4")
local pg = pk:clone()
pg:makeMove(pmove)
local tb, ta
engine:evalTerms(pk:fen(), function(t) tb = t end)
UIManager:run(function() return tb ~= nil end, 10)
engine:evalTerms(pg:fen(), function(t) ta = t end)
UIManager:run(function() return ta ~= nil end, 10)
local Positional = require("chessuite/positional")
local reason = Positional.worst(tb, ta, "w", pg)
print("   g4 weakens:", reason and reason.term, reason and reason.words, reason and reason.loss)
check("pawn storm in front of the own king weakens it", reason and reason.term == "King safety")
local ptext, ppart = Coach.addPositional("Pawn to g4 is a mistake.", pk, pmove, nil, tb, ta)
print("   positional:", ptext)
check("positional reason in the text", ptext and ptext:find("^Pawn to g4 is a mistake: it weakens your king") ~= nil
    and ppart and #ppart.steps >= 1)

engine:quit()
engine.maia:quit()
UIManager:run(nil, 3)
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
