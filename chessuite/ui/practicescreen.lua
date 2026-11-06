--[[
Lichess Practice, laid out like the Lichess app's practice screen: your
progress, "Resume learning", then every section with its courses and how
many of their lessons you have done. Everything works offline.
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Common = require("chessuite/ui/common")
local LP = require("chessuite/lichesspractice")

local PracticeScreen = Common.Page:extend{
    title = "Practice",
    plugin = nil,
}

local ICONS = { checkmates = "trophy", ["fundamental-tactics"] = "lightbulb", ["advanced-tactics"] = "lightbulb",
    ["pawn-endgames"] = "practice", ["rook-endgames"] = "practice" }

function PracticeScreen:init()
    self.page = 1
    Common.Page.init(self)
end

-- Everything on the page, top to bottom; it is cut into pages that fit the screen.
function PracticeScreen:entries(width)
    local done, total, resume = LP.progress()
    local list = {}
    list[#list + 1] = Common.paragraph("Progress: " .. math.floor(done * 100 / math.max(1, total)) .. "% · "
        .. done .. " of " .. total .. " lessons", width, 18, { bold = true })
    if resume then
        list[#list + 1] = Common.Tile:new{
            width = width, inverted = true, icon = "continue", title = "Resume learning", subtitle = resume.name,
            show_parent = self, callback = function() self:open(resume) end,
        }
    end
    for _, sec in ipairs(LP.sections()) do
        list[#list + 1] = Common.paragraph(sec.name, width, 20, { bold = true })
        for _, st in ipairs(sec.studies) do
            local n = LP.doneCount(st.id)
            list[#list + 1] = Common.Tile:new{
                width = width,
                title = st.name,
                badge = n >= #st.chapters and "✓ done" or (n .. " / " .. #st.chapters),
                subtitle = st.description,
                icon = ICONS[sec.id] or "practice",
                show_parent = self,
                callback = function() self:open(st) end,
            }
        end
    end
    return list
end

function PracticeScreen:buildContent(width, height)
    local list = self:entries(width)
    local gap = Common.scale(8)
    local nav = Common.buttonBar({ { { text = "‹" }, { text = "1 / 1" }, { text = "›" } } }, width, self)
    local avail = height - nav:getSize().h - gap
    -- cut into pages
    local pages, cur, used = {}, {}, 0
    for _, w in ipairs(list) do
        local h = w:getSize().h + gap
        if #cur > 0 and used + h > avail then
            pages[#pages + 1] = cur
            cur, used = {}, 0
        end
        cur[#cur + 1] = w
        used = used + h
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    self.page = math.max(1, math.min(self.page, #pages))
    local group = VerticalGroup:new{ align = "left" }
    for _, w in ipairs(pages[self.page] or {}) do
        group[#group + 1] = w
        group[#group + 1] = Common.vspace(gap)
    end
    if #pages > 1 then
        group[#group + 1] = Common.buttonBar({ {
            { text = "‹", enabled = self.page > 1, callback = function() self.page = self.page - 1; self:refresh() end },
            { text = self.page .. " / " .. #pages, enabled = false },
            { text = "›", enabled = self.page < #pages, callback = function() self.page = self.page + 1; self:refresh() end },
        } }, width, self)
    end
    return group
end

function PracticeScreen:open(study)
    UIManager:show(require("chessuite/ui/lessonscreen"):new{
        plugin = self.plugin, study = study, index = LP.firstOngoing(study),
        on_close = function() if not self.closed then self:refresh() end end,
    })
end

function PracticeScreen:onClose()
    self.closed = true
    return Common.Page.onClose(self)
end

return PracticeScreen
