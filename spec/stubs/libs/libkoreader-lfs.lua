local function q(p) return "'" .. p:gsub("'", "'\\''") .. "'" end
return {
    attributes = function(p, what)
        if os.execute("test -d " .. q(p)) == 0 then return "directory" end
        local f = io.open(p, "rb"); if not f then return nil end; f:close(); return "file"
    end,
    mkdir = function(p) return os.execute("mkdir -p " .. q(p)) == 0 end,
}
