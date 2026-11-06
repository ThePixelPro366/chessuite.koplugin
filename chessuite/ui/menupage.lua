--[[
A short full-screen list of choices, one big card each (Play, Puzzles,
Analysis on the start page), like the Lichess app's tab screens.
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local Common = require("chessuite/ui/common")

local MenuPage = Common.Page:extend{
    title = "",
    items = nil, -- function(page) returning { { title, subtitle, icon, inverted, callback } }
}

function MenuPage:buildContent(width, height)
    local tiles = {}
    for _, it in ipairs(self.items(self)) do
        tiles[#tiles + 1] = Common.Tile:new{
            width = width, title = it.title, subtitle = it.subtitle, icon = it.icon, badge = it.badge,
            inverted = it.inverted, avatar_size = 56, show_parent = self, callback = it.callback,
        }
    end
    return VerticalGroup:new{ align = "left", Common.tileGrid(tiles, width, 1, Common.scale(12)) }
end

function MenuPage:onClose()
    self.closed = true
    return Common.Page.onClose(self)
end

return MenuPage
