-- Same approach as koreader-base ffi/util.lua, reduced to what the plugin uses.
local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
int pipe(int[2]); int fork(void); int dup2(int, int); int close(int);
int execl(const char *, const char *, ...); void _exit(int);
long read(int, void *, size_t); long write(int, const void *, size_t);
int waitpid(int, int *, int); int kill(int, int); int setpgid(int, int);
int ioctl(int, unsigned long, ...);
]]
local util = {}
function util.runInSubProcess(func, with_pipe)
    local p = ffi.new("int[2]")
    C.pipe(p); local parent_read, child_write = p[0], p[1]
    C.pipe(p); local child_read, parent_write = p[0], p[1]
    local pid = C.fork()
    if pid == 0 then
        C.setpgid(0, 0)
        C.close(parent_read); C.close(parent_write)
        func(0, child_write, child_read)
        C._exit(0)
    end
    C.close(child_read); C.close(child_write)
    return pid, parent_read, parent_write
end
function util.isSubProcessDone(pid)
    local st = ffi.new("int[1]")
    local r = C.waitpid(pid, st, 1)
    return r == pid or r == -1
end
function util.terminateSubProcess(pid) C.kill(-pid, 9) end
function util.getNonBlockingReadSize(fd)
    local n = ffi.new("int[1]")
    if C.ioctl(fd, 0x541B, n) ~= 0 then return nil end
    return tonumber(n[0])
end
function util.writeToFD(fd, data)
    return C.write(fd, data, #data) == #data
end
return util
