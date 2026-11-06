--[[
Full-screen opponent picker: bots with personalities grouped by strength,
the coaches, and plain Stockfish levels.
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Bots = require("chessuite/bots")
local Common = require("chessuite/ui/common")
local Store = require("chessuite/store")

local OpponentScreen = Common.Page:extend{
    title = "Choose your opponent",
    plugin = nil,
}

local TABS = {
    { id = "special", name = "Coaches" },
    { id = "beginner", name = "Beginner" },
    { id = "intermediate", name = "Intermediate" },
    { id = "advanced", name = "Advanced" },
    { id = "master", name = "Master" },
    { id = "stockfish", name = "Stockfish" },
}

function OpponentScreen:init()
    self.tab = Store.get("opponent_tab") or "special"
    Common.Page.init(self)
end

function OpponentScreen:buildContent(width, height)
    local rows = { {}, {} }
    for i, t in ipairs(TABS) do
        local r = i <= 3 and rows[1] or rows[2]
        r[#r + 1] = {
            text = (self.tab == t.id and "★ " or "") .. t.name,
            callback = function()
                self.tab = t.id
                Store.set("opponent_tab", t.id)
                self:refresh()
            end,
        }
    end
    local tabs = Common.buttonBar(rows, width, self)
    local rating = Store.playerRating()
    local function badge(elo)
        if math.abs(elo - rating) <= 200 then return elo .. " · good match" end
        return tostring(elo)
    end
    local group = VerticalGroup:new{
        align = "left",
        Common.paragraph("Your rating: " .. rating .. (Store.hasPlayerRating() and "" or " (change it in Settings)"),
            width, 18, { bold = true }),
        Common.vspace(Common.scale(8)),
        tabs,
        Common.vspace(Common.scale(12)),
    }

    local tiles = {}
    if self.tab == "stockfish" then
        local last = Store.get("stockfish_elo") or rating
        group[#group + 1] = Common.Tile:new{
            width = width,
            inverted = true,
            title = "Stockfish at any rating",
            subtitle = "Choose from 100 to 3200 Elo. Just the engine: no chat, no personality. Below 1000 the "
                .. "human-like Maia engine plays. Last time: " .. last .. ".",
            icon = "engine",
            show_parent = self,
            callback = function() self:askStockfishElo(last) end,
        }
        group[#group + 1] = Common.vspace(Common.scale(12))
        local tw = Common.tileWidth(width, 2)
        for _, l in ipairs(Bots.LEVELS) do
            local b = Bots.levelBot(l.level)
            tiles[#tiles + 1] = Common.Tile:new{
                width = tw,
                title = "Level " .. l.level,
                subtitle = "About " .. l.elo .. " Elo" .. (math.abs(l.elo - rating) <= 200 and ", good match" or ""),
                letter = tostring(l.level),
                show_parent = self,
                callback = function() self:pick(b) end,
            }
        end
        group[#group + 1] = Common.tileGrid(tiles, width, 2)
    else
        for _, b in ipairs(Bots.ROSTER) do
            if b.tier == self.tab then
                tiles[#tiles + 1] = Common.Tile:new{
                    width = width,
                    title = b.name,
                    badge = b.is_coach and ("plays at " .. rating) or badge(b.elo),
                    subtitle = b.tagline .. ". " .. b.description,
                    piece = Bots.pieceFor(b),
                    icon = b.is_coach and "coach" or nil,
                    inverted = b.is_coach,
                    show_parent = self,
                    callback = function() self:pick(b) end,
                }
            end
        end
        group[#group + 1] = Common.tileGrid(tiles, width, 1, Common.scale(10))
    end
    return group
end

function OpponentScreen:askStockfishElo(value)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = "Stockfish strength (Elo)",
        info_text = "Below 1000 the human-like Maia engine plays: it makes the mistakes people at that "
            .. "rating make. 100 has just learned the moves, 800 is a beginner, 1500 a club player, "
            .. "3200 is Stockfish at full strength.",
        value = value,
        value_min = 100,
        value_max = 3200,
        value_step = 50,
        value_hold_step = 250,
        ok_text = "Play",
        ok_always_enabled = true, -- playing at the same strength again is fine
        callback = function(spin)
            Store.set("stockfish_elo", spin.value)
            self:pick(Bots.stockfishAt(spin.value))
        end,
    })
end

function OpponentScreen:pick(bot)
    local ColorPicker = require("chessuite/ui/colorpicker")
    ColorPicker.ask(bot, function(color)
        local GameScreen = require("chessuite/ui/gamescreen")
        UIManager:close(self)
        Store.clearSavedGame()
        UIManager:show(GameScreen:new{ plugin = self.plugin, bot = bot, player_color = color,
            on_close = self.on_close })
    end)
end

return OpponentScreen
