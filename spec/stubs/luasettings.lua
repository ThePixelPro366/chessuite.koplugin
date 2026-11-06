-- in-memory stand-in
local S = {}
S.__index = S
function S:open() return setmetatable({ data = {} }, S) end
function S:readSetting(k) return self.data[k] end
function S:saveSetting(k, v) self.data[k] = v end
function S:delSetting(k) self.data[k] = nil end
function S:flush() end
return S
