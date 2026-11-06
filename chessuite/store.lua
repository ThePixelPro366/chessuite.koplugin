--[[
Everything the plugin remembers, in <koreader settings dir>/chessuite.lua.
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Store = {}

local DEFAULTS = {
    show_legal_moves = true,
    show_coordinates = true,
    move_words = true,        -- "Knight to f3" instead of "Nf3" in move lists
    coach_level = "beginner", -- "beginner" or "normal"
    coach_comments = true,    -- the coach comments on your moves (Hint works either way)
    analysis_seconds = 8,     -- how long local analysis runs before it stops to save battery
    review_depth = 16,        -- search depth for game reviews
    review_cloud = true,      -- use the Lichess cloud evaluation in reviews when online
    review_source = "lichess", -- "lichess": Lichess' server analysis when logged in and online; "local"
    engine_threads = 1,
    engine_hash = 16,
    puzzle_angle = "mix",
    puzzle_difficulty = "normal",
    puzzle_rated = true,      -- send results as rated (a hint makes that puzzle unrated, like lichess)
    puzzle_auto_next = false, -- jump to the next puzzle right after solving one
    puzzle_queue = 50,        -- puzzles kept for offline solving
    board_dark = 0xAA,        -- grey level of the dark squares
    time_control = "none",    -- clock for games against bots, see Store.TIME_CONTROLS
    friend_flip = true,       -- in a game with a friend, turn the board to the side to move
}

-- Clocks for games against bots: minutes + seconds added per move.
Store.TIME_CONTROLS = {
    { id = "none", name = "No clock" },
    { id = "3+2", name = "3 + 2", base = 180, inc = 2 },
    { id = "5+3", name = "5 + 3", base = 300, inc = 3 },
    { id = "10+5", name = "10 + 5", base = 600, inc = 5 },
    { id = "15+10", name = "15 + 10", base = 900, inc = 10 },
    { id = "30+0", name = "30 min", base = 1800, inc = 0 },
}

function Store.timeControl(id)
    id = id or Store.get("time_control")
    for _, t in ipairs(Store.TIME_CONTROLS) do
        if t.id == id then return t.base and t or nil end
    end
    return nil
end

function Store.settings()
    if not Store._settings then
        Store._settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/chessuite.lua")
    end
    return Store._settings
end

function Store.get(key)
    local v = Store.settings():readSetting(key)
    if v == nil then return DEFAULTS[key] end
    return v
end

function Store.set(key, value)
    Store.settings():saveSetting(key, value)
    Store.settings():flush()
end

function Store.toggle(key)
    Store.set(key, not Store.get(key))
end

-- Your own rating -------------------------------------------------------------

Store.DEFAULT_RATING = 1200

function Store.playerRating()
    return Store.get("player_rating") or Store.DEFAULT_RATING
end

function Store.hasPlayerRating() return Store.get("player_rating") ~= nil end

function Store.setPlayerRating(r)
    r = math.max(100, math.min(3200, math.floor(r + 0.5)))
    Store.set("player_rating", r)
end

-- Elo update after a game against an opponent rated `opp` (score 1, 0.5 or 0).
-- Changes faster for the first 20 games, like a provisional rating.
function Store.ratePlayerGame(opp, score)
    local r = Store.playerRating()
    local n = Store.get("rated_games") or 0
    local k = n < 20 and 40 or 20
    local expected = 1 / (1 + 10 ^ ((opp - r) / 400))
    local new = math.max(100, math.floor(r + k * (score - expected) + 0.5))
    Store.set("player_rating", new)
    Store.set("rated_games", n + 1)
    Store.addRatingPoint(new)
    return new, new - r
end

-- Your rating after each rated game, for the chart on the progress page.
function Store.ratingHistory() return Store.get("rating_history") or {} end
function Store.addRatingPoint(r)
    local h = Store.ratingHistory()
    h[#h + 1] = { t = os.time(), r = r }
    while #h > 200 do table.remove(h, 1) end
    Store.set("rating_history", h)
end

-- Wins, draws and losses against bots, by your colour.
function Store.gameStats()
    return Store.get("game_stats") or { w = { won = 0, drawn = 0, lost = 0 }, b = { won = 0, drawn = 0, lost = 0 } }
end
function Store.recordGame(color, score)
    local st = Store.gameStats()
    local side = st[color] or { won = 0, drawn = 0, lost = 0 }
    if score == 1 then side.won = side.won + 1 elseif score == 0 then side.lost = side.lost + 1
    else side.drawn = side.drawn + 1 end
    st[color] = side
    Store.set("game_stats", st)
end

-- Best puzzle streak (the streak mode, not rated).
function Store.bestStreak() return Store.get("streak_best") or 0 end
function Store.noteStreak(n)
    if n > Store.bestStreak() then Store.set("streak_best", n); return true end
    return false
end

-- Lichess account -----------------------------------------------------------

function Store.token() return Store.get("lichess_token") end
function Store.username() return Store.get("lichess_username") end
function Store.isLoggedIn() return Store.token() ~= nil and Store.token() ~= "" end

function Store.logout()
    local s = Store.settings()
    s:delSetting("lichess_token")
    s:delSetting("lichess_username")
    s:delSetting("lichess_user_id")
    s:delSetting("puzzle_rating")
    s:delSetting("puzzle_cache")
    s:flush()
end

-- The Lichess website login handed over by the companion app (see pairing.lua).
-- It is a full login to the account: kept only here, removed with forgetWebSession().
function Store.webSession()
    local cookie = Store.get("lichess_web_cookie")
    if not cookie or cookie == "" then return nil end
    return { cookie = cookie, user = Store.get("lichess_web_user"), ua = Store.get("lichess_web_ua") }
end

function Store.setWebSession(cookie, user, ua)
    Store.set("lichess_web_cookie", cookie)
    Store.set("lichess_web_user", user)
    Store.set("lichess_web_ua", ua)
end

function Store.forgetWebSession()
    local s = Store.settings()
    s:delSetting("lichess_web_cookie")
    s:delSetting("lichess_web_user")
    s:delSetting("lichess_web_ua")
    s:flush()
end

-- Puzzles kept for offline solving, and results waiting to be sent.
function Store.puzzleCache() return Store.get("puzzle_cache") or {} end
function Store.setPuzzleCache(list) Store.set("puzzle_cache", list) end

function Store.pendingResults() return Store.get("puzzle_pending") or {} end
function Store.setPendingResults(list) Store.set("puzzle_pending", list) end

function Store.addPendingResult(angle, result)
    local pending = Store.pendingResults()
    pending[#pending + 1] = { angle = angle, id = result.id, win = result.win, rated = result.rated ~= false }
    Store.setPendingResults(pending)
end

-- Local puzzle statistics (also kept when offline).
function Store.puzzleStats()
    return Store.get("puzzle_stats") or { solved = 0, failed = 0, streak = 0, best_streak = 0 }
end

function Store.recordPuzzle(win)
    local st = Store.puzzleStats()
    if win then
        st.solved = st.solved + 1
        st.streak = st.streak + 1
        if st.streak > st.best_streak then st.best_streak = st.streak end
    else
        st.failed = st.failed + 1
        st.streak = 0
    end
    Store.set("puzzle_stats", st)
    return st
end

-- Games ---------------------------------------------------------------------

-- The unfinished game, so it can be continued later.
function Store.savedGame() return Store.get("saved_game") end
function Store.saveGame(t) Store.set("saved_game", t) end
function Store.clearSavedGame()
    Store.settings():delSetting("saved_game")
    Store.settings():flush()
end

-- The last finished games (PGN), newest first, for analysis.
function Store.recentGames() return Store.get("recent_games") or {} end
function Store.addRecentGame(entry)
    local list = Store.recentGames()
    table.insert(list, 1, entry)
    while #list > 20 do table.remove(list) end
    Store.set("recent_games", list)
end

function Store.gamesDir()
    local dir = DataStorage:getDataDir() .. "/chessuite"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    return dir
end

return Store
