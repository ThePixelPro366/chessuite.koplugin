--[[
Full-screen "My progress" page: your rating over time as a chart, results
against the bots, puzzles and Lichess Practice.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local Common = require("chessuite/ui/common")
local LP = require("chessuite/lichesspractice")
local Store = require("chessuite/store")

-- A line chart of numbers, drawn with plain rectangles (works on any screen).
local Chart = Widget:extend{
    width = 400,
    height = 200,
    values = nil, -- list of numbers, oldest first
}

function Chart:getSize() return Geom:new{ w = self.width, h = self.height } end

function Chart:range()
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(self.values) do lo = math.min(lo, v); hi = math.max(hi, v) end
    -- round to 50s, with some room
    lo = math.floor((lo - 25) / 50) * 50
    hi = math.ceil((hi + 25) / 50) * 50
    return lo, hi
end

function Chart:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local black, grey = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_LIGHT_GRAY
    local face = Font:getFace("cfont", 14)
    local lo, hi = self:range()
    local label_w = Common.scale(44)
    local left, top = x + label_w, y + Common.scale(6)
    local w, h = self.width - label_w - Common.scale(4), self.height - Common.scale(12)
    -- grid lines and labels: bottom, middle, top
    for i = 0, 2 do
        local gy = top + math.floor(h * i / 2)
        bb:paintRect(left, gy, w, 1, grey)
        local t = TextWidget:new{ text = tostring(math.floor(hi - (hi - lo) * i / 2 + 0.5)), face = face }
        local ts = t:getSize()
        t:paintTo(bb, x, gy - math.floor(ts.h / 2))
        t:free()
    end
    bb:paintRect(left, top, 2, h, black)
    local n = #self.values
    local function point(i)
        local px = left + (n == 1 and math.floor(w / 2) or math.floor((i - 1) * (w - 1) / (n - 1)))
        local py = top + h - math.floor((self.values[i] - lo) * h / (hi - lo))
        return px, py
    end
    local dot = math.max(3, Common.scale(3))
    for i = 1, n do
        local x1, y1 = point(i)
        if i < n then
            -- the segment to the next point, as a thick line of small squares
            local x2, y2 = point(i + 1)
            local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1), 1)
            for s = 0, steps do
                local px = x1 + math.floor((x2 - x1) * s / steps)
                local py = y1 + math.floor((y2 - y1) * s / steps)
                bb:paintRect(px - 1, py - 1, 3, 3, black)
            end
        end
        if n <= 40 then bb:paintRect(x1 - dot, y1 - dot, 2 * dot + 1, 2 * dot + 1, black) end
    end
end

local StatsPage = Common.Page:extend{
    title = "My progress",
    plugin = nil,
}

function StatsPage:buildContent(width, height)
    local group = VerticalGroup:new{ align = "left" }
    local history = Store.ratingHistory()
    local rating = Store.playerRating()
    local values = {}
    for _, p in ipairs(history) do values[#values + 1] = p.r end
    local best = rating
    for _, v in ipairs(values) do best = math.max(best, v) end
    group[#group + 1] = Common.paragraph("Your rating: " .. rating .. (best > rating and ("   best " .. best) or ""),
        width, 20, { bold = true })
    group[#group + 1] = Common.vspace(Common.scale(6))
    if #values >= 2 then
        group[#group + 1] = Chart:new{ width = width, height = math.floor(math.min(height * 0.3, width * 0.5)),
            values = values }
        group[#group + 1] = Common.paragraph("Your last " .. #values .. " rated games against bots.", width, 15)
    else
        group[#group + 1] = Common.paragraph("Play a few games against the bots and your rating will be drawn here.",
            width, 17)
    end
    group[#group + 1] = Common.vspace(Common.scale(12))

    local gs = Store.gameStats()
    local function sum(k) return (gs.w[k] or 0) + (gs.b[k] or 0) end
    local played = sum("won") + sum("drawn") + sum("lost")
    local function pct(side)
        local t = gs[side]
        local n = t.won + t.drawn + t.lost
        if n == 0 then return "–" end
        return math.floor((t.won + t.drawn / 2) * 100 / n + 0.5) .. "%"
    end
    local ps = Store.puzzleStats()
    local done, practice_total = LP.progress()

    local cols = width > height and 3 or 2
    local tw = Common.tileWidth(width, cols)
    local tiles = {}
    local function stat(icon, title, subtitle)
        tiles[#tiles + 1] = Common.Tile:new{ width = tw, icon = icon, title = title, subtitle = subtitle,
            show_parent = self }
    end
    stat("play", tostring(played), played == 0 and "games against bots"
        or (sum("won") .. " won · " .. sum("drawn") .. " drawn · " .. sum("lost") .. " lost"))
    stat("trophy", pct("w") .. " / " .. pct("b"), "your score with White / with Black")
    stat("puzzle", tostring(ps.solved), "puzzles solved, " .. ps.failed .. " failed"
        .. (Store.get("puzzle_rating") and (" · Lichess rating " .. Store.get("puzzle_rating")) or ""))
    stat("streak", tostring(ps.best_streak), "puzzles solved in a row · Puzzle Streak best " .. Store.bestStreak())
    stat("practice", done .. " / " .. practice_total, "Lichess Practice lessons done")
    stat("stats", tostring(best), "your best rating")
    group[#group + 1] = Common.tileGrid(tiles, width, cols)
    return group
end

StatsPage.Chart = Chart
return StatsPage
