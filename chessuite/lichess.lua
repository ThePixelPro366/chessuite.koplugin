--[[
Minimal lichess.org API client (https://lichess.org/api).

Authentication uses a personal API token. The account screen shows a QR
code that opens the token creation page with the needed scopes preselected,
so the token can be created on a phone and typed (or put in a file) on the
e-reader.
--]]

local logger = require("logger")

local Lichess = {}
Lichess.__index = Lichess

Lichess.BASE = "https://lichess.org"
-- Lichess asks API clients to say who they are.
Lichess.USER_AGENT = "Chessuite (KOReader plugin; +https://github.com/ThePixelPro366/chessuite.koplugin)"
Lichess.SCOPES = { "puzzle:read", "puzzle:write" }

local function urlEncode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end
Lichess.urlEncode = urlEncode

function Lichess.tokenCreateUrl()
    local parts = {}
    for _, s in ipairs(Lichess.SCOPES) do parts[#parts + 1] = "scopes[]=" .. urlEncode(s) end
    parts[#parts + 1] = "description=" .. urlEncode("KOReader Chessuite")
    return Lichess.BASE .. "/account/oauth/token/create?" .. table.concat(parts, "&")
end

-- Request log --------------------------------------------------------------
-- Every request is noted (never the token) so failures can be read in the
-- "Lichess log" page and in <koreader dir>/chessuite-lichess.log.

Lichess.LOG = {}
local LOG_MAX = 60

local function snippet(s, n)
    s = tostring(s or ""):gsub("%s+", " ")
    if #s > n then s = s:sub(1, n) .. "…" end
    return s
end

function Lichess.logFile()
    local ok, DataStorage = pcall(require, "datastorage")
    return ok and (DataStorage:getDataDir() .. "/chessuite-lichess.log") or nil
end

function Lichess.addLog(entry)
    entry.time = os.date("%Y-%m-%d %H:%M:%S")
    table.insert(Lichess.LOG, 1, entry)
    while #Lichess.LOG > LOG_MAX do table.remove(Lichess.LOG) end
    local path = Lichess.logFile()
    local f = path and io.open(path, "a")
    if f then
        f:write(Lichess.formatLogEntry(entry), "\n")
        f:close()
    end
end

function Lichess.formatLogEntry(e)
    local t = e.time .. "  " .. e.method .. " " .. e.path
        .. (e.web and " (website login)" or e.auth and " (with token)" or " (no token)")
        .. "\n  -> " .. (e.code and ("HTTP " .. e.code) or "no answer")
    if e.err then t = t .. "  " .. e.err end
    if e.body and e.body ~= "" then t = t .. "\n  answer: " .. e.body end
    return t
end

function Lichess.logText()
    if #Lichess.LOG == 0 then return "No requests to Lichess yet." end
    local out = {}
    for _, e in ipairs(Lichess.LOG) do out[#out + 1] = Lichess.formatLogEntry(e) end
    return table.concat(out, "\n\n")
end

function Lichess.clearLog()
    Lichess.LOG = {}
    local path = Lichess.logFile()
    if path then os.remove(path) end
end

function Lichess:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

local function queryString(query)
    if not query then return "" end
    local parts = {}
    for k, v in pairs(query) do
        if v ~= nil then parts[#parts + 1] = urlEncode(k) .. "=" .. urlEncode(v) end
    end
    table.sort(parts)
    return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

-- KOReader's JSON decoder turns null into a special value (a function):
-- remove those, so a missing field is simply nil ("opening": null at the start
-- position of the opening explorer made indexing it crash).
local function stripNulls(v, depth)
    if type(v) ~= "table" or (depth or 0) > 20 then return v end
    local nulls = {}
    for k, x in pairs(v) do
        if type(x) == "function" or type(x) == "userdata" then
            nulls[#nulls + 1] = k
        elseif type(x) == "table" then
            stripNulls(x, (depth or 0) + 1)
        end
    end
    for _, k in ipairs(nulls) do v[k] = nil end
    return v
end
Lichess.stripNulls = stripNulls

-- Returns ok, decoded_json_or_text, http_code
function Lichess:request(method, path, opts)
    opts = opts or {}
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local JSON = require("json")

    local sink = {}
    local headers = { ["Accept"] = opts.accept or "application/json", ["User-Agent"] = Lichess.USER_AGENT }
    if opts.web then
        -- the website login from the companion app, sent the way lichess.org's own pages do
        -- (Lichess refuses changes without an Origin header from lichess.org)
        local session = opts.web
        headers["Cookie"] = "lila2=" .. session.cookie
        headers["Origin"] = Lichess.BASE
        headers["Referer"] = Lichess.BASE .. "/"
        -- like a script on lichess.org; plain page loads (GET) are left as they are
        if method ~= "GET" then headers["X-Requested-With"] = "XMLHttpRequest" end
        if session.ua and session.ua ~= "" then headers["User-Agent"] = session.ua end
    elseif self.token and self.token ~= "" and not opts.anonymous then
        headers["Authorization"] = "Bearer " .. self.token
    end
    local body
    if opts.json then
        body = JSON.encode(opts.json)
        headers["Content-Type"] = "application/json"
    elseif opts.form then
        local parts = {}
        for k, v in pairs(opts.form) do parts[#parts + 1] = urlEncode(k) .. "=" .. urlEncode(v) end
        body = table.concat(parts, "&")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elseif opts.body then
        body = opts.body
        headers["Content-Type"] = "text/plain"
    end
    if body then headers["Content-Length"] = tostring(#body) end
    local request = {
        url = (opts.base or Lichess.BASE) .. path .. queryString(opts.query),
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
        source = body and ltn12.source.string(body) or nil,
    }
    logger.dbg("chessuite lichess:", method, request.url)
    local entry = { method = method, path = path .. queryString(opts.query), auth = headers["Authorization"] ~= nil,
        web = opts.web ~= nil }
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if resp_headers == nil then
        logger.warn("chessuite lichess: network error", status or code)
        entry.err = "network error: " .. tostring(status or code)
        Lichess.addLog(entry)
        return false, entry.err, nil
    end
    local content = table.concat(sink)
    local data = content
    local first = content:match("^%s*(.)")
    if first == "{" or first == "[" then
        local ok, decoded = pcall(JSON.decode, content)
        if ok then data = stripNulls(decoded) end
    end
    entry.code = code
    -- a short look at the answer; puzzle batches and games are long, keep the start
    entry.body = snippet(content, 300)
    if code == 200 or code == 201 or code == 204 then
        Lichess.addLog(entry)
        return true, data, code
    end
    local err = "HTTP " .. tostring(code)
    if type(data) == "table" and data.error then
        err = err .. ": " .. tostring(data.error)
    elseif content ~= "" then
        err = err .. ": " .. snippet(content, 120)
    end
    if code == 401 then err = err .. " (the token is invalid, expired or lacks a permission)" end
    if code == 429 then err = err .. " (too many requests, wait a minute)" end
    entry.err = err
    Lichess.addLog(entry)
    logger.warn("chessuite lichess: request failed", code, content:sub(1, 200))
    return false, err, code
end

function Lichess:account()
    return self:request("GET", "/api/account")
end

-- Returns ok, table of token -> {scopes = "a,b", userId = ...}
function Lichess:testToken(token)
    return self:request("POST", "/api/token/test", { body = token, anonymous = true })
end

function Lichess:puzzleBatch(angle, nb, difficulty)
    return self:request("GET", "/api/puzzle/batch/" .. urlEncode(angle or "mix"), {
        query = { nb = nb or 10, difficulty = difficulty },
    })
end

-- The openings that have puzzles, like the Lichess app's "By openings":
-- { openings = { { family = { key, name, count }, openings = { { key, name, count } } } } }
-- A key works as the angle of puzzleBatch.
function Lichess:puzzleOpenings()
    return self:request("GET", "/training/openings", { anonymous = true })
end

-- solutions: list of { id = "...", win = true/false, rated = true }
function Lichess:solvePuzzles(angle, solutions, nb, difficulty)
    return self:request("POST", "/api/puzzle/batch/" .. urlEncode(angle or "mix"), {
        query = { nb = nb or 0, difficulty = difficulty },
        json = { solutions = solutions },
    })
end

function Lichess:puzzleDaily()
    return self:request("GET", "/api/puzzle/daily", { anonymous = true })
end

function Lichess:puzzleDashboard(days)
    return self:request("GET", "/api/puzzle/dashboard/" .. (days or 30))
end

function Lichess:cloudEval(fen, multipv)
    return self:request("GET", "/api/cloud-eval", {
        query = { fen = fen, multiPv = multipv or 3 },
        anonymous = true,
    })
end

-- Turns a cloud-eval answer into engine lines like the local engine gives:
-- lichess scores are from White's side, ours from the side to move.
function Lichess.cloudLines(data, turn)
    if type(data) ~= "table" or type(data.pvs) ~= "table" then return nil end
    local sign = turn == "b" and -1 or 1
    local lines = {}
    for i, pv in ipairs(data.pvs) do
        local moves = {}
        for u in (pv.moves or ""):gmatch("%S+") do moves[#moves + 1] = u end
        lines[i] = {
            cp = pv.cp and pv.cp * sign or nil,
            mate = pv.mate and pv.mate * sign or nil,
            pv = moves,
            depth = data.depth,
            multipv = i,
            cloud = true,
        }
    end
    return #lines > 0 and lines or nil
end

-- Imports a PGN; returns ok, { id = ..., url = ... }
function Lichess:importGame(pgn)
    return self:request("POST", "/api/import", { form = { pgn = pgn } })
end

-- Asks Lichess for its server analysis of a game, like the "Request a
-- computer analysis" button. Lichess only accepts this from its website or
-- official app, so it needs the website login from the companion app.
-- An "already analysed" answer counts as success.
function Lichess:requestAnalysis(id, session)
    if not session then return false, "no Lichess website login (connect the companion app)", nil end
    local ok, data, code = self:request("POST", "/game/" .. urlEncode(id) .. "/request-analysis", { web = session })
    if not ok and type(data) == "string" and data:lower():find("already analysed") then return true, data, code end
    return ok, data, code
end

-- Checks the website login: returns ok, username.
-- The token API (/api/account) ignores website logins, so this loads the home
-- page like a browser and reads the name Lichess shows when logged in (#user_tag).
function Lichess:webAccount(session)
    local ok, data = self:request("GET", "/", { web = session, accept = "text/html" })
    if not ok then return false, data end
    local name = type(data) == "string" and data:match('id="user_tag"[^>]*>%s*([^<%s]+)')
    if name then return true, name end
    return false, "Lichess does not show you as logged in with this login (log in again in the app)"
end

-- A game as JSON, with the server analysis once it is there.
function Lichess:exportGame(id)
    return self:request("GET", "/game/export/" .. urlEncode(id), {
        query = { evals = "true", accuracy = "true", moves = "true", clocks = "false", opening = "true" },
    })
end

-- Your last games on Lichess (standard chess only), newest first.
-- Returns ok, list of { id, pgn, white, black, color, result, date, opening, analysed, speed }.
function Lichess:userGames(username, max)
    local ok, data = self:request("GET", "/api/games/user/" .. urlEncode(username), {
        accept = "application/x-ndjson",
        query = { max = max or 30, pgnInJson = "true", opening = "true", evals = "false", clocks = "false" },
    })
    if not ok then return false, data end
    local JSON = require("json")
    local raw = {}
    if type(data) == "table" then
        raw[1] = data
    elseif type(data) == "string" then
        for line in data:gmatch("[^\n]+") do
            local okj, g = pcall(JSON.decode, line)
            if okj and type(g) == "table" then raw[#raw + 1] = stripNulls(g) end
        end
    end
    local me = username:lower()
    local games = {}
    for _, g in ipairs(raw) do
        if g.variant == "standard" and g.pgn then
            local p = g.players or {}
            local function name(side)
                local s = p[side] or {}
                return (s.user and s.user.name) or (s.aiLevel and ("Stockfish level " .. s.aiLevel)) or "Anonymous"
            end
            local white, black = name("white"), name("black")
            local color = white:lower() == me and "w" or "b"
            local result = g.winner == "white" and "1-0" or (g.winner == "black" and "0-1" or "1/2-1/2")
            if g.status == "started" or g.status == "created" then result = "*" end
            games[#games + 1] = {
                id = g.id, pgn = g.pgn, white = white, black = black, color = color, result = result,
                opponent = color == "w" and black or white,
                date = g.createdAt and os.date("%Y-%m-%d", math.floor(g.createdAt / 1000)) or "",
                opening = g.opening and g.opening.name, analysed = g.analysis ~= nil or nil, speed = g.speed,
            }
        end
    end
    return true, games
end

-- The Lichess opening explorer: the moves played from a position, in the
-- masters' games or in the games of Lichess players (db = "masters" or
-- "lichess"). The explorer needs a Lichess login.
-- Returns ok, { white, draws, black, opening = { eco, name }, moves = { { uci, san, white, draws, black } } }
Lichess.EXPLORER = "https://explorer.lichess.ovh"
function Lichess:explorer(db, fen)
    local query = { fen = fen, moves = 12, topGames = 0 }
    if db == "lichess" then
        query.variant = "standard"
        query.speeds = "blitz,rapid,classical"
        query.ratings = "1600,1800,2000,2200,2500"
        query.recentGames = 0
    end
    return self:request("GET", "/" .. (db == "lichess" and "lichess" or "masters"),
        { base = Lichess.EXPLORER, query = query })
end

-- The Lichess endgame tablebase (7 pieces or fewer): the exact result with
-- perfect play, for the side to move ("win", "draw", "loss", "cursed-win",
-- "blessed-loss"). No account needed.
Lichess.TABLEBASE = "https://tablebase.lichess.ovh"
function Lichess:tablebase(fen)
    return self:request("GET", "/standard", { base = Lichess.TABLEBASE, query = { fen = fen }, anonymous = true })
end

-- An analysis board URL for a position (no account needed).
function Lichess.analysisUrl(fen)
    return Lichess.BASE .. "/analysis/standard/" .. fen:gsub(" ", "_")
end

return Lichess
