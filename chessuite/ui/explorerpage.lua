--[[
The Lichess opening explorer, like in the Lichess app: the moves played from
the position on the analysis board, by masters or by Lichess players, with
how often each was played and how the games ended. Tap a move to play it
on the board and look one move further.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local Common = require("chessuite/ui/common")
local Describe = require("chessuite/describe")
local Openings = require("chessuite/openings")
local Store = require("chessuite/store")

-- White / draws / black as a bar, like the explorer's: white, grey, black.
local ResultBar = Widget:extend{ width = 200, height = 20, white = 1, draws = 1, black = 1 }
function ResultBar:getSize() return Geom:new{ w = self.width, h = self.height } end
function ResultBar:paintTo(bb, x, y)
    local total = math.max(1, self.white + self.draws + self.black)
    local w1 = math.floor(self.width * self.white / total)
    local w2 = math.floor(self.width * self.draws / total)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + 1, y + 1, math.max(0, w1 - 1), self.height - 2, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x + w1, y + 1, w2, self.height - 2, Blitbuffer.COLOR_GRAY)
end

local function thousands(n)
    local s = tostring(n)
    while true do
        local t = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
        if t == s then return s end
        s = t
    end
end

local ExplorerPage = Common.Page:extend{
    title = "Opening explorer",
    plugin = nil,
    game = nil,    -- the position (a Chess game)
    on_move = nil, -- function(uci): plays it on the analysis board, returns the new position
    on_back = nil, -- function(): one move back on the analysis board, returns the position
}

function ExplorerPage:init()
    self.db = Store.get("explorer_db") or "masters"
    self.cache = {}
    Common.Page.init(self)
    UIManager:nextTick(function() self:load() end)
end

function ExplorerPage:load()
    if not Store.isLoggedIn() then
        self.error = "The Lichess opening explorer needs a Lichess login: open Lichess account on the start page."
        return self:refresh()
    end
    local key = self.db .. " " .. self.game:fen()
    if self.cache[key] then
        self.data, self.error = self.cache[key], nil
        return self:refresh()
    end
    Common.whenOnline(function()
        local ok, data = Common.busy("Asking the Lichess opening explorer…", function()
            return self.plugin:lichess():explorer(self.db, self.game:fen())
        end)
        if self.closed then return end
        if ok and type(data) == "table" then
            self.cache[key] = data
            self.data, self.error = data, nil
        else
            self.data, self.error = nil, "Lichess did not answer: " .. tostring(data)
        end
        self:refresh()
    end)
end

function ExplorerPage:buildContent(width, height)
    local function tab(id, text)
        return { text = (self.db == id and "★ " or "") .. text, callback = function()
            self.db = id
            Store.set("explorer_db", id)
            self:load()
        end }
    end
    local name = (self.data and self.data.opening and self.data.opening.name) or Openings.current(self.game)
    local group = VerticalGroup:new{
        align = "left",
        Common.buttonBar({ { tab("masters", "Masters"), tab("lichess", "Lichess players") } }, width, self),
        Common.vspace(Common.scale(8)),
        Common.paragraph(name or (self.game:plyCount() == 0 and "Start position" or "Position"), width, 19,
            { bold = true }),
        Common.vspace(Common.scale(8)),
    }
    local footer = Common.buttonBar({ {
        { text = "‹ Move back", enabled = self.game:plyCount() > 0, callback = function() self:back() end },
        { text = "Back to the board", callback = function() self:onClose() end },
    } }, width, self)
    if self.error then
        group[#group + 1] = Common.paragraph(self.error, width, 18)
    elseif self.data then
        local d = self.data
        local total = (d.white or 0) + (d.draws or 0) + (d.black or 0)
        if total == 0 or #(d.moves or {}) == 0 then
            group[#group + 1] = Common.paragraph("No games reached this position.", width, 18)
        else
            group[#group + 1] = Common.paragraph(thousands(total) .. " games · tap a move to play it", width, 16)
            group[#group + 1] = Common.vspace(Common.scale(6))
            local avail = height - group:getSize().h - footer:getSize().h - Common.scale(10)
            local bar_w = math.floor(width * 0.32)
            local text_w = width - bar_w - Common.scale(12)
            local rows = {}
            for _, m in ipairs(d.moves) do
                local mv = self.game:moveFromUci(m.uci)
                if mv then
                    local n = (m.white or 0) + (m.draws or 0) + (m.black or 0)
                    rows[#rows + 1] = {
                        text = Describe.move(self.game, mv) .. "  ·  " .. math.floor(n * 100 / total + 0.5) .. "%  ·  "
                            .. thousands(n),
                        uci = m.uci, m = m,
                    }
                end
            end
            -- as many moves as fit, each a button with its result bar
            local list = VerticalGroup:new{ align = "left" }
            local used = 0
            for _, r in ipairs(rows) do
                local button = Common.buttonBar({ { { text = r.text, callback = function() self:play(r.uci) end } } },
                    text_w, self)
                local line = HorizontalGroup:new{
                    align = "center",
                    button,
                    Common.hspace(Common.scale(12)),
                    ResultBar:new{ width = bar_w, height = Common.scale(18), white = r.m.white or 0,
                        draws = r.m.draws or 0, black = r.m.black or 0 },
                }
                local h = line:getSize().h
                if used + h > avail then break end
                list[#list + 1] = line
                used = used + h
            end
            group = VerticalGroup:new{ align = "left", group, list }
        end
    else
        group[#group + 1] = Common.paragraph("Loading…", width, 18)
    end
    -- the buttons at the bottom of the page
    local spacer = math.max(0, height - group:getSize().h - footer:getSize().h)
    return VerticalGroup:new{ align = "left", group, Common.vspace(spacer), footer }
end

-- Plays a move on the analysis board and looks one move further.
function ExplorerPage:play(uci)
    self.game = self.on_move(uci)
    self:load()
end

-- One move back on the analysis board.
function ExplorerPage:back()
    self.game = self.on_back()
    self:load()
end

function ExplorerPage:onClose()
    self.closed = true
    return Common.Page.onClose(self)
end

return ExplorerPage
