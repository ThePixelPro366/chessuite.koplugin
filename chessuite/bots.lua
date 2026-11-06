--[[
Opponents: the classic Stockfish levels, and bots with a personality.

The personality roster (names, ratings, styles, greetings and chat lines)
and the way a bot picks its move from honest engine lines (search depth,
softmax temperature over the centipawn loss, random moves for beginners,
"slips" where a bot overlooks one of your long-range pieces, personality
nudges) are ported from the open-source chess-app project by Arunav
Rajkhowa (https://github.com/ArunavRajkhowa/chess-app, AGPL-3.0), an open
alternative to chess.com's bots and coach.

The beginner bots (and plain engine games below 1000) play with Maia3, the
human move model of the University of Toronto CSSLab
(https://github.com/CSSLab/maia3), bundled as a small C port (bin/maia3-*):
it picks the move a player of that rating would most likely make, so its
mistakes are the ones people make, not random moves. Where it cannot run,
these bots fall back to the Stockfish based picking below.
--]]

local Chess = require("chessuite/chess")
local Engine = require("chessuite/uci")

local Bots = {}

-- Plain Stockfish, similar to lichess' "play with the computer" levels.
Bots.LEVELS = {
    { level = 1, skill = 0,  depth = 1,  movetime = 50,   elo = 800 },
    { level = 2, skill = 3,  depth = 2,  movetime = 100,  elo = 1100 },
    { level = 3, skill = 6,  depth = 3,  movetime = 150,  elo = 1400 },
    { level = 4, skill = 9,  depth = 4,  movetime = 200,  elo = 1700 },
    { level = 5, skill = 11, depth = 6,  movetime = 300,  elo = 2000 },
    { level = 6, skill = 14, depth = 8,  movetime = 400,  elo = 2300 },
    { level = 7, skill = 17, depth = 10, movetime = 500,  elo = 2700 },
    { level = 8, skill = 20, depth = 22, movetime = 1500, elo = 3000 },
}

local DEFAULT_CHAT = {
    capture_mine = { "Ouch. I needed that one.", "Fair capture. I will get it back.", "Hmm. I did not see that." },
    capture_yours = { "Thank you for the piece.", "I will take that.", "One for me." },
    check_given = { "Check.", "Your king looks lonely.", "Careful now." },
    check_received = { "A check. Noted.", "I see your check. My king is fine.", "Checks are cheap; mates are not." },
    long_game = { "A long fight. I like those.", "Still here. Are you?" },
    bot_winning = { "The material is on my side now.", "This is going well for me. Find something." },
    bot_losing = { "You are ahead. Do not relax.", "I am worse. Let us see if you can convert." },
}

local PERSONALITY_CHAT = {
    pip = { capture_mine = { "Oh no, my piece!", "Wait, you can do that?" }, capture_yours = { "I took something! Is that good?" }, check_given = { "Is this check? I think it is check!" }, bot_losing = { "I am losing again, aren't I?" } },
    max = { capture_yours = { "Mine! All mine!", "Grab first, think later." }, capture_mine = { "Hey! Give that back." }, check_given = { "Run, king, run!" } },
    rafa = { capture_mine = { "A pawn for the initiative. Worth it." }, check_given = { "The attack begins." }, bot_losing = { "Material is temporary. Pressure is forever." } },
    mei = { capture_mine = { "Patience. Everything is still protected." }, bot_winning = { "Small advantages, one at a time." } },
    trickster = { capture_yours = { "Did you see the trap? There is another one." }, check_given = { "Surprise." }, bot_losing = { "Fine. No more tricks. Maybe." } },
    wall = { capture_mine = { "Even walls lose a brick now and then." }, check_received = { "You will need more than a check." } },
    grinder = { bot_winning = { "Now we grind." }, long_game = { "The endgame is where I live." } },
    coach = { capture_mine = { "Good. You saw the loose piece." }, capture_yours = { "That was hanging. Check what my pieces attack before you move." }, check_received = { "Nice check. Did it gain anything?" }, bot_losing = { "You are winning. Simplify: trade pieces, not pawns." } },
    stockfish = { capture_mine = { "Noted." }, capture_yours = { "Correct." }, check_given = { "Check." } },
}

local function bot(t)
    t.multipv = t.multipv or 4
    t.random_move = t.random_move or 0
    t.slip = t.slip or 0
    t.personality = t.personality or {}
    t.greeting = t.greeting or "Good luck, have fun!"
    t.on_win = t.on_win or "Good game! Review it to see what we can learn."
    t.on_loss = t.on_loss or "Well played! You got me this time."
    t.on_draw = t.on_draw or "A draw. Fair result."
    local chat = {}
    for k, v in pairs(DEFAULT_CHAT) do
        local lines = {}
        for _, l in ipairs((PERSONALITY_CHAT[t.id] or {})[k] or {}) do lines[#lines + 1] = l end
        for _, l in ipairs(v) do lines[#lines + 1] = l end
        chat[k] = lines
    end
    t.chat = chat
    return t
end

Bots.TIERS = {
    { id = "beginner", name = "Beginner" },
    { id = "intermediate", name = "Intermediate" },
    { id = "advanced", name = "Advanced" },
    { id = "master", name = "Master" },
    { id = "special", name = "Coaches & specialists" },
}

Bots.ROSTER = {
    bot{ id = "pip", name = "Pip", elo = 250, tier = "beginner", tagline = "Just learned the rules", maia = true,
        depth = 1, temp = 400, multipv = 10, random_move = 0.35,
        description = "Pip hangs pieces, forgets about checks and loves pushing pawns. Perfect for a first game.",
        greeting = "Hi! I only learned chess last week. Be gentle!" },
    bot{ id = "max", name = "Max", elo = 400, tier = "beginner", tagline = "Grabs every piece in sight", maia = true,
        depth = 1, temp = 250, multipv = 8, random_move = 0.2,
        personality = { aggression = 0.8 },
        description = "Max takes anything he can and chases your queen. Punish greedy captures.",
        greeting = "Let's go! I like taking pieces." },
    bot{ id = "luna", name = "Luna", elo = 600, tier = "beginner", tagline = "Knows the opening principles", maia = true,
        depth = 2, temp = 150, multipv = 6, random_move = 0.08,
        description = "Luna develops her pieces and castles, then drifts. Good practice for simple tactics." },
    bot{ id = "sam", name = "Sam", elo = 800, tier = "beginner", tagline = "Spots one-move threats", maia = true,
        depth = 1, temp = 100, multipv = 5, slip = 0.6,
        description = "Sam sees hanging pieces and one-move captures, but misses deeper tactics." },
    bot{ id = "nova", name = "Nova", elo = 1000, tier = "intermediate", tagline = "Club night regular", depth = 2, temp = 70, multipv = 5, slip = 0.55,
        description = "Nova plays sensible chess and finds two-move tactics. Your first real test." },
    bot{ id = "rafa", name = "Rafa", elo = 1200, tier = "intermediate", tagline = "Loves a gambit", depth = 3, temp = 55, multipv = 4, slip = 0.4,
        personality = { aggression = 0.7 },
        description = "Rafa sacrifices pawns for open lines and attacks early. Keep your king safe." },
    bot{ id = "mei", name = "Mei", elo = 1400, tier = "intermediate", tagline = "Solid and patient", depth = 4, temp = 55, slip = 0.3,
        personality = { solidity = 0.7 },
        description = "Mei never overextends. You will have to create something yourself." },
    bot{ id = "leo", name = "Leo", elo = 1600, tier = "intermediate", tagline = "Tactical and sharp", depth = 5, temp = 45, slip = 0.2,
        personality = { aggression = 0.5 },
        description = "Leo calculates well in open positions. Avoid tactics you have not checked twice." },
    bot{ id = "ivy", name = "Ivy", elo = 1800, tier = "advanced", tagline = "Positional squeeze", depth = 6, temp = 40, slip = 0.1,
        personality = { solidity = 0.5, trade_when_ahead = 0.6 },
        description = "Ivy improves her pieces, grabs space and converts small edges. Learn to make plans against her." },
    bot{ id = "omar", name = "Omar", elo = 2000, tier = "advanced", tagline = "Expert strength", depth = 7, temp = 35,
        description = "Omar plays like a strong club expert. Few mistakes, punishes yours." },
    bot{ id = "zara", name = "Zara", elo = 2200, tier = "advanced", tagline = "Candidate master", depth = 9, temp = 25,
        personality = { aggression = 0.3 },
        description = "Zara's attacking play is precise. Defend accurately or lose quickly." },
    bot{ id = "viktor", name = "Viktor", elo = 2400, tier = "advanced", tagline = "FIDE master", depth = 11, temp = 16, multipv = 3,
        personality = { solidity = 0.6, trade_when_ahead = 0.8 },
        description = "Viktor grinds endgames. Expect every small advantage to be converted." },
    bot{ id = "elena", name = "Elena", elo = 2600, tier = "master", tagline = "International master", depth = 14, temp = 5, multipv = 2,
        description = "Elena plays near-perfect chess at club time controls." },
    bot{ id = "arjun", name = "Arjun", elo = 2800, tier = "master", tagline = "Grandmaster", depth = 16, temp = 2, multipv = 2,
        description = "Grandmaster strength. Expect to learn more than you win." },
    bot{ id = "kai", name = "Kai", elo = 3000, tier = "master", tagline = "Super grandmaster", depth = 18, temp = 0, multipv = 1, movetime = 800,
        description = "Elite strength. Study the games afterwards; the moves are the lesson." },
    bot{ id = "stockfish", name = "Stockfish", elo = 3200, tier = "master", tagline = "Full engine strength", depth = 22, temp = 0, multipv = 1, movetime = 2000,
        description = "The engine at full strength with no restraint. Nobody beats this one." },
    bot{ id = "coach", name = "Coach", elo = 1200, tier = "special", tagline = "Adapts to you, explains moves", depth = 4, temp = 60,
        description = "Coach adapts its strength to how you are doing: harder when you are ahead, gentler when you are behind. Explanations, hints and takebacks are on.",
        greeting = "Let's play and learn. Ask me for a hint any time.", is_coach = true },
    bot{ id = "trickster", name = "Trickster", elo = 1500, tier = "special", tagline = "Sets traps every game", depth = 5, temp = 45,
        personality = { aggression = 0.9 },
        description = "Trickster goes for cheap tricks and traps. Great for learning what not to fall for." },
    bot{ id = "wall", name = "The Wall", elo = 1700, tier = "special", tagline = "Defends everything", depth = 6, temp = 35, multipv = 3,
        personality = { solidity = 1.0, aggression = -0.6 },
        description = "The Wall trades pieces and keeps everything protected. Learn to break down a solid setup." },
    bot{ id = "grinder", name = "The Grinder", elo = 1900, tier = "special", tagline = "Endgame specialist", depth = 7, temp = 26, multipv = 3,
        personality = { trade_when_ahead = 1.0, solidity = 0.4 },
        description = "The Grinder steers for endgames and wins them. Practice your technique." },
}

Bots.BY_ID = {}
for _, b in ipairs(Bots.ROSTER) do Bots.BY_ID[b.id] = b end

-- A Stockfish level as a bot-like table.
function Bots.levelBot(level)
    local l = Bots.LEVELS[level] or Bots.LEVELS[4]
    return {
        id = "level" .. l.level, name = "Stockfish level " .. l.level, elo = l.elo, is_level = true,
        level = l, tagline = "About " .. l.elo .. " Elo", chat = {}, greeting = nil,
        on_win = "Checkmate. Try again!", on_loss = "Well played!", on_draw = "Draw.",
    }
end

-- Plain engine at any rating from 100 to 3200, without a personality.
-- Below MAIA_BELOW it is the human-like Maia3 at that rating. Above, it is
-- Stockfish with its strength settings interpolated between the roster bots
-- around that rating (also the fallback where Maia3 cannot run; below 250
-- that one plays more and more random moves).
Bots.MAIA_BELOW = 1000
function Bots.stockfishAt(elo)
    elo = math.max(100, math.min(3200, math.floor(elo + 0.5)))
    local ladder = {}
    for _, b in ipairs(Bots.ROSTER) do
        if b.tier ~= "special" then ladder[#ladder + 1] = b end
    end
    table.sort(ladder, function(a, c) return a.elo < c.elo end)
    local p
    if elo <= ladder[1].elo then
        local t = (ladder[1].elo - elo) / (ladder[1].elo - 100)
        p = { depth = 1, temp = 400 + 300 * t, multipv = 10, random_move = 0.35 + 0.35 * t, slip = 0 }
    else
        local lo, hi = ladder[#ladder], ladder[#ladder]
        for i = 1, #ladder - 1 do
            if elo >= ladder[i].elo and elo <= ladder[i + 1].elo then lo, hi = ladder[i], ladder[i + 1] end
        end
        local t = hi.elo == lo.elo and 0 or (elo - lo.elo) / (hi.elo - lo.elo)
        local function mix(k) return (lo[k] or 0) + ((hi[k] or 0) - (lo[k] or 0)) * t end
        p = {
            depth = math.floor(mix("depth") + 0.5),
            temp = mix("temp"),
            multipv = math.max(1, math.floor(mix("multipv") + 0.5)),
            random_move = mix("random_move"),
            slip = mix("slip"),
            movetime = t >= 0.5 and hi.movetime or lo.movetime,
        }
    end
    p.id = "sf:" .. elo
    p.name = "Stockfish"
    p.elo = elo
    p.tier = "stockfish"
    p.tagline = "Plain engine at " .. elo
    if elo < Bots.MAIA_BELOW then
        p.maia = true
        p.name = "Maia"
        p.tagline = "Human-like engine at " .. elo
    end
    p.description = ""
    p.personality = {}
    p.chat = {}
    p.no_personality = true
    p.on_win, p.on_loss, p.on_draw = "", "", ""
    return p
end

-- Two people on one device: no engine moves, no rating.
Bots.FRIEND = { id = "friend", name = "Friend", human = true, no_personality = true, chat = {},
    on_win = "", on_loss = "", on_draw = "" }

-- The chess piece that stands for a bot on its card: pawns for beginners up
-- to the queen for masters, a rook for the plain engine. The coach has its own icon.
local TIER_PIECE = { beginner = "p", intermediate = "n", advanced = "b", master = "q", stockfish = "r" }
function Bots.pieceFor(b)
    if not b or b.is_coach or b.human then return nil end
    if b.is_level then return "r" end
    if b.id == "stockfish" then return "k" end
    return TIER_PIECE[b.tier] or "k"
end

function Bots.get(id)
    if id == "friend" then return Bots.FRIEND end
    if Bots.BY_ID[id] then return Bots.BY_ID[id] end
    local sf = type(id) == "string" and tonumber(id:match("^sf:(%d+)$"))
    if sf then return Bots.stockfishAt(sf) end
    local lvl = type(id) == "string" and tonumber(id:match("^level(%d)$"))
    if lvl then return Bots.levelBot(lvl) end
    return nil
end

-- The Coach, playing at about `rating`: it borrows the search settings of
-- the roster bot closest to that rating and keeps its own voice.
function Bots.coachFor(rating)
    local base = Bots.BY_ID.coach
    local closest
    for _, b in ipairs(Bots.ROSTER) do
        if b.tier ~= "special" and (not closest or math.abs(b.elo - rating) < math.abs(closest.elo - rating)) then
            closest = b
        end
    end
    local c = {}
    for k, v in pairs(base) do c[k] = v end
    for _, k in ipairs({ "depth", "temp", "multipv", "random_move", "slip", "movetime", "maia" }) do c[k] = closest[k] end
    c.elo = rating
    return c
end

function Bots.say(b, event)
    local lines = b.chat and b.chat[event]
    if not lines or #lines == 0 then return nil end
    return lines[math.random(#lines)]
end

-- Selection --------------------------------------------------------------------

local VALUE = { p = 1, n = 3, b = 3, r = 5, q = 9, k = 0 }
local SLIP_MAX_LOSS_CP = 400
local LONG_RANGE = { b = true, r = true, q = true }

local function personalityBonus(game, m, b, balance)
    local p = b.personality or {}
    local bonus = 0
    local capture = m.captured ~= nil
    game:makeMove(m)
    local check = game:inCheck()
    game:unmakeMove()
    if p.aggression and p.aggression ~= 0 then
        if capture then bonus = bonus + 25 * p.aggression end
        if check then bonus = bonus + 20 * p.aggression end
        local k = game.kings[Chess.opposite(game.turn)]
        local df = math.abs(Chess.fileOf(m.to) - Chess.fileOf(k))
        local dr = math.abs(Chess.rankOf(m.to) - Chess.rankOf(k))
        if math.max(df, dr) <= 2 then bonus = bonus + 15 * p.aggression end
    end
    if p.solidity and p.solidity ~= 0 then
        if not capture and not check then bonus = bonus + 12 * p.solidity end
        local r = Chess.rankOf(m.to)
        if Chess.typeOf(m.piece) == "p" and (r == 3 or r == 4) then bonus = bonus - 8 * p.solidity end
    end
    if p.trade_when_ahead and p.trade_when_ahead ~= 0 and capture then
        if Chess.typeOf(m.captured) == Chess.typeOf(m.piece) then
            bonus = bonus + 20 * p.trade_when_ahead * (balance > 0 and 1 or -0.5)
        end
    end
    return bonus
end

local function balanceFor(game, color)
    local b = game:materialBalance()
    return color == "w" and b or -b
end

-- A capture that wins at least a minor piece by a simple exchange count.
local function winsAPiece(game, m)
    if not m.captured or Chess.typeOf(m.captured) == "p" then return false end
    local gain = VALUE[Chess.typeOf(m.captured)]
    game:makeMove(m)
    local defended = #game:attackers(m.to, game.turn) > 0
    game:unmakeMove()
    if defended then gain = gain - VALUE[Chess.typeOf(m.piece)] end
    return gain >= 3
end

local function dropsAMajor(game, m)
    local t = Chess.typeOf(m.piece)
    if t ~= "r" and t ~= "q" then return false end
    if m.captured and VALUE[Chess.typeOf(m.captured)] >= VALUE[t] then return false end
    game:makeMove(m)
    local attacked = #game:attackers(m.to, game.turn) > 0
    game:unmakeMove()
    return attacked
end

-- The FEN with one of the opponent's bishops, rooks or queens removed.
local function blindSpotFen(game)
    if game:inCheck() then return nil end
    local them = Chess.opposite(game.turn)
    local squares = {}
    for s = 0, 119 do
        local p = Chess.onBoard(s) and game.board[s]
        if p and Chess.colorOf(p) == them and LONG_RANGE[Chess.typeOf(p)] then squares[#squares + 1] = s end
    end
    if #squares == 0 then return nil end
    local g = game:clone()
    g.board[squares[math.random(#squares)]] = nil
    if g:inCheck(them) then return nil end
    return g:fen()
end

local function adaptive(b, game)
    local temp, rnd = b.temp or 0, b.random_move or 0
    if b.id ~= "coach" then return temp, rnd end
    local balance = balanceFor(game, game.turn)
    if balance <= -2 then return temp * 0.4, 0 end
    if balance >= 2 then return temp * 2.5, 0.08 end
    return temp, rnd
end

-- Maia3's rating for a bot; the Coach plays 300 points stronger when it is
-- behind and 300 weaker when it is ahead.
local function maiaElo(b, game)
    local elo = b.elo or 1000
    if b.id == "coach" then
        local balance = balanceFor(game, game.turn)
        if balance <= -2 then elo = elo + 300 elseif balance >= 2 then elo = elo - 300 end
    end
    return math.max(0, math.floor(elo + 0.5))
end

-- Maia3's moves are sampled like its own UCI engine does, without the
-- unlikely tail (moves almost nobody at that rating would play).
local MAIA_TOP_P = 0.97

local function maiaMove(engine, game, b, legal, done, fallback)
    local ucis = {}
    for i, m in ipairs(legal) do ucis[i] = Chess.uci(m) end
    engine:search({ fen = game:fen(), depth = 1, multipv = #ucis, searchmoves = ucis,
        options = { Elo = maiaElo(b, game) } }, nil, function(res)
        local lines = res and res.lines
        if not lines or #lines == 0 or not lines[1].prob then return fallback() end
        local balance = balanceFor(game, game.turn)
        local cands, mass, total = {}, 0, 0
        for _, l in ipairs(lines) do
            local m = l.pv and game:moveFromUci(l.pv[1])
            if m and (mass < MAIA_TOP_P or #cands == 0) then
                mass = mass + l.prob
                -- personality: a nudge on top of the human probabilities
                local w = l.prob * math.exp(personalityBonus(game, m, b, balance) / 40)
                cands[#cands + 1] = { uci = l.pv[1], w = w }
                total = total + w
            end
        end
        if #cands == 0 then return fallback() end
        local r = math.random() * total
        for _, c in ipairs(cands) do
            r = r - c.w
            if r <= 0 then return done(c.uci, { lines = lines, source = "maia" }) end
        end
        done(cands[1].uci, { lines = lines, source = "maia" })
    end)
end

local function searchParams(b, fen, multipv)
    if b.movetime then return { fen = fen, movetime = b.movetime, multipv = multipv } end
    return { fen = fen, depth = b.depth, multipv = multipv }
end

--[[
Picks the bot's move. Calls done(uci, info) where info has the engine's
lines (when there was a search) so the caller can reuse the evaluation.
--]]
function Bots.chooseMove(engine, game, b, done)
    local legal = game:moves()
    if #legal == 0 then return done(nil) end
    local fen = game:fen()

    if b.is_level then
        local l = b.level
        engine:search({ fen = fen, depth = l.depth, movetime = l.movetime, skill = l.skill, multipv = 1 }, nil,
            function(res, err)
                if not res or not res.bestmove then
                    return done(Chess.uci(legal[math.random(#legal)]), { error = err })
                end
                done(res.bestmove, { lines = res.lines })
            end)
        return
    end

    if b.maia and engine.maia and not engine.maia.failed then
        return maiaMove(engine.maia, game, b, legal, done, function()
            -- Maia3 does not run here: play this game with Stockfish
            engine.maia.failed = true
            Bots.chooseMove(engine, game, b, done)
        end)
    end

    local temp, random_prob = adaptive(b, game)
    if random_prob > 0 and math.random() < random_prob then
        return done(Chess.uci(legal[math.random(#legal)]), { source = "random" })
    end

    local multipv = math.min(b.multipv or 1, #legal)

    local function pick(lines, slip_uci)
        if not lines or #lines == 0 then
            return done(Chess.uci(legal[math.random(#legal)]), { source = "random" })
        end
        local cands = {}
        for _, l in ipairs(lines) do
            local m = l.pv and game:moveFromUci(l.pv[1])
            if m then cands[#cands + 1] = { move = m, cp = Engine.lineCp(l), line = l } end
        end
        if #cands == 0 then return done(Chess.uci(legal[math.random(#legal)])) end
        local best_cp = cands[1].cp
        -- a slip: play the move chosen with one of our opponent's pieces out of sight
        if slip_uci then
            local slip_cp
            for _, c in ipairs(cands) do if Chess.uci(c.move) == slip_uci then slip_cp = c.cp end end
            local sm = game:moveFromUci(slip_uci)
            if sm and slip_cp and not Engine.isMateScore(best_cp) and not Engine.isMateScore(slip_cp)
                and best_cp - slip_cp <= SLIP_MAX_LOSS_CP and not dropsAMajor(game, sm) then
                return done(slip_uci, { lines = lines, source = "slip" })
            end
        end
        -- a club player never leaves a free piece on the board
        if (b.slip or 0) > 0 and not Engine.isMateScore(best_cp) then
            for _, c in ipairs(cands) do
                if not Engine.isMateScore(c.cp) and winsAPiece(game, c.move) then
                    return done(Chess.uci(c.move), { lines = lines, source = "grab" })
                end
            end
        end
        if temp <= 0 or #cands == 1 then
            return done(Chess.uci(cands[1].move), { lines = lines, source = "engine" })
        end
        local balance = balanceFor(game, game.turn)
        local top = -math.huge
        for _, c in ipairs(cands) do
            c.adj = c.cp + personalityBonus(game, c.move, b, balance)
            if c.adj > top then top = c.adj end
        end
        local total = 0
        for _, c in ipairs(cands) do
            c.w = math.exp((c.adj - top) / temp)
            total = total + c.w
        end
        local r = math.random() * total
        for _, c in ipairs(cands) do
            r = r - c.w
            if r <= 0 then return done(Chess.uci(c.move), { lines = lines, source = "engine" }) end
        end
        return done(Chess.uci(cands[1].move), { lines = lines, source = "engine" })
    end

    local function mainSearch(slip_uci)
        local params = searchParams(b, fen, multipv)
        if slip_uci then
            -- one more line gives the slip move a better chance to be judged for free
            params.multipv = math.min(multipv + 1, #legal)
        end
        engine:search(params, nil, function(res)
            local lines = res and res.lines
            if slip_uci and lines then
                local found = false
                for _, l in ipairs(lines) do if l.pv[1] == slip_uci then found = true end end
                if not found then
                    -- judge the slip move on the real board
                    local p2 = searchParams(b, fen, 1)
                    p2.searchmoves = { slip_uci }
                    p2.keep_running = true
                    engine:search(p2, nil, function(res2)
                        local l2 = res2 and res2.lines and res2.lines[1]
                        if l2 then
                            l2.multipv = #lines + 1
                            lines[#lines + 1] = l2
                        end
                        pick(lines, slip_uci)
                    end)
                    return
                end
            end
            pick(lines, slip_uci)
        end)
    end

    local blind = (b.slip or 0) > 0 and math.random() < b.slip and blindSpotFen(game)
    if blind then
        engine:search(searchParams(b, blind, 1), nil, function(res)
            local slip = res and res.bestmove
            if slip and not game:moveFromUci(slip) then slip = nil end
            mainSearch(slip)
        end)
    else
        mainSearch(nil)
    end
end

-- Chat after a pair of moves, from the bot's point of view.
function Bots.chatEvent(b, game, bot_color, player_move, bot_move, eval_cp_bot)
    if player_move and player_move.captured and math.random() < 0.6 then return Bots.say(b, "capture_mine") end
    if bot_move and bot_move.captured and math.random() < 0.6 then return Bots.say(b, "capture_yours") end
    if bot_move and game:inCheck() and game.turn ~= bot_color and math.random() < 0.5 then return Bots.say(b, "check_given") end
    if player_move and player_move.san and player_move.san:find("[+#]") and math.random() < 0.5 then
        return Bots.say(b, "check_received")
    end
    if eval_cp_bot and math.random() < 0.15 then
        if eval_cp_bot > 300 then return Bots.say(b, "bot_winning") end
        if eval_cp_bot < -300 then return Bots.say(b, "bot_losing") end
    end
    if game:plyCount() == 80 then return Bots.say(b, "long_game") end
    return nil
end

return Bots
