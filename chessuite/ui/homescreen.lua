--[[
The plugin's start page: big cards for everything it can do.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Bots = require("chessuite/bots")
local Common = require("chessuite/ui/common")
local Store = require("chessuite/store")

local HomeScreen = Common.Page:extend{
    title = "Chessuite",
    plugin = nil,
}

function HomeScreen:init()
    self.left_icon = "appbar.settings"
    self.left_icon_tap_callback = function() self:showSettings() end
    self.subtitle = Store.isLoggedIn() and ("Lichess: " .. (Store.username() or "logged in")) or "Not logged in to Lichess"
    Common.Page.init(self)
end

function HomeScreen:open(widget_class, args)
    args = args or {}
    args.plugin = self.plugin
    args.on_close = function() if not self.closed then self:refreshHome() end end
    UIManager:show(widget_class:new(args))
end

function HomeScreen:refreshHome()
    self.subtitle = Store.isLoggedIn() and ("Lichess: " .. (Store.username() or "logged in")) or "Not logged in to Lichess"
    self:refresh()
end

-- Opens a short list of choices (a MenuPage) that stays up to date.
function HomeScreen:menu(title, items)
    local MenuPage = require("chessuite/ui/menupage")
    local page
    page = MenuPage:new{ title = title, items = items, plugin = self.plugin,
        on_close = function() if not self.closed then self:refreshHome() end end }
    UIManager:show(page)
end

-- Opens a page from a menu page; the menu page is brought up to date when it closes.
local function openFrom(menu, widget_class, args)
    args = args or {}
    args.plugin = menu.plugin
    args.on_close = function() if not menu.closed then menu:refresh() end end
    UIManager:show(widget_class:new(args))
end

function HomeScreen:playItems(menu)
    local items = {}
    local saved = Store.savedGame()
    local saved_bot = saved and saved.bot_id and Bots.get(saved.bot_id)
    if saved_bot then
        items[#items + 1] = {
            title = "Continue your game", inverted = true, icon = "continue",
            subtitle = (saved_bot.human and "with a friend" or ("vs " .. saved_bot.name)) .. " · "
                .. math.floor(#(saved.moves or {}) / 2) .. " moves played",
            callback = function() openFrom(menu, require("chessuite/ui/gamescreen"), { bot = saved_bot, resume = saved }) end,
        }
    end
    items[#items + 1] = { title = "Play a bot", icon = "play", subtitle = "Bots with personalities from 250 to 3200, "
        .. "and Stockfish at any strength. Your rating: " .. Store.playerRating() .. ".",
        callback = function() openFrom(menu, require("chessuite/ui/opponentscreen")) end }
    items[#items + 1] = { title = "Learn with Coach", icon = "coach",
        subtitle = "Plays at your level and explains every move in plain words.",
        callback = function()
            local coach = Bots.get("coach")
            require("chessuite/ui/colorpicker").ask(coach, function(color)
                Store.clearSavedGame()
                openFrom(menu, require("chessuite/ui/gamescreen"), { bot = coach, player_color = color })
            end)
        end }
    items[#items + 1] = { title = "Play a friend", icon = "friend",
        subtitle = "Two players on this device, with a chess clock if you like.",
        callback = function()
            require("chessuite/ui/colorpicker").ask(Bots.FRIEND, function()
                Store.clearSavedGame()
                openFrom(menu, require("chessuite/ui/gamescreen"), { bot = Bots.FRIEND, player_color = "w" })
            end, { no_color = true, title = "Play a friend on this device" })
        end }
    return items
end

function HomeScreen:puzzleItems(menu)
    local rating = Store.get("puzzle_rating")
    return {
        { title = "Puzzles", icon = "puzzle",
          subtitle = Store.isLoggedIn() and ("Rated Lichess puzzles" .. (rating and (", your rating " .. rating) or "")
              .. ". Work offline too.") or "Log in to Lichess to solve puzzles that count for your rating.",
          callback = function()
              if Store.isLoggedIn() then
                  openFrom(menu, require("chessuite/ui/puzzlescreen"))
              else
                  openFrom(menu, require("chessuite/ui/accountscreen"))
              end
          end },
        { title = "Puzzle Streak", icon = "streak",
          subtitle = "Puzzles get harder, one mistake ends the run. Your best: " .. Store.bestStreak() .. ".",
          callback = function() openFrom(menu, require("chessuite/ui/puzzlescreen"), { streak = true }) end },
        { title = "Puzzles by opening", icon = "opening",
          subtitle = Store.isLoggedIn() and "Learn an opening's typical tactics, with puzzles from real games in it."
              or "Log in to Lichess first.",
          callback = function()
              if Store.isLoggedIn() then
                  openFrom(menu, require("chessuite/ui/openingpuzzles"))
              else
                  openFrom(menu, require("chessuite/ui/accountscreen"))
              end
          end },
        { title = "Daily puzzle", icon = "daily", subtitle = "Today's Lichess puzzle. No account needed.",
          callback = function()
              openFrom(menu, require("chessuite/ui/puzzlescreen"), { daily = true, title = "Daily puzzle" })
          end },
    }
end

function HomeScreen:learnItems(menu)
    local Repertoire = require("chessuite/repertoire")
    local done, total = require("chessuite/lichesspractice").progress()
    local due, mastered, lines = 0, 0, 0
    for _, op in ipairs(Repertoire.openings()) do
        local s = Repertoire.summary(op)
        if s.seen > 0 then due = due + s.due end
        mastered = mastered + s.mastered
        lines = lines + s.total
    end
    return {
        { title = "Openings", icon = "opening",
          subtitle = "Learn opening lines move by move, then drill them with spaced repetition. " .. mastered .. " of "
              .. lines .. " lines mastered" .. (due > 0 and (", " .. due .. " due") or "") .. ".",
          callback = function() openFrom(menu, require("chessuite/ui/repertoirescreen")) end },
        { title = "Practice", icon = "practice",
          subtitle = "Lichess Practice: checkmates, tactics, endgames. " .. done .. " of " .. total .. " lessons done.",
          callback = function() openFrom(menu, require("chessuite/ui/practicescreen")) end },
    }
end

function HomeScreen:analysisItems(menu)
    return {
        { title = "Analysis board", icon = "analysis",
          subtitle = "Stockfish, the Lichess cloud and the opening explorer.",
          callback = function() openFrom(menu, require("chessuite/ui/analysisscreen")) end },
        { title = "Review my games", icon = "review",
          subtitle = "Your games from this device or from Lichess, with accuracy and mistakes.",
          callback = function()
              local GamesPage = require("chessuite/ui/gamespage")
              local Chess = require("chessuite/chess")
              UIManager:show(GamesPage:new{ plugin = self.plugin,
                  on_pick = function(entry)
                      local g = Chess.fromPgn(entry.pgn)
                      if g then
                          openFrom(menu, require("chessuite/ui/analysisscreen"),
                              { game = g, review = true, player_color = entry.color, title = "Game review",
                                lichess_game_id = entry.lichess_id })
                      end
                  end,
              })
          end },
        { title = "My progress", icon = "stats", subtitle = "Your rating chart, results and records.",
          callback = function() openFrom(menu, require("chessuite/ui/statspage")) end },
    }
end

function HomeScreen:buildContent(width, height)
    local group = VerticalGroup:new{ align = "left" }
    -- a line about where you stand
    local facts = { "Rating " .. Store.playerRating() }
    if Store.get("puzzle_rating") then facts[#facts + 1] = "puzzles " .. Store.get("puzzle_rating") end
    if Store.bestStreak() > 0 then facts[#facts + 1] = "best streak " .. Store.bestStreak() end
    group[#group + 1] = Common.paragraph(table.concat(facts, "  ·  "), width, 17, { bold = true })
    group[#group + 1] = Common.vspace(Common.scale(12))

    local saved = Store.savedGame()
    local saved_bot = saved and saved.bot_id and Bots.get(saved.bot_id)
    local cards = {
        { title = "Play", icon = "play",
          subtitle = saved_bot and "A game is waiting for you." or "Bots, Coach, or a friend on this device.",
          callback = function() self:menu("Play", function(m) return self:playItems(m) end) end },
        { title = "Puzzles", icon = "puzzle", subtitle = "Lichess puzzles, by opening, Puzzle Streak, daily puzzle.",
          callback = function() self:menu("Puzzles", function(m) return self:puzzleItems(m) end) end },
        { title = "Learn", icon = "opening",
          subtitle = "Openings, and Lichess Practice: checkmates, tactics, endgames.",
          callback = function() self:menu("Learn", function(m) return self:learnItems(m) end) end },
        { title = "Analysis", icon = "analysis", subtitle = "Analysis board, game reviews, your progress.",
          callback = function() self:menu("Analysis", function(m) return self:analysisItems(m) end) end },
    }
    local landscape = width > height
    local cols = landscape and 2 or 1
    local tiles = {}
    for _, c in ipairs(cards) do
        tiles[#tiles + 1] = Common.Tile:new{ width = Common.tileWidth(width, cols), title = c.title, subtitle = c.subtitle,
            icon = c.icon, avatar_size = 64, show_parent = self, callback = c.callback }
    end
    group[#group + 1] = Common.tileGrid(tiles, width, cols, Common.scale(14))
    return group
end

-- Quick settings popup -------------------------------------------------------------

function HomeScreen:showSettings()
    local dialog
    local function toggle(label, key, on_text, off_text)
        return {
            text = label .. ": " .. (Store.get(key) and (on_text or "on") or (off_text or "off")),
            callback = function()
                Store.toggle(key)
                UIManager:close(dialog)
                self:showSettings()
            end,
        }
    end
    local function cycle(label, key, values, names)
        local cur = Store.get(key)
        local idx = 1
        for i, v in ipairs(values) do if v == cur then idx = i end end
        return {
            text = label .. ": " .. names[idx],
            callback = function()
                Store.set(key, values[idx % #values + 1])
                UIManager:close(dialog)
                self:showSettings()
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = "Settings",
        buttons = {
            { {
                text = "Lichess account: " .. (Store.isLoggedIn() and (Store.username() or "logged in") or "log in"),
                callback = function()
                    UIManager:close(dialog)
                    self:open(require("chessuite/ui/accountscreen"))
                end,
            } },
            { {
                text = "Your rating: " .. Store.playerRating() .. (Store.hasPlayerRating() and "" or " (not set)"),
                callback = function()
                    UIManager:close(dialog)
                    self:askRating()
                end,
            } },
            { toggle("Show where a piece can go", "show_legal_moves") },
            { toggle("Board coordinates", "show_coordinates") },
            { toggle("Moves are written", "move_words", "in words", "in chess notation") },
            { toggle("Coach comments on your moves", "coach_comments") },
            { toggle("Games with a friend: turn the board", "friend_flip", "to the player to move", "never") },
            { cycle("Coach explanations", "coach_level", { "beginner", "normal" }, { "short and simple", "detailed" }) },
            { cycle("Dark squares", "board_dark", { 0xAA, 0x88, 0xCC }, { "medium", "dark", "light" }) },
            { cycle("Game review", "review_depth", { 16, 20, 12 }, { "normal (depth 16)", "deep (depth 20, slow)", "quick (depth 12)" }) },
            { cycle("Game review by", "review_source", { "lichess", "local" },
                { "Lichess when logged in and online", "Stockfish on this device" }) },
            { toggle("Lichess cloud in local reviews", "review_cloud", "when online", "off") },
            { cycle("Analysis time", "analysis_seconds", { 8, 15, 30, 5 }, { "8 seconds", "15 seconds", "30 seconds", "5 seconds" }) },
            { { text = "About Chessuite", callback = function()
                UIManager:close(dialog)
                Common.info(
                    "Chessuite for KOReader " .. (Common.version or "") .. "\n"
                    .. "Free software under the AGPL-3.0.\n"
                    .. "https://github.com/ThePixelPro366/chessuite.koplugin\n\n"
                    .. "Chess engine: Stockfish 11 (GPL-3.0), bundled for ARM and x86 devices.\n"
                    .. "Human-like bots: Maia3 by the University of Toronto CSSLab (AGPL-3.0).\n"
                    .. "Bots, coach texts and move classification: ported from chess-app by Arunav Rajkhowa (AGPL-3.0).\n"
                    .. "Tactic names: a port of the Lichess puzzle tagger (AGPL-3.0).\n"
                    .. "Opening courses: tabia by dax (MIT). Opening names: lichess chess-openings (CC0).\n"
                    .. "Lichess Practice lessons: from the Lichess mobile app (GPL-3.0).\n"
                    .. "Puzzles, cloud analysis, opening explorer and tablebase: lichess.org.\n"
                    .. "Pieces: cburnett by Colin M.L. Burnett (GPLv2+).\n"
                    .. "Icons: Material Symbols by Google (Apache-2.0).\n\n"
                    .. "Not affiliated with or endorsed by Lichess.")
            end } },
        },
    }
    UIManager:show(dialog)
end

function HomeScreen:askRating()
    local SpinWidget = require("ui/widget/spinwidget")
    local lichess = Store.get("lichess_game_rating")
    UIManager:show(SpinWidget:new{
        title_text = "Your chess rating",
        info_text = "Coach plays at this level and bots near it are marked as a good match. "
            .. "It goes up and down after every game against a bot. Not sure? 800 is a beginner, "
            .. "1200 a casual player, 1600 a club player.",
        value = Store.playerRating(),
        value_min = 100,
        value_max = 3200,
        value_step = 50,
        value_hold_step = 200,
        default_value = Store.DEFAULT_RATING,
        ok_always_enabled = true,
        extra_text = lichess and ("Use my Lichess rating (" .. lichess .. ")") or nil,
        extra_callback = lichess and function(spin)
            Store.setPlayerRating(lichess)
            UIManager:close(spin)
            self:refreshHome()
        end or nil,
        callback = function(spin)
            Store.setPlayerRating(spin.value)
            self:refreshHome()
        end,
    })
end

function HomeScreen:onClose()
    self.closed = true
    UIManager:close(self)
    if self.plugin then self.plugin:stopEngine() end
    return true
end

return HomeScreen
