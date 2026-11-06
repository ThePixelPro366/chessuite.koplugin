--[[
Talks UCI to a Stockfish process through a pair of pipes.

The process is started with KOReader's ffi/util runInSubProcess() (which
gives us bidirectional pipes and its own process group), then exec()s the
engine binary. Output is read without blocking from a UIManager timer, so
the UI stays responsive while the engine thinks.

Usage:
    local engine = Engine:new{ path = "/path/to/stockfish" }
    engine:search({ fen = fen, movetime = 1000, multipv = 3 },
        function(info) ... end,      -- optional, called while searching
        function(result) ... end)    -- result.bestmove, result.lines
--]]

local logger = require("logger")

local Engine = {}
Engine.__index = Engine

local POLL_INTERVAL = 0.08
local START_TIMEOUT = 8

-- Which bundled binary runs on this device: "stockfish" (default) or "maia3".
function Engine.bundledBinaryName(engine)
    engine = engine or "stockfish"
    local ok, ffi = pcall(require, "ffi")
    local arch = ok and ffi.arch or ""
    if arch == "arm" then return engine .. "-armv7" end
    if arch == "arm64" then return engine .. "-aarch64" end
    if arch == "x64" then return engine .. "-x86_64" end
    return nil
end

function Engine:new(o)
    o = o or {}
    setmetatable(o, self)
    o.threads = o.threads or 1
    o.hash = o.hash or 16
    o.buffer = ""
    o.queue = {}
    o.current = nil
    o.ready = false
    o.options_sent = {}
    return o
end

function Engine:isRunning()
    if not self.pid then return false end
    local ffiutil = require("ffi/util")
    if ffiutil.isSubProcessDone(self.pid) then
        self:_closeFds()
        self.pid = nil
        return false
    end
    return true
end

function Engine:_closeFds()
    local ffi = require("ffi")
    local C = ffi.C
    if self.read_fd then C.close(self.read_fd); self.read_fd = nil end
    if self.write_fd then C.close(self.write_fd); self.write_fd = nil end
end

function Engine:start()
    if self:isRunning() then return true end
    if not self.path then return false, "no engine binary for this device" end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(self.path, "mode") ~= "file" then
        return false, "engine binary not found: " .. self.path
    end
    -- Archive tools and some file systems drop the executable bit.
    os.execute("chmod 755 '" .. self.path:gsub("'", "'\\''") .. "' 2>/dev/null")

    local ffi = require("ffi")
    local C = ffi.C
    local ffiutil = require("ffi/util")
    local path = self.path
    local pid, read_fd, write_fd = ffiutil.runInSubProcess(function(_, child_write_fd, child_read_fd)
        C.dup2(child_read_fd, 0)
        C.dup2(child_write_fd, 1)
        C.execl(path, path, nil)
        -- only reached when exec failed
        C._exit(127)
    end, "bidi")
    if not pid then
        return false, read_fd or "could not start engine"
    end
    self.pid, self.read_fd, self.write_fd = pid, read_fd, write_fd
    self.buffer = ""
    self.ready = false
    self.started_at = os.time()
    self.options_sent = {}
    self:send("uci")
    self:_schedulePoll()
    return true
end

function Engine:send(line)
    if not self.write_fd then return false end
    local ffiutil = require("ffi/util")
    logger.dbg("chessuite uci >", line)
    return ffiutil.writeToFD(self.write_fd, line .. "\n")
end

function Engine:setOption(name, value)
    value = tostring(value)
    if self.options_sent[name] == value then return end
    self.options_sent[name] = value
    self:send("setoption name " .. name .. " value " .. value)
end

function Engine:_schedulePoll()
    if self.polling then return end
    self.polling = true
    local UIManager = require("ui/uimanager")
    self._poll = self._poll or function()
        self.polling = false
        self:poll()
        if self.pid and (not self.ready or self.current or #self.queue > 0) then
            self:_schedulePoll()
        end
    end
    UIManager:scheduleIn(POLL_INTERVAL, self._poll)
end

function Engine:poll()
    if not self.read_fd then return end
    local ffiutil = require("ffi/util")
    local available = ffiutil.getNonBlockingReadSize(self.read_fd)
    if available and available > 0 then
        local ffi = require("ffi")
        local buf = ffi.new("char[?]", available)
        local n = ffi.C.read(self.read_fd, buf, available)
        if n > 0 then
            self.buffer = self.buffer .. ffi.string(buf, n)
            while true do
                local nl = self.buffer:find("\n", 1, true)
                if not nl then break end
                local line = self.buffer:sub(1, nl - 1):gsub("\r$", "")
                self.buffer = self.buffer:sub(nl + 1)
                self:_onLine(line)
            end
        end
    elseif not self.ready and self.started_at and os.time() - self.started_at > START_TIMEOUT then
        logger.warn("chessuite: engine did not answer, giving up")
        self:quit()
        if self.on_failure then self.on_failure("engine did not start") end
    elseif not self:isRunning() then
        logger.warn("chessuite: engine process exited")
        self.ready = false
        local job = self.current
        self.current = nil
        self.queue = {}
        if job and job.on_done and not job.cancelled then
            job.on_done(nil, "engine stopped")
        end
    end
end

local function parseInfo(line)
    local info = {}
    local tokens = {}
    for t in line:gmatch("%S+") do tokens[#tokens + 1] = t end
    local i = 2
    while i <= #tokens do
        local t = tokens[i]
        if t == "depth" or t == "seldepth" or t == "multipv" or t == "nodes" or t == "nps" or t == "time"
            or t == "prob" then -- prob: Maia3's chance that a human plays this move
            info[t] = tonumber(tokens[i + 1])
            i = i + 2
        elseif t == "score" then
            local kind, v = tokens[i + 1], tonumber(tokens[i + 2])
            if kind == "cp" then info.cp = v else info.mate = v end
            i = i + 3
            if tokens[i] == "lowerbound" or tokens[i] == "upperbound" then
                info.bound = tokens[i]
                i = i + 1
            end
        elseif t == "pv" then
            info.pv = {}
            for j = i + 1, #tokens do info.pv[#info.pv + 1] = tokens[j] end
            break
        else
            i = i + 1
        end
    end
    return info
end
Engine.parseInfo = parseInfo

function Engine:_onLine(line)
    logger.dbg("chessuite uci <", line)
    if line == "uciok" then
        self:setOption("Threads", self.threads)
        self:setOption("Hash", self.hash)
        self:send("isready")
    elseif line == "readyok" then
        if not self.ready then
            self.ready = true
            self:_startNext()
        end
    elseif self.current and self.current.params.eval then
        local job = self.current
        local name, wmg, weg, bmg, beg, tmg, teg = line:match(
            "^%s*([%a ]-)%s*|%s*(%S+)%s+(%S+)%s*|%s*(%S+)%s+(%S+)%s*|%s*(%S+)%s+(%S+)")
        if name and name ~= "Term" and name ~= "" then
            job.terms = job.terms or {}
            job.terms[name] = { white = { tonumber(wmg), tonumber(weg) }, black = { tonumber(bmg), tonumber(beg) },
                total = { tonumber(tmg), tonumber(teg) } }
        end
        if line:find("^Total evaluation") or line:find("^Final evaluation") then
            self.current = nil
            if not job.cancelled and job.on_done then job.on_done(job.terms or {}) end
            self:_startNext()
        end
    elseif line:sub(1, 5) == "info " then
        local job = self.current
        if job and line:find(" pv ", 1, true) then
            local info = parseInfo(line)
            if info.pv and #info.pv > 0 and not info.bound then
                local k = info.multipv or 1
                job.lines[k] = info
                if job.on_info and not job.cancelled then job.on_info(info, job.lines) end
            end
        end
    elseif line:sub(1, 9) == "bestmove " then
        local job = self.current
        self.current = nil
        if job and not job.cancelled and job.on_done then
            local best = line:match("^bestmove (%S+)")
            if best == "(none)" then best = nil end
            local lines = {}
            for k = 1, (job.params.multipv or 1) do
                if job.lines[k] then lines[#lines + 1] = job.lines[k] end
            end
            job.on_done({ bestmove = best, lines = lines })
        end
        self:_startNext()
    end
end

function Engine:_startNext()
    if self.current or not self.ready then return end
    local job = table.remove(self.queue, 1)
    if not job then return end
    self.current = job
    local p = job.params
    if p.eval then
        -- Stockfish's static evaluation, term by term (see Engine:evalTerms)
        self:send("position fen " .. p.fen)
        self:send("eval")
        self:_schedulePoll()
        return
    end
    self:setOption("MultiPV", p.multipv or 1)
    self:setOption("Skill Level", p.skill or 20)
    for name, value in pairs(p.options or {}) do self:setOption(name, value) end
    local pos = p.fen and ("position fen " .. p.fen) or "position startpos"
    if p.moves and #p.moves > 0 then pos = pos .. " moves " .. table.concat(p.moves, " ") end
    self:send(pos)
    local go = { "go" }
    if p.infinite then
        go[#go + 1] = "infinite"
    else
        if p.depth then go[#go + 1] = "depth " .. p.depth end
        if p.movetime then go[#go + 1] = "movetime " .. math.floor(p.movetime) end
        if p.nodes then go[#go + 1] = "nodes " .. math.floor(p.nodes) end
        if #go == 1 then go[#go + 1] = "movetime 1000" end
    end
    if p.searchmoves and #p.searchmoves > 0 then
        go[#go + 1] = "searchmoves " .. table.concat(p.searchmoves, " ")
    end
    self:send(table.concat(go, " "))
    self:_schedulePoll()
end

-- Queues a search. A running search is stopped and its callbacks dropped,
-- unless params.keep_running is set (then the new one waits its turn).
function Engine:search(params, on_info, on_done)
    if not self:isRunning() then
        local ok, err = self:start()
        if not ok then
            if on_done then on_done(nil, err) end
            return nil
        end
    end
    local job = { params = params, on_info = on_info, on_done = on_done, lines = {} }
    if not params.keep_running then self:cancelAll() end
    self.queue[#self.queue + 1] = job
    self:_startNext()
    self:_schedulePoll()
    return job
end

-- Stockfish 11's evaluation of a position, by term ("King safety",
-- "Mobility", "Threats", "Passed", "Space", "Pawns", ...): for each the
-- middlegame and endgame values in pawns for { white }, { black } and { total }
-- (White's side). Waits for a running search. cb(terms)
function Engine:evalTerms(fen, cb)
    return self:search({ fen = fen, eval = true, keep_running = true }, nil, cb)
end

-- Ask an infinite (or long) search to finish now; its on_done gets called.
function Engine:finish()
    if self.current then self:send("stop") end
end

function Engine:cancelAll()
    for _, job in ipairs(self.queue) do job.cancelled = true end
    self.queue = {}
    if self.current then
        self.current.cancelled = true
        self:send("stop")
    end
end

function Engine:newGame()
    if self:isRunning() then
        self:cancelAll()
        self:send("ucinewgame")
    end
end

function Engine:quit()
    self:cancelAll()
    if not self.pid then return end
    self:send("quit")
    local pid = self.pid
    self.pid = nil
    self.ready = false
    self:_closeFds()
    local ffiutil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    local tries = 0
    local function reap()
        tries = tries + 1
        if ffiutil.isSubProcessDone(pid) then return end
        if tries == 5 then ffiutil.terminateSubProcess(pid) end
        if tries < 20 then UIManager:scheduleIn(0.2, reap) end
    end
    UIManager:scheduleIn(0.2, reap)
end

-- Score helpers --------------------------------------------------------------

local MATE_CP = 100000

-- Centipawns from the side to move's view; mates mapped to big numbers.
function Engine.lineCp(line)
    if not line then return nil end
    if line.mate then
        if line.mate > 0 then return MATE_CP - line.mate * 100 end
        return -MATE_CP - line.mate * 100
    end
    return line.cp
end
Engine.MATE_CP = MATE_CP

function Engine.isMateScore(cp) return cp and math.abs(cp) > MATE_CP - 10000 end

-- lichess' win percentage curve, 0..100 from the side to move's view.
function Engine.winPercent(cp)
    if not cp then return 50 end
    if cp > 1500 then cp = 1500 elseif cp < -1500 then cp = -1500 end
    return 50 + 50 * (2 / (1 + math.exp(-0.00368208 * cp)) - 1)
end

-- Human readable score from White's view, e.g. "+0.35", "-M3", "M2".
function Engine.formatScore(line, side_to_move)
    if not line then return "" end
    local sign = side_to_move == "w" and 1 or -1
    if line.mate then
        local m = line.mate * sign
        if m > 0 then return "M" .. m end
        return "-M" .. (-m)
    end
    local v = (line.cp or 0) * sign / 100
    return string.format("%+.2f", v)
end

return Engine
