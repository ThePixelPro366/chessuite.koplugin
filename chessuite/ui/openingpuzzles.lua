--[[
Puzzles by opening, like the Lichess app (Puzzles → Themes → By openings):
the openings that have puzzles, most played first, then their variations.
The puzzles come from real games in that opening, so you learn its typical
tactics. The list is kept for offline use, and so are the puzzles you got.
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Common = require("chessuite/ui/common")
local Puzzles = require("chessuite/puzzles")
local Store = require("chessuite/store")

local MAX_VARIATIONS = 12 -- kept per opening

local OpeningPuzzles = Common.Page:extend{
    title = "Puzzles by opening",
    plugin = nil,
    family = nil, -- set: the variations of this opening { key, name, count, openings }
}

function OpeningPuzzles:init()
    self.page = 1
    if self.family then self.title = self.family.name end
    Common.Page.init(self)
    if not self.family then UIManager:nextTick(function() self:load() end) end
end

-- The list from Lichess, or the one kept from last time when offline.
function OpeningPuzzles:load()
    local function fromLichess()
        local ok, data = Common.busy("Loading the openings from Lichess…", function()
            return self.plugin:lichess():puzzleOpenings()
        end)
        if self.closed then return end
        if ok and type(data) == "table" and type(data.openings) == "table" then
            local list = {}
            for _, o in ipairs(data.openings) do
                local f = o.family
                if f and f.key then
                    local vars = {}
                    for i, v in ipairs(o.openings or {}) do
                        if i > MAX_VARIATIONS then break end
                        vars[#vars + 1] = { key = v.key, name = v.name, count = v.count }
                    end
                    list[#list + 1] = { key = f.key, name = f.name, count = f.count, openings = vars }
                end
            end
            Store.set("puzzle_openings", list)
            self.families = list
        else
            self.error = tostring(data)
            self.families = Store.get("puzzle_openings")
        end
        self:refresh()
    end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isOnline() then return fromLichess() end
    self.families = Store.get("puzzle_openings")
    if self.families then return self:refresh() end
    Common.whenOnline(fromLichess)
end

local function countWords(n)
    if not n then return "" end
    if n >= 1000 then return math.floor(n / 1000 + 0.5) .. "k puzzles" end
    return n .. " puzzles"
end

function OpeningPuzzles:entries()
    local saved = Puzzles.cachedAngles()
    local function badge(key) return saved[key] and (saved[key] .. " saved") or nil end
    local out = {}
    if self.family then
        out[#out + 1] = { title = "All " .. self.family.name, subtitle = countWords(self.family.count),
            badge = badge(self.family.key), opening = self.family }
        for _, v in ipairs(self.family.openings or {}) do
            out[#out + 1] = { title = v.name, subtitle = countWords(v.count), badge = badge(v.key), opening = v,
                full_name = self.family.name .. ": " .. v.name }
        end
        return out
    end
    for _, f in ipairs(self.families or {}) do
        out[#out + 1] = { title = f.name, subtitle = countWords(f.count)
            .. (#(f.openings or {}) > 0 and (" · " .. #f.openings .. (#f.openings == 1 and " variation" or " variations"))
                or ""),
            badge = badge(f.key), family = f }
    end
    return out
end

function OpeningPuzzles:buildContent(width, height)
    local group = VerticalGroup:new{ align = "left" }
    if not self.family then
        group[#group + 1] = Common.paragraph("Puzzles from real games in an opening: learn its typical tactics and traps. "
            .. "They count for your Lichess puzzle rating.", width, 17)
        group[#group + 1] = Common.vspace(Common.scale(10))
    end
    local entries = self:entries()
    if #entries == 0 then
        group[#group + 1] = Common.paragraph(self.error and ("Could not load the openings: " .. self.error)
            or "Loading…", width, 18)
        return group
    end
    local nav_h = Common.scale(60)
    local tile_h = Common.Tile:new{ width = width, title = "X", subtitle = "X", icon = "puzzle" }:getSize().h
        + Common.scale(8)
    local per_page = math.max(1, math.floor((height - group:getSize().h - nav_h) / tile_h))
    local pages = math.ceil(#entries / per_page)
    self.page = math.max(1, math.min(self.page, pages))
    local tiles = {}
    for i = (self.page - 1) * per_page + 1, math.min(#entries, self.page * per_page) do
        local e = entries[i]
        tiles[#tiles + 1] = Common.Tile:new{
            width = width, title = e.title, subtitle = e.subtitle, badge = e.badge, icon = "puzzle",
            show_parent = self,
            callback = function()
                if e.family and #(e.family.openings or {}) > 0 then
                    UIManager:show(OpeningPuzzles:new{ plugin = self.plugin, family = e.family,
                        on_close = function() if not self.closed then self:refresh() end end })
                else
                    self:solve(e.opening or e.family, e.full_name)
                end
            end,
        }
    end
    local list = VerticalGroup:new{ align = "left", group, Common.tileGrid(tiles, width, 1, Common.scale(8)) }
    if pages > 1 then
        list[#list + 1] = Common.vspace(Common.scale(8))
        list[#list + 1] = Common.buttonBar({ {
            { text = "‹", enabled = self.page > 1, callback = function() self.page = self.page - 1; self:refresh() end },
            { text = self.page .. " / " .. pages, enabled = false },
            { text = "›", enabled = self.page < pages, callback = function() self.page = self.page + 1; self:refresh() end },
        } }, width, self)
    end
    return list
end

function OpeningPuzzles:solve(opening, full_name)
    UIManager:show(require("chessuite/ui/puzzlescreen"):new{
        plugin = self.plugin,
        opening = { key = opening.key, name = full_name or opening.name },
        on_close = function() if not self.closed then self:refresh() end end,
    })
end

function OpeningPuzzles:onClose()
    self.closed = true
    return Common.Page.onClose(self)
end

return OpeningPuzzles
