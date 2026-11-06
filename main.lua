--[[
Chessuite: chess for KOReader.

Opens a full-screen home page from the main menu (Tools) or from a gesture
(Dispatcher action "Chessuite"). Everything else lives on full-screen pages,
see chessuite/ui/.
--]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- KOReader only puts the plugin folder on package.path while this file is
-- being loaded, so every module the pages require later on is loaded now.
local MODULES = {
    "chessuite/chess", "chessuite/describe", "chessuite/uci", "chessuite/lichess", "chessuite/store",
    "chessuite/bots", "chessuite/openings", "chessuite/tactics", "chessuite/explain", "chessuite/positional",
    "chessuite/coach",
    "chessuite/puzzles",
    "chessuite/ui/common", "chessuite/ui/boardwidget", "chessuite/ui/colorpicker", "chessuite/ui/movelistpage",
    "chessuite/pairing", "chessuite/ui/pairpage", "chessuite/ui/logpage", "chessuite/ui/gamespage", "chessuite/ui/gamescreen", "chessuite/ui/analysisscreen", "chessuite/ui/puzzlescreen",
    "chessuite/lichesspractice", "chessuite/ui/lessonscreen", "chessuite/ui/practicescreen", "chessuite/ui/explorerpage",
    "chessuite/ui/statspage", "chessuite/ui/menupage", "chessuite/ui/explainpage",
    "chessuite/ui/openingpuzzles", "chessuite/repertoire", "chessuite/ui/repertoirescreen",
    "chessuite/ui/accountscreen", "chessuite/ui/opponentscreen", "chessuite/ui/homescreen",
}
for i = 1, #MODULES do require(MODULES[i]) end

local Chessuite = WidgetContainer:extend{
    name = "chessuite",
    is_doc_only = false,
}

function Chessuite:onDispatcherRegisterActions()
    Dispatcher:registerAction("chessuite_open", {
        category = "none",
        event = "ChessuiteOpen",
        title = _("Chessuite"),
        general = true,
    })
end

function Chessuite:init()
    local Common = require("chessuite/ui/common")
    Common.plugin_dir = self.path
    local ok, meta = pcall(dofile, self.path .. "/_meta.lua")
    if ok and type(meta) == "table" then Common.version = meta.version end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Chessuite:addToMainMenu(menu_items)
    menu_items.chessuite = {
        text = _("Chess (Chessuite)"),
        sorting_hint = "tools",
        callback = function() self:openHome() end,
    }
end

function Chessuite:onChessuiteOpen()
    self:openHome()
    return true
end

function Chessuite:openHome()
    local HomeScreen = require("chessuite/ui/homescreen")
    UIManager:show(HomeScreen:new{ plugin = self })
end

-- The bundled Stockfish, started on first use and shared by all pages.
function Chessuite:getEngine()
    if not self.engine then
        local Engine = require("chessuite/uci")
        local Store = require("chessuite/store")
        local path = Store.get("engine_path")
        if not path or path == "" then
            local name = Engine.bundledBinaryName()
            path = name and (self.path .. "/bin/" .. name)
        end
        logger.info("chessuite: engine", path)
        self.engine = Engine:new{
            path = path,
            threads = Store.get("engine_threads"),
            hash = Store.get("engine_hash"),
        }
        -- Maia3, the human-like engine the beginner bots play with
        local maia = Engine.bundledBinaryName("maia3")
        if maia then self.engine.maia = Engine:new{ path = self.path .. "/bin/" .. maia } end
    end
    return self.engine
end

function Chessuite:stopEngine()
    if self.engine then
        self.engine:quit()
        if self.engine.maia then self.engine.maia:quit() end
    end
end

function Chessuite:lichess()
    if not self.lichess_client then
        local Lichess = require("chessuite/lichess")
        local Store = require("chessuite/store")
        self.lichess_client = Lichess:new{ token = Store.token() }
    end
    return self.lichess_client
end

function Chessuite:resetLichess()
    self.lichess_client = nil
end

function Chessuite:onCloseWidget()
    self:stopEngine()
end

return Chessuite
