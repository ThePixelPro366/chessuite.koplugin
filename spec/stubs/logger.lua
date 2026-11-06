local l = {}
function l.dbg(...) if os.getenv("DEBUG") then print("DBG", ...) end end
function l.info(...) end
function l.warn(...) print("WARN", ...) end
function l.err(...) print("ERR", ...) end
return l
