--[[
Opening courses for the opening trainer, ported from tabia
(https://github.com/daxaur/tabia, MIT, (c) 2026 dax): openings in folders,
their lines with the idea and the coach's notes on moves
(chessuite/repertoire_data.lua), spaced repetition like tabia's store.js
(Leitner boxes: a line played cleanly comes back later, a slip brings it
back sooner) and the coach's lines from its coach.js.
--]]

local Store = require("chessuite/store")

local Repertoire = {}

local DAY = 24 * 3600
-- box 0 = due now; then 1, 3, 7, 16, 35 and 90 days
Repertoire.INTERVALS = { [0] = 0, DAY, 3 * DAY, 7 * DAY, 16 * DAY, 35 * DAY, 90 * DAY }
Repertoire.MAX_BOX = 6
Repertoire.MASTERED_BOX = 4

-- tabia's coach.js defaults ({exp} is the move to play, in words here)
Repertoire.MESSAGES = {
    start = { "Let's drill. Play the repertoire move.", "Board's set. Show me the line.",
        "Warm up those reflexes. Your move." },
    correct = { "Clean.", "That's the one.", "Exactly right.", "Booked.", "Crisp move." },
    wrong = { "Not quite, look again.", "That's off-book. The move was {exp}.", "Close, but {exp} is the line.",
        "Reset and feel it: {exp}." },
    done = { "Line complete. Filed away.", "Whole line, clean. Nice.", "Done: that one's in the muscle now." },
    doneMiss = { "Logged. We'll see this one again soon.", "A slip in there; it comes back sooner.",
        "Not clean, but you'll get it next pass." },
    learn = { "Watch how it flows.", "Here's the idea: follow the plan.", "Study the shape, then you'll drill it." },
    offBook = { "That leaves your prep: {exp} keeps you in the lines.", "Off your repertoire here. The move is {exp}.",
        "Not in your book: play {exp}." },
}

-- A coach line: from the line's or opening's own messages, else the defaults.
function Repertoire.say(key, vars, own)
    local list = own and own[key] and #own[key] > 0 and own[key] or Repertoire.MESSAGES[key] or { "" }
    local m = list[math.random(#list)]
    return (m:gsub("{(%w+)}", function(k) return vars and vars[k] or "" end))
end

local data
function Repertoire.data()
    if not data then
        local dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./chessuite/"
        local ok, d = pcall(dofile, dir .. "repertoire_data.lua")
        data = ok and d or { categories = {}, openings = {} }
    end
    return data
end

function Repertoire.openings() return Repertoire.data().openings end
function Repertoire.categories() return Repertoire.data().categories end

function Repertoire.opening(id)
    for _, o in ipairs(Repertoire.openings()) do if o.id == id then return o end end
end

function Repertoire.line(op, id)
    for _, l in ipairs(op.lines) do if l.id == id then return l end end
end

-- Spaced repetition (tabia's store.js) ------------------------------------------------

local function all() return Store.get("repertoire_srs") or {} end

function Repertoire.state(op_id, line_id)
    local s = all()[op_id]
    return (s and s[line_id]) or { box = 0, due = 0, seen = 0, ok = 0, fail = 0 }
end

local function save(op_id, line_id, st)
    local s = all()
    s[op_id] = s[op_id] or {}
    s[op_id][line_id] = st
    Store.set("repertoire_srs", s)
end

-- After drilling a whole line: clean moves the line up a box, a slip down one.
function Repertoire.record(op_id, line_id, success, now)
    local st = Repertoire.state(op_id, line_id)
    st.seen = st.seen + 1
    if success then
        st.ok = st.ok + 1
        st.box = math.min(Repertoire.MAX_BOX, st.box + 1)
    else
        st.fail = st.fail + 1
        st.box = math.max(0, st.box - 1)
    end
    st.due = (now or os.time()) + Repertoire.INTERVALS[st.box]
    save(op_id, line_id, st)
    return st
end

function Repertoire.discover(op_id, line_id)
    local st = Repertoire.state(op_id, line_id)
    if not st.disc then
        st.disc = true
        save(op_id, line_id, st)
    end
end

function Repertoire.isDue(op_id, line_id, now)
    return Repertoire.state(op_id, line_id).due <= (now or os.time())
end
function Repertoire.mastery(op_id, line_id) return Repertoire.state(op_id, line_id).box end

-- The next line to drill: due lines first, then the weakest, then the most overdue.
function Repertoire.pickNext(op_id, line_ids, now)
    now = now or os.time()
    local scored = {}
    for i, id in ipairs(line_ids) do
        local st = Repertoire.state(op_id, id)
        scored[#scored + 1] = { id = id, box = st.box, overdue = now - st.due, i = i }
    end
    table.sort(scored, function(a, b)
        local ad, bd = a.overdue >= 0, b.overdue >= 0
        if ad ~= bd then return ad end
        if a.box ~= b.box then return a.box < b.box end
        if a.overdue ~= b.overdue then return a.overdue > b.overdue end
        return a.i < b.i
    end)
    return scored[1] and scored[1].id
end

-- Counts for an opening: lines due, mastered, seen.
function Repertoire.summary(op, now)
    local due, mastered, seen = 0, 0, 0
    for _, l in ipairs(op.lines) do
        local st = Repertoire.state(op.id, l.id)
        if st.due <= (now or os.time()) then due = due + 1 end
        if st.box >= Repertoire.MASTERED_BOX then mastered = mastered + 1 end
        if st.seen > 0 or st.disc then seen = seen + 1 end
    end
    return { due = due, mastered = mastered, seen = seen, total = #op.lines }
end

-- "●●○○○○"
function Repertoire.dots(box)
    return string.rep("●", box) .. string.rep("○", Repertoire.MAX_BOX - box)
end

return Repertoire
