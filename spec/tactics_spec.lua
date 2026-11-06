-- The Lua port of the Lichess puzzle tagger (chessuite/tactics.lua) against
-- 600 puzzles from the Lichess puzzle database (CC0, database.lichess.org)
-- and the themes Lichess gave them. Run from the plugin dir:
--     luajit spec/tactics_spec.lua
package.path = "./spec/stubs/?.lua;./?.lua;" .. package.path
local Chess = require("chessuite/chess")
local Tactics = require("chessuite/tactics")
local Explain = require("chessuite/explain")

local failures = 0
local function check(name, cond)
    print((cond and "ok   " or "FAIL ") .. name)
    if not cond then failures = failures + 1 end
end

local THEMES = { "fork", "pin", "skewer", "discoveredAttack", "hangingPiece", "trappedPiece", "doubleCheck",
    "backRankMate", "smotheredMate", "deflection", "attraction", "capturingDefender", "promotion", "mate" }
local stat = {}
for _, t in ipairs(THEMES) do stat[t] = { tp = 0, fp = 0, fn = 0 } end
local puzzles = {}
local f = assert(io.open("spec/fixtures/lichess_puzzles.csv"))
f:read("*l")
for line in f:lines() do
    local id, fen, moves, themes = line:match("^([^,]*),([^,]*),([^,]*),(.*)$")
    local ucis = {}
    for u in moves:gmatch("%S+") do ucis[#ucis + 1] = u end
    puzzles[#puzzles + 1] = { id = id, fen = fen, ucis = ucis, themes = themes }
    local r = Tactics.analyse(Chess.new(fen), ucis)
    local got, want = {}, {}
    for _, t in ipairs(r.tags) do got[t] = true end
    if got.discoveredCheck then got.discoveredAttack = true end
    for t in themes:gmatch("%S+") do want[t] = true end
    for _, t in ipairs(THEMES) do
        local s = stat[t]
        if got[t] and want[t] then s.tp = s.tp + 1
        elseif got[t] then s.fp = s.fp + 1
        elseif want[t] then s.fn = s.fn + 1 end
    end
end
f:close()
for _, t in ipairs(THEMES) do
    local s = stat[t]
    local precision = s.tp / math.max(1, s.tp + s.fp)
    local recall = s.tp / math.max(1, s.tp + s.fn)
    print(string.format("   %-18s precision %5.1f%%  recall %5.1f%%  (%d)", t, precision * 100, recall * 100, s.tp + s.fn))
    check(t .. " found like Lichess", precision >= 0.93 and recall >= 0.97)
end

-- explanations: a fork puzzle explained, with the line to step through
for _, p in ipairs(puzzles) do
    if p.themes:find("fork") and not p.themes:find("mate") then
        local g = Chess.new(p.fen)
        local m = g:moveFromUci(p.ucis[1])
        local rest = {}
        for i = 2, #p.ucis do rest[#rest + 1] = p.ucis[i] end
        local e = Explain.punishment(g, m, rest)
        print("   " .. p.id .. ": " .. e.headline .. " / " .. e.text)
        check("fork explained", e.headline == "it walks into a fork" and e.text:find("at the same time") ~= nil)
        local key
        for _, s in ipairs(e.steps) do
            for _, a in ipairs(s.arrows) do if a.dashed then key = s end end
        end
        check("the fork drawn: dashed arrows to the forked pieces, rings around them", key ~= nil
            and next(key.marks) ~= nil)
        check("steps start with the move itself", e.steps[1].arrows[1].label == 1 and #e.steps >= 2)
        break
    end
end
for _, p in ipairs(puzzles) do
    if p.themes:find("mateIn2") then
        local g = Chess.new(p.fen)
        local m = g:moveFromUci(p.ucis[1])
        local rest = {}
        for i = 2, #p.ucis do rest[#rest + 1] = p.ucis[i] end
        local e = Explain.punishment(g, m, rest)
        print("   " .. p.id .. ": " .. e.headline)
        check("mate in 2 explained and shown to the end", e.mate == 2 and #e.steps == 4
            and e.steps[4].game:isCheckmate())
        -- the same line as an idea, from the side that mates
        local after = g:clone()
        after:makeMove(m)
        local idea = Explain.idea(after, rest)
        print("   idea: " .. idea.headline)
        check("the winning idea", idea.mate == 2 and idea.headline:find("checkmate in 2") ~= nil)
        break
    end
end

if failures > 0 then print(failures .. " failure(s)"); os.exit(1) end
print("all passed")
