-- Run with: luajit spec/chess_spec.lua  (from the plugin directory)
package.path = "./?.lua;" .. package.path
local Chess = require("chessuite/chess")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    else
        print("ok   " .. name)
    end
end

-- perft numbers from https://www.chessprogramming.org/Perft_Results
local perfts = {
    { Chess.START_FEN, { 20, 400, 8902, 197281 } },
    { "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", { 48, 2039, 97862 } },
    { "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", { 14, 191, 2812, 43238 } },
    { "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", { 6, 264, 9467 } },
    { "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", { 44, 1486, 62379 } },
}
for i, t in ipairs(perfts) do
    local g = Chess.new(t[1])
    for d, n in ipairs(t[2]) do check(("perft %d depth %d"):format(i, d), g:perft(d), n) end
end

local g = Chess.new()
for _, m in ipairs({ "e4", "e5", "Nf3", "Nc6", "Bc4", "Nf6", "O-O", "Bc5" }) do assert(g:move(m), m) end
check("castle fen", g:fen(), "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQ1RK1 w kq - 6 5")
check("pgn movetext", g:moveText(), "1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. O-O Bc5")

g = Chess.new()
g:playLine("f3 e5 g4 Qh4")
check("fool's mate san", g:lastMove().san, "Qh4#")
check("fool's mate result", select(2, g:gameResult()), "checkmate")

g = Chess.new("rn5r/ppp3pp/2kbQn2/8/2N1p3/1P2B3/P1P2PPP/qN2K2R w K - 0 1")
check("uci king-takes-rook castling", g:moveFromUci("e1h1").flags, "castle_k")
check("promotion san", Chess.new("8/P6k/8/8/8/8/8/K7 w - - 0 1"):san(Chess.new("8/P6k/8/8/8/8/8/K7 w - - 0 1"):moveFromUci("a7a8q")), "a8=Q")

-- disambiguation
g = Chess.new("4k3/8/8/8/8/8/4K3/R6R w - - 0 1")
check("rook disambiguation", g:san(g:moveFromUci("a1d1")), "Rad1")

-- lichess puzzle: replay pgn
g = Chess.new()
local ok = g:playLine("e4 e5 Nf3 d5 Nxe5 dxe4 Bc4 Be6 Bxe6 fxe6 Qh5+ Ke7 d4 Qxd4 b3 Nf6 Qf7+ Kd6 Nc4+ Kc6 Qxe6+ Bd6 Be3 Qxa1")
check("puzzle replay", ok, true)
check("puzzle fen", g:fen(), "rn5r/ppp3pp/2kbQn2/8/2N1p3/1P2B3/P1P2PPP/qN2K2R w K - 0 13")

-- threefold
g = Chess.new()
g:playLine("Nf3 Nf6 Ng1 Ng8 Nf3 Nf6 Ng1 Ng8")
check("threefold", select(2, g:gameResult()), "threefold repetition")
g:undo()
check("undo threefold", g:gameResult(), nil)
g:move("Ng8")
check("threefold must be claimed", g:gameResult({ no_claims = true }), nil)
check("threefold claimable", g:claimableDraw(), "threefold repetition")
g:playLine("Nf3 Nf6 Ng1 Ng8 Nf3 Nf6 Ng1 Ng8")
check("fivefold is automatic", select(2, g:gameResult({ no_claims = true })), "fivefold repetition")

-- PGN round trip
g = Chess.fromPgn('[Event "x"]\n1. e4 {comment} e5 (1... c5 2. Nf3) 2. Nf3 Nc6 3. Bb5 a6 *')
check("pgn parse", g and g:moveText(), "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6")

check("insufficient", select(2, Chess.new("8/8/8/4k3/8/8/2B5/4K3 w - - 0 1"):gameResult()), "insufficient material")
check("stalemate", select(2, Chess.new("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"):gameResult()), "stalemate")

if failures > 0 then print(failures .. " failure(s)"); os.exit(1) end
print("all passed")
