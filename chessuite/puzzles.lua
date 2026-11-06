--[[
Lichess puzzles: a local cache of puzzles (so you can keep solving while
offline), the queue of results that still have to be sent to Lichess, and
turning a puzzle into a position.

Results are sent with POST /api/puzzle/batch/{angle}, which marks the
puzzles as played and updates your Lichess puzzle rating.
--]]

local Chess = require("chessuite/chess")
local Store = require("chessuite/store")

local Puzzles = {}

-- Themes offered in the picker (lichess "angles"), in plain words.
Puzzles.THEMES = {
    { id = "mix", name = "Healthy mix" },
    { id = "mateIn1", name = "Mate in 1" },
    { id = "mateIn2", name = "Mate in 2" },
    { id = "mateIn3", name = "Mate in 3" },
    { id = "fork", name = "Forks" },
    { id = "pin", name = "Pins" },
    { id = "skewer", name = "Skewers" },
    { id = "hangingPiece", name = "Hanging pieces" },
    { id = "discoveredAttack", name = "Discovered attacks" },
    { id = "backRankMate", name = "Back rank mates" },
    { id = "sacrifice", name = "Sacrifices" },
    { id = "promotion", name = "Promotion" },
    { id = "opening", name = "Opening" },
    { id = "middlegame", name = "Middlegame" },
    { id = "endgame", name = "Endgames" },
    { id = "short", name = "Short puzzles" },
    { id = "long", name = "Long puzzles" },
    { id = "defensiveMove", name = "Defensive moves" },
}

Puzzles.DIFFICULTIES = {
    { id = "easiest", name = "Easiest" },
    { id = "easier", name = "Easier" },
    { id = "normal", name = "Normal" },
    { id = "harder", name = "Harder" },
    { id = "hardest", name = "Hardest" },
}

function Puzzles.themeName(id)
    for _, t in ipairs(Puzzles.THEMES) do if t.id == id then return t.name end end
    return id
end

-- Builds the starting position of a puzzle (lichess PuzzleAndGame JSON).
-- Returns game, player colour, solution (list of UCI moves).
function Puzzles.toGame(entry)
    local p = entry.puzzle or {}
    local game
    local pgn = entry.game and entry.game.pgn
    if pgn and pgn ~= "" then
        game = Chess.new()
        local ok = game:playLine(pgn)
        if not ok then game = nil end
    end
    if not game and p.fen then
        game = Chess.new(p.fen)
    end
    if not game then return nil, "could not set up the puzzle" end
    return game, game.turn, p.solution or {}
end

-- Is `uci` an acceptable answer at this step? Any checkmate is accepted
-- (lichess does the same for puzzles with several mates).
function Puzzles.isCorrect(game, solution, step, uci)
    local expected = solution[step]
    if not expected then return false end
    local m = game:moveFromUci(uci)
    local e = game:moveFromUci(expected)
    if m and e and m.from == e.from and m.to == e.to and m.promotion == e.promotion then return true end
    if m then
        local g = game:clone()
        g:makeMove(m)
        if g:isCheckmate() then return true end
    end
    return false
end

-- Cache ----------------------------------------------------------------------

function Puzzles.cacheKey()
    return Store.get("puzzle_angle") .. "|" .. Store.get("puzzle_difficulty")
end

-- The cache keeps a queue per theme or opening (and difficulty), like the
-- Lichess app's saved batches, so puzzles by opening do not replace the others.
local MAX_QUEUES = 6

local function cacheTable()
    local cache = Store.puzzleCache()
    if cache.key then
        -- the older single-queue format
        cache = { by = { [cache.key] = cache.list or {} }, order = { cache.key } }
    end
    cache.by = cache.by or {}
    cache.order = cache.order or {}
    return cache
end

function Puzzles.cached()
    return cacheTable().by[Puzzles.cacheKey()] or {}
end

function Puzzles.setCached(list)
    local cache = cacheTable()
    local key = Puzzles.cacheKey()
    cache.by[key] = list
    -- the most recently used queue last; the oldest go when there are too many
    for i = #cache.order, 1, -1 do
        if cache.order[i] == key then table.remove(cache.order, i) end
    end
    cache.order[#cache.order + 1] = key
    while #cache.order > MAX_QUEUES do
        cache.by[table.remove(cache.order, 1)] = nil
    end
    Store.setPuzzleCache(cache)
end

-- Opening keys with puzzles kept for offline solving.
function Puzzles.cachedAngles()
    local out = {}
    for key, list in pairs(cacheTable().by) do
        local angle = key:match("^(.-)|")
        if angle and #list > 0 then out[angle] = #list end
    end
    return out
end

function Puzzles.take()
    local list = Puzzles.cached()
    local entry = table.remove(list, 1)
    Puzzles.setCached(list)
    return entry
end

local function merge(list, puzzles)
    local seen = {}
    for _, e in ipairs(list) do seen[e.puzzle.id] = true end
    for _, e in ipairs(puzzles or {}) do
        if e.puzzle and not seen[e.puzzle.id] then
            list[#list + 1] = e
            seen[e.puzzle.id] = true
        end
    end
end

-- How many puzzles to keep for offline solving (the server sends at most 50 at once).
function Puzzles.target() return Store.get("puzzle_queue") or 50 end

local function backingOff()
    return (Store.get("puzzle_backoff_until") or 0) > os.time()
end

local function noteError(code)
    -- too many requests: leave lichess alone for a while, like the app does
    if code == 429 then Store.set("puzzle_backoff_until", os.time() + 120) end
end

-- Fills the cache up to the target. Returns ok, err.
function Puzzles.refill(client, nb)
    if backingOff() then return false, "Lichess asked us to slow down, try again in a minute" end
    local list = Puzzles.cached()
    local want = nb or (Puzzles.target() - #list)
    while want > 0 do
        local ok, data, code = client:puzzleBatch(Store.get("puzzle_angle"), math.min(want, 50),
            Store.get("puzzle_difficulty"))
        if not ok then
            noteError(code)
            Puzzles.setCached(list)
            return #list > 0, data
        end
        local before = #list
        merge(list, type(data) == "table" and data.puzzles)
        if #list == before then break end
        want = want - (#list - before)
    end
    Puzzles.setCached(list)
    return true
end

-- Results ----------------------------------------------------------------------

-- Sends every queued result, and tops up the cache in the same request (as
-- the lichess app does). Returns ok, info where info has rating (new puzzle
-- rating) and diffs ({ [puzzle id] = rating change }).
function Puzzles.sync(client)
    local pending = Store.pendingResults()
    if #pending == 0 then return true, { diffs = {} } end
    if backingOff() then return false, "Lichess asked us to slow down, try again in a minute" end
    local by_angle, order = {}, {}
    for _, r in ipairs(pending) do
        local a = r.angle or "mix"
        if not by_angle[a] then by_angle[a] = {}; order[#order + 1] = a end
        table.insert(by_angle[a], { id = r.id, win = r.win and true or false, rated = r.rated ~= false })
    end
    local info = { diffs = {} }
    local left = {}
    local last_err
    local current = Store.get("puzzle_angle")
    for _, angle in ipairs(order) do
        local nb = 0
        if angle == current then nb = math.max(0, math.min(50, Puzzles.target() - #Puzzles.cached())) end
        local ok, data, code = client:solvePuzzles(angle, by_angle[angle], nb, Store.get("puzzle_difficulty"))
        if ok and type(data) == "table" then
            for _, round in ipairs(data.rounds or {}) do info.diffs[round.id] = round.ratingDiff end
            if data.glicko and data.glicko.rating then
                info.rating = math.floor(data.glicko.rating + 0.5)
                Store.set("puzzle_rating", info.rating)
            end
            if nb > 0 and data.puzzles then
                local list = Puzzles.cached()
                merge(list, data.puzzles)
                Puzzles.setCached(list)
            end
        else
            noteError(code)
            last_err = data
            for _, r in ipairs(pending) do
                if (r.angle or "mix") == angle then left[#left + 1] = r end
            end
        end
    end
    Store.setPendingResults(left)
    if #left > 0 then return false, last_err end
    return true, info
end

return Puzzles
