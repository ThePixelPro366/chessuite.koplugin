--[[
Small popup to choose your colour and the clock before a game.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local Store = require("chessuite/store")

local ColorPicker = {}

local function clockName()
    local id = Store.get("time_control")
    for _, t in ipairs(Store.TIME_CONTROLS) do
        if t.id == id then return t.name end
    end
    return "No clock"
end

-- The next time control in the list.
local function nextClock()
    local id = Store.get("time_control")
    local list = Store.TIME_CONTROLS
    for i, t in ipairs(list) do
        if t.id == id then return list[i % #list + 1].id end
    end
    return list[1].id
end

-- opts.no_color: only "Start" (a game with a friend: White moves first)
function ColorPicker.ask(bot, callback, opts)
    opts = opts or {}
    local dialog
    local function pick(c)
        UIManager:close(dialog)
        if c == "random" then c = math.random() < 0.5 and "w" or "b" end
        callback(c)
    end
    local colors = opts.no_color and { { text = "Start", callback = function() pick("w") end } } or {
        { text = "White", callback = function() pick("w") end },
        { text = "Black", callback = function() pick("b") end },
        { text = "Random", callback = function() pick("random") end },
    }
    dialog = ButtonDialog:new{
        title = opts.title or ("Play " .. bot.name .. (bot.elo and (" (" .. bot.elo .. ")") or "") .. " as"),
        buttons = {
            colors,
            { { text = "⏱ Clock: " .. clockName() .. " (tap to change)", callback = function()
                UIManager:close(dialog)
                Store.set("time_control", nextClock())
                ColorPicker.ask(bot, callback, opts)
            end } },
        },
    }
    UIManager:show(dialog)
end

return ColorPicker
