-- Tiny stand-in for KOReader's UIManager: a timer queue run by UIManager:run().
local ffi = require("ffi")
pcall(ffi.cdef, "int usleep(unsigned int);")
local U = { tasks = {}, now = 0 }
function U:scheduleIn(t, f) table.insert(self.tasks, { at = self.now + t, f = f }) end
function U:nextTick(f) self:scheduleIn(0, f) end
function U:unschedule(f)
    for i = #self.tasks, 1, -1 do if self.tasks[i].f == f then table.remove(self.tasks, i) end end
end
function U:run(until_fn, max_seconds)
    local deadline = self.now + (max_seconds or 30)
    while (not until_fn or not until_fn()) and self.now < deadline do
        table.sort(self.tasks, function(a, b) return a.at < b.at end)
        local t = table.remove(self.tasks, 1)
        if not t then break end
        if t.at > self.now then
            ffi.C.usleep(math.floor((t.at - self.now) * 1e6))
            self.now = t.at
        end
        t.f()
    end
end
return U
