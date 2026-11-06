-- Puzzle logic against a fake Lichess client. Run: luajit spec/puzzles_spec.lua
package.path = "./spec/stubs/?.lua;./?.lua;" .. package.path
local Puzzles = require("chessuite/puzzles")
local Store = require("chessuite/store")
local failures = 0
local function check(name, cond) print((cond and "ok   " or "FAIL ") .. name); if not cond then failures = failures + 1 end end

local daily = { game = { pgn = "e4 e5 Nf3 d5 Nxe5 dxe4 Bc4 Be6 Bxe6 fxe6 Qh5+ Ke7 d4 Qxd4 b3 Nf6 Qf7+ Kd6 Nc4+ Kc6 Qxe6+ Bd6 Be3 Qxa1" },
    puzzle = { id = "Ba42D", solution = { "c4a5", "c6b5", "e6c4", "b5a5", "c4a4" } } }
local g, color, sol = Puzzles.toGame(daily)
check("puzzle from pgn", g and color == "w" and #sol == 5)
check("last move highlighted is opponent's", g:lastMove() and require("chessuite/chess").uci(g:lastMove()) == "d4a1")
check("correct first move", Puzzles.isCorrect(g, sol, 1, "c4a5"))
check("wrong move", not Puzzles.isCorrect(g, sol, 1, "e6e4"))
-- an alternative checkmate is accepted
local Chess = require("chessuite/chess")
local m1 = Chess.new("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1")
check("alternative mate accepted", Puzzles.isCorrect(m1, { "a1a8" }, 1, "a1a8"))

-- fen fallback
local g2 = Puzzles.toGame({ puzzle = { fen = "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", solution = { "a1a8" } } })
check("fen fallback", g2 and g2:fen():find("^6k1") ~= nil)

-- cache + sync with a fake client
local sent
local client = {
    puzzleBatch = function(_, angle, nb, diff) return true, { puzzles = { daily, { puzzle = { id = "x2", solution = {} }, game = { pgn = "e4" } } } } end,
    solvePuzzles = function(_, angle, sols) sent = { angle = angle, sols = sols }
        return true, { rounds = { { id = "Ba42D", win = true, ratingDiff = 9 } }, glicko = { rating = 1532.4 } } end,
}
check("refill", Puzzles.refill(client) and #Puzzles.cached() == 2)
Puzzles.refill(client)
check("no duplicates", #Puzzles.cached() == 2)
check("take", Puzzles.take().puzzle.id == "Ba42D" and #Puzzles.cached() == 1)
-- one queue per theme or opening: another angle does not replace this one
local keep = #Puzzles.cached()
Store.set("puzzle_angle", "Sicilian_Defense")
check("new angle starts empty", #Puzzles.cached() == 0)
Puzzles.setCached({ { puzzle = { id = "sic1" } } })
check("cached angles listed", Puzzles.cachedAngles().Sicilian_Defense == 1)
Store.set("puzzle_angle", "mix")
check("the first queue is still there", #Puzzles.cached() == keep)
Store.addPendingResult("mix", { id = "Ba42D", win = true })
local ok, info = Puzzles.sync(client)
check("sync ok", ok and info.rating == 1532 and info.diffs.Ba42D == 9)
check("sent as json-ready list", sent.angle == "mix" and sent.sols[1].id == "Ba42D" and sent.sols[1].rated == true)
check("queue emptied", #Store.pendingResults() == 0)
-- failed sync keeps the queue
Store.addPendingResult("fork", { id = "y", win = false })
client.solvePuzzles = function() return false, "network error" end
ok = Puzzles.sync(client)
check("failed sync keeps results", not ok and #Store.pendingResults() == 1)

if failures > 0 then print(failures .. " failure(s)"); os.exit(1) end
print("all passed")
