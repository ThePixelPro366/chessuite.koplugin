--[[
Full-screen Lichess account page: log in with a personal API token (a QR
code opens the token page on your phone with the right permissions), see
your puzzle rating and statistics, send queued puzzle results, log out.
--]]

local DataStorage = require("datastorage")
local InputDialog = require("ui/widget/inputdialog")
local QRWidget = require("ui/widget/qrwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Common = require("chessuite/ui/common")
local Lichess = require("chessuite/lichess")
local Puzzles = require("chessuite/puzzles")
local Store = require("chessuite/store")

local AccountScreen = Common.Page:extend{
    title = "Lichess account",
    plugin = nil,
}

function AccountScreen.tokenFile()
    return DataStorage:getDataDir() .. "/lichess_token.txt"
end

-- Remember the Lichess game rating (rapid, else blitz, else classical) so it
-- can be used as your rating here.
function AccountScreen.rememberGameRating(data)
    local perfs = type(data) == "table" and data.perfs or {}
    for _, key in ipairs({ "rapid", "blitz", "classical" }) do
        local p = perfs[key]
        if p and p.rating and (p.games or 0) > 0 then
            Store.set("lichess_game_rating", p.rating)
            if not Store.hasPlayerRating() then Store.setPlayerRating(p.rating) end
            return
        end
    end
end

function AccountScreen:init()
    Common.Page.init(self)
    if Store.isLoggedIn() and not self.loaded then
        UIManager:nextTick(function() self:loadAccount(true) end)
    end
end

function AccountScreen:buildContent(width, height)
    if Store.isLoggedIn() then return self:buildLoggedIn(width, height) end
    return self:buildLogin(width, height)
end

function AccountScreen:buildLogin(width, height)
    local intro = Common.paragraph(
        "Log in to solve Lichess puzzles that count for your Lichess puzzle rating.\n\n"
        .. "1. Scan this code with your phone. It opens Lichess with the right permissions already selected "
        .. "(read and solve puzzles).\n"
        .. "2. Tap \"Create\" on Lichess. You get a token that starts with lip_.\n"
        .. "3. Tap \"Enter token\" below and type it. Or save it in the file "
        .. AccountScreen.tokenFile() .. " and tap \"Load from file\".",
        width, 18)
    local buttons = Common.buttonBar({ {
        { text = "Enter token", callback = function() self:askToken() end },
        { text = "Load from file", callback = function() self:loadTokenFile() end },
    }, self:phoneRow() }, width, self)
    local qr_size = math.min(width, height - intro:getSize().h - buttons:getSize().h - Common.scale(40))
    qr_size = math.max(qr_size, Common.scale(120))
    local qr = QRWidget:new{ text = Lichess.tokenCreateUrl(), width = qr_size, height = qr_size }
    return VerticalGroup:new{
        align = "center",
        intro,
        Common.vspace(Common.scale(10)),
        Common.centered(qr, width, qr_size),
        Common.vspace(Common.scale(10)),
        buttons,
    }
end

function AccountScreen:buildLoggedIn(width, height)
    local acc = self.account or {}
    local perfs = acc.perfs or {}
    local function rating(key)
        local p = perfs[key]
        return p and p.rating and (tostring(p.rating) .. (p.prov and "?" or "")) or "-"
    end
    local st = Store.puzzleStats()
    local lines = {
        "Puzzle rating: " .. (rating("puzzle") ~= "-" and rating("puzzle") or tostring(Store.get("puzzle_rating") or "?")),
        "Blitz " .. rating("blitz") .. " · Rapid " .. rating("rapid") .. " · Classical " .. rating("classical"),
        "",
        "Puzzles on this device: " .. st.solved .. " solved, " .. st.failed .. " failed",
        "Current streak: " .. st.streak .. " · best streak: " .. st.best_streak,
        "Results waiting to be sent to Lichess: " .. #Store.pendingResults(),
    }
    local dash = self.dashboard and self.dashboard.global
    if dash then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Last 30 days on Lichess: " .. (dash.nb or 0) .. " puzzles, "
            .. (dash.firstWins or 0) .. " solved on the first try"
        if dash.performance then lines[#lines + 1] = "Puzzle performance: " .. dash.performance end
    end
    local header = HorizontalGroup:new{
        align = "center",
        Common.Avatar:new{ letter = (Store.username() or "?"):sub(1, 1):upper(), size = Common.scale(64), inverted = true },
        Common.hspace(),
        Common.label(Store.username() or "Logged in", 26, true, nil, width - Common.scale(90)),
    }
    local buttons = Common.buttonBar({
        {
            { text = "Refresh", callback = function() self:loadAccount(false) end },
            { text = "Send results", callback = function() self:syncNow() end },
        },
        self:phoneRow(),
        {
            { text = "Lichess log", callback = function()
                UIManager:show(require("chessuite/ui/logpage"):new{})
            end },
            { text = "Log out", callback = function()
                Store.logout()
                self.account = nil
                self.dashboard = nil
                if self.plugin then self.plugin:resetLichess() end
                self:refresh()
            end },
        },
    }, width, self)
    return VerticalGroup:new{
        align = "left",
        header,
        Common.vspace(Common.scale(16)),
        Common.paragraph(table.concat(lines, "\n"), width, 20),
        Common.vspace(Common.scale(16)),
        buttons,
    }
end

-- The website login from the companion app, for Lichess' game analysis.
function AccountScreen:phoneRow()
    local web = Store.webSession()
    if web then
        return {
            { text = "Analysis login: " .. tostring(web.user or "?"), enabled = false },
            { text = "Forget phone login", callback = function()
                Store.forgetWebSession()
                self:refresh()
            end },
        }
    end
    return { { text = "Connect phone for Lichess analysis", callback = function()
        local PairPage = require("chessuite/ui/pairpage")
        UIManager:show(PairPage:new{ plugin = self.plugin, on_close = function()
            if not self.closed then self:refresh() end
        end })
    end } }
end

-- Login ------------------------------------------------------------------------

function AccountScreen:askToken()
    local dialog
    dialog = InputDialog:new{
        title = "Lichess API token",
        input = "lip_",
        input_hint = "lip_…",
        buttons = { {
            { text = "Cancel", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "Log in", is_enter_default = true, callback = function()
                local t = dialog:getInputText()
                UIManager:close(dialog)
                self:login(t)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AccountScreen:loadTokenFile()
    local f = io.open(AccountScreen.tokenFile(), "r")
    if not f then
        Common.info("No file found at " .. AccountScreen.tokenFile())
        return
    end
    local t = f:read("*a")
    f:close()
    self:login(t)
end

function AccountScreen:login(token)
    token = (token or ""):gsub("%s", "")
    if token == "" or token == "lip_" then return end
    Common.whenOnline(function()
        local client = Lichess:new{ token = token }
        local ok, data = Common.busy("Checking the token with Lichess…", function() return client:account() end)
        if not ok or type(data) ~= "table" or not data.username then
            Common.info("Login failed: " .. tostring(data))
            return
        end
        local _, scopes = client:testToken(token)
        local s = type(scopes) == "table" and scopes[token] and scopes[token].scopes or ""
        Store.set("lichess_token", token)
        Store.set("lichess_username", data.username)
        Store.set("lichess_user_id", data.id)
        if data.perfs and data.perfs.puzzle then Store.set("puzzle_rating", data.perfs.puzzle.rating) end
        AccountScreen.rememberGameRating(data)
        if self.plugin then self.plugin:resetLichess() end
        self.account = data
        -- the token file is not needed anymore
        os.remove(AccountScreen.tokenFile())
        if type(s) == "string" and not s:find("puzzle:write", 1, true) then
            Common.info("Logged in, but this token cannot send puzzle results. Create a new token with "
                .. "\"Solve puzzles\" allowed (the QR code selects it for you).")
        else
            Common.info("Welcome, " .. data.username .. "!", 2)
        end
        self:refresh()
    end)
end

function AccountScreen:loadAccount(quiet)
    self.loaded = true
    local NetworkMgr = require("ui/network/manager")
    if quiet and not NetworkMgr:isOnline() then return end
    Common.whenOnline(function()
        local client = self.plugin:lichess()
        local ok, data = Common.busy("Loading your Lichess profile…", function() return client:account() end)
        if ok and type(data) == "table" then
            self.account = data
            if data.perfs and data.perfs.puzzle then Store.set("puzzle_rating", data.perfs.puzzle.rating) end
            AccountScreen.rememberGameRating(data)
            local ok2, dash = client:puzzleDashboard(30)
            if ok2 and type(dash) == "table" then self.dashboard = dash end
        elseif not quiet then
            Common.info("Could not load your profile: " .. tostring(data))
        end
        if not self.closed then self:refresh() end
    end)
end

function AccountScreen:syncNow()
    Common.whenOnline(function()
        local client = self.plugin:lichess()
        local ok, info = Common.busy("Sending puzzle results…", function() return Puzzles.sync(client) end)
        if ok then
            Common.info("All results sent." .. (info and info.rating and (" Puzzle rating: " .. info.rating) or ""), 3)
        else
            Common.info("Could not send results: " .. tostring(info))
        end
        self:refresh()
    end)
end

function AccountScreen:onClose()
    self.closed = true
    return Common.Page.onClose(self)
end

return AccountScreen
