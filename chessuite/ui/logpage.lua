--[[
Full-screen page with the last requests made to Lichess and their answers,
to find out why something failed.
--]]

local Font = require("ui/font")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Common = require("chessuite/ui/common")
local Lichess = require("chessuite/lichess")

local LogPage = Common.Page:extend{
    title = "Lichess log",
}

function LogPage:buildContent(width, height)
    local buttons = Common.buttonBar({ {
        { text = "Refresh", callback = function() self:refresh() end },
        { text = "Clear log", callback = function() Lichess.clearLog(); self:refresh() end },
    } }, width, self)
    local note = Common.paragraph("Newest first. Also saved to " .. (Lichess.logFile() or "?")
        .. ". Your token is never written down.", width, 15)
    local text_h = height - buttons:getSize().h - note:getSize().h - Common.scale(20)
    return VerticalGroup:new{
        align = "left",
        note,
        Common.vspace(Common.scale(8)),
        ScrollTextWidget:new{
            text = Lichess.logText(),
            face = Font:getFace("cfont", 15),
            width = width,
            height = text_h,
            dialog = self,
        },
        Common.vspace(Common.scale(8)),
        buttons,
    }
end

return LogPage
