--[[
Full-screen list of your finished games, to review them: the games played
on this device, and your last games on Lichess.
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Bots = require("chessuite/bots")
local Common = require("chessuite/ui/common")
local Store = require("chessuite/store")

local GamesPage = Common.Page:extend{
    title = "My games",
    plugin = nil,
    on_pick = nil,
    per_page = 5,
}

function GamesPage:init()
    self.page = 1
    self.tab = "device"
    Common.Page.init(self)
end

local function outcome(entry)
    if entry.result == "*" then return "Unfinished" end
    if entry.result == "1/2-1/2" then return "Draw" end
    if entry.friend then return entry.result == "1-0" and "White won" or "Black won" end
    local won = (entry.result == "1-0" and entry.color == "w") or (entry.result == "0-1" and entry.color == "b")
    return won and "You won" or "You lost"
end

-- The Lichess name to load games for: the token login, else the phone login.
local function lichessName()
    if Store.username() then return Store.username() end
    local web = Store.webSession()
    return web and web.user
end

function GamesPage:loadLichess()
    local name = lichessName()
    if not name or not self.plugin then return end
    Common.whenOnline(function()
        local ok, games = Common.busy("Loading your games from Lichess…", function()
            return self.plugin:lichess():userGames(name, 30)
        end)
        if self.closed then return end
        if ok then
            self.lichess_games = games
            self.lichess_error = nil
        else
            self.lichess_error = tostring(games)
        end
        self:refresh()
    end)
end

function GamesPage:buildContent(width, height)
    local group = VerticalGroup:new{ align = "left" }
    local function tab(id, text)
        return { text = (self.tab == id and "★ " or "") .. text, callback = function()
            self.tab = id
            self.page = 1
            self:refresh()
            if id == "lichess" and not self.lichess_games then self:loadLichess() end
        end }
    end
    group[#group + 1] = Common.buttonBar({ { tab("device", "On this device"), tab("lichess", "On Lichess") } },
        width, self)
    group[#group + 1] = Common.vspace(Common.scale(12))

    local games
    if self.tab == "lichess" then
        if not lichessName() then
            group[#group + 1] = Common.paragraph("Log in to Lichess (Lichess account on the start page) to see "
                .. "your games from lichess.org here.", width, 20)
            return group
        end
        if self.lichess_error then
            group[#group + 1] = Common.paragraph("Could not load your games: " .. self.lichess_error, width, 18)
            group[#group + 1] = Common.vspace(Common.scale(8))
            group[#group + 1] = Common.buttonBar({ { { text = "Try again", callback = function() self:loadLichess() end } } },
                width, self)
            return group
        end
        games = {}
        for _, g in ipairs(self.lichess_games or {}) do
            games[#games + 1] = { pgn = g.pgn, color = g.color, result = g.result, opponent = g.opponent,
                date = g.date, lichess_id = g.id, opening = g.opening, analysed = g.analysed, speed = g.speed }
        end
        if not self.lichess_games then
            group[#group + 1] = Common.paragraph("Loading…", width, 20)
            return group
        end
    else
        games = Store.recentGames()
    end
    if #games == 0 then
        group[#group + 1] = Common.paragraph(self.tab == "lichess" and "No standard chess games on Lichess yet."
            or "No finished games yet. Play a game and it will show up here for review.", width, 20)
        return group
    end
    local pages = math.ceil(#games / self.per_page)
    self.page = math.max(1, math.min(self.page, pages))
    local tiles = {}
    for i = (self.page - 1) * self.per_page + 1, math.min(#games, self.page * self.per_page) do
        local e = games[i]
        local bot
        for _, b in ipairs(Bots.ROSTER) do if b.name == e.opponent then bot = b end end
        local details = { e.date or "" }
        if e.speed then details[#details + 1] = e.speed end
        details[#details + 1] = e.friend and "with a friend" or ("you played " .. (e.color == "b" and "Black" or "White"))
        if e.opening then details[#details + 1] = e.opening end
        tiles[#tiles + 1] = Common.Tile:new{
            width = width,
            title = (e.friend and "Friend game" or ("vs " .. (e.opponent or "?"))) .. " · " .. outcome(e),
            badge = e.analysed and "analysed" or nil,
            subtitle = table.concat(details, " · ") .. ". Tap to review.",
            piece = bot and Bots.pieceFor(bot) or nil,
            icon = e.friend and "friend" or (e.lichess_id and "download") or (not bot and "play") or nil,
            show_parent = self,
            callback = function()
                UIManager:close(self)
                if self.on_pick then self.on_pick(e) end
            end,
        }
    end
    group[#group + 1] = Common.tileGrid(tiles, width, 1, Common.scale(10))
    if pages > 1 then
        group[#group + 1] = Common.vspace(Common.scale(12))
        group[#group + 1] = Common.buttonBar({ {
            { text = "‹ Newer", enabled = self.page > 1, callback = function() self.page = self.page - 1; self:refresh() end },
            { text = self.page .. " / " .. pages, enabled = false },
            { text = "Older ›", enabled = self.page < pages, callback = function() self.page = self.page + 1; self:refresh() end },
        } }, width, self)
    end
    return group
end

function GamesPage:onClose()
    self.closed = true
    return Common.Page.onClose(self)
end

return GamesPage
