--[[
Full-screen page that pairs the Chessuite Companion phone app: shows a QR
code of the e-reader's pairing address and waits for the phone to send the
Lichess website login (see chessuite/pairing.lua).
--]]

local QRWidget = require("ui/widget/qrwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Common = require("chessuite/ui/common")
local Pairing = require("chessuite/pairing")
local Store = require("chessuite/store")

local PairPage = Common.Page:extend{
    title = "Connect phone",
    plugin = nil,
}

function PairPage:init()
    self.state = "starting"
    Common.Page.init(self)
    UIManager:nextTick(function() self:startServer() end)
end

function PairPage:startServer()
    Common.whenOnline(function()
        if self.closed then return end
        self.pairing = Pairing:new{
            apk_path = self.plugin.path .. "/companion/chessuite-companion.apk",
            on_done = function(user) self:onPaired(user) end,
        }
        local ok, err = self.pairing:start()
        if ok then
            self.state = "waiting"
        else
            self.state = "error"
            self.error = err
        end
        self:refresh()
    end)
end

function PairPage:onPaired(user)
    if self.closed then return end
    self.state = "checking"
    self.user = user
    self:refresh()
    UIManager:nextTick(function()
        local ok, name = self.plugin:lichess():webAccount(Store.webSession())
        if self.closed then return end
        self.state = ok and "done" or "unverified"
        if ok then self.user = name end
        self.check_error = not ok and tostring(name) or nil
        self:refresh()
    end)
end

function PairPage:buildContent(width, height)
    local group = VerticalGroup:new{ align = "center" }
    local function para(text, size, bold)
        group[#group + 1] = Common.paragraph(text, width, size or 18, { bold = bold })
        group[#group + 1] = Common.vspace(Common.scale(8))
    end
    if self.state == "starting" then
        para("Starting…")
    elseif self.state == "error" then
        para("Could not start: " .. tostring(self.error), 18, true)
        para("Make sure the e-reader is on the same Wi-Fi as your phone, then open this page again.")
    elseif self.state == "waiting" then
        -- measure the texts in their own group: a group must not get new children
        -- after its size was asked for (KOReader keeps the positions it computed then)
        local intro = VerticalGroup:new{
            align = "left",
            Common.paragraph("Let Lichess analyse your games", width, 20, { bold = true }),
            Common.vspace(Common.scale(8)),
            Common.paragraph("1. Scan this code with your phone's camera (same Wi-Fi as this e-reader).\n"
                .. "2. On the page that opens, tap \"Open in Chessuite Companion\". No app yet? The page lets you "
                .. "download it from this e-reader.\n"
                .. "3. Log in to Lichess in the app. Your login is then sent to this e-reader.", width, 17),
        }
        local address = Common.paragraph(self.pairing:url(), width, 16, { alignment = "center" })
        local buttons = Common.buttonBar({ { { text = "Cancel", callback = function() self:onClose() end } } },
            width, self)
        local used = intro:getSize().h + address:getSize().h + buttons:getSize().h + Common.scale(40)
        local qr_size = math.max(Common.scale(120), math.min(width, height - used))
        group[#group + 1] = intro
        group[#group + 1] = Common.vspace(Common.scale(8))
        group[#group + 1] = QRWidget:new{ text = self.pairing:url(), width = qr_size, height = qr_size }
        group[#group + 1] = Common.vspace(Common.scale(6))
        group[#group + 1] = address
        group[#group + 1] = Common.vspace(Common.scale(8))
        group[#group + 1] = buttons
    elseif self.state == "checking" then
        para("Login received from your phone. Checking it with Lichess…", 18, true)
    else
        if self.state == "done" then
            para("Connected!", 22, true)
            para("This e-reader is now logged in to the Lichess website as " .. tostring(self.user) .. ". "
                .. "Game reviews are now made by Lichess' servers.")
        else
            para("Login received, but Lichess did not confirm it.", 20, true)
            para("It will still be tried for the next review. Details: " .. tostring(self.check_error)
                .. "\nSee Lichess account → Lichess log.")
        end
        group[#group + 1] = Common.buttonBar({ { { text = "Close", callback = function() self:onClose() end } } },
            width, self)
    end
    return group
end

function PairPage:onClose()
    self.closed = true
    if self.pairing then self.pairing:stop() end
    return Common.Page.onClose(self)
end

return PairPage
