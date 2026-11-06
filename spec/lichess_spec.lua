-- Lichess client logging with a fake network. Run: luajit spec/lichess_spec.lua
package.path = "./spec/stubs/?.lua;./?.lua;" .. package.path
local answer = { code = 403, body = '{"error":"Missing scope"}' }
package.loaded["ltn12"] = {
    sink = { table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end end },
    source = { string = function(s) return s end },
}
package.loaded["socket"] = { skip = function(n, ...) return select(n + 1, ...) end }
local last_headers
package.loaded["socket.http"] = { request = function(req)
    last_headers = req.headers
    if answer.code == nil then return nil, "timeout" end
    req.sink(answer.body)
    return 1, answer.code, { ["content-type"] = "application/json" }, "HTTP/1.1 " .. answer.code
end }
package.loaded["socketutil"] = { LARGE_BLOCK_TIMEOUT = 1, LARGE_TOTAL_TIMEOUT = 1,
    set_timeout = function() end, reset_timeout = function() end }
package.loaded["json"] = { encode = function() return "{}" end, decode = function(s)
    local e = s:match('"error":"([^"]*)"')
    if e then return { error = e } end
    return { ok = true }
end }

local Lichess = require("chessuite/lichess")
local failures = 0
local function check(name, cond) print((cond and "ok   " or "FAIL ") .. name); if not cond then failures = failures + 1 end end

Lichess.clearLog()
local client = Lichess:new{ token = "lip_SECRET123" }
local _, ok, err, code
ok, err = client:requestAnalysis("abcd1234")
check("no analysis request without the website login", not ok and err:find("companion"))
local session = { cookie = "sessionId=abc", user = "tester", ua = "PhoneUA" }
ok, err, code = client:requestAnalysis("abcd1234", session)
check("website login sent like lichess.org's pages", last_headers.Cookie == "lila2=sessionId=abc"
    and last_headers.Origin == "https://lichess.org" and last_headers["User-Agent"] == "PhoneUA"
    and last_headers.Authorization == nil)
check("refused request fails", not ok and code == 403)
check("error carries lichess' message", err == "HTTP 403: Missing scope")
local e = Lichess.LOG[1]
check("logged with path and code", e and e.path == "/game/abcd1234/request-analysis" and e.code == 403 and e.web)
local text = Lichess.logText()
print(text)
check("token never logged", not text:find("SECRET"))
local f = io.open(Lichess.logFile(), "r")
check("log file written", f ~= nil and f:read("*a"):find("request%-analysis") ~= nil)
if f then f:close() end

answer = { code = 200, body = '<html><body><a id="user_tag" class="toggle link">Tester123</a></body></html>' }
local wok, wname = client:webAccount(session)
check("website login checked on the home page", wok and wname == "Tester123" and last_headers["X-Requested-With"] == nil)
answer = { code = 200, body = '<html><body><a href="/login">Sign in</a></body></html>' }
wok = client:webAccount(session)
check("logged-out home page is not a login", not wok)
answer = { code = 400, body = "This game is already analysed" }
ok = client:requestAnalysis("abcd1234", session)
check("already analysed counts as success", ok)
answer = { code = 200, body = '{"id":"x"}' }
ok = client:exportGame("abcd1234")
check("success logged too", ok and Lichess.LOG[1].code == 200 and Lichess.LOG[1].path:find("evals=true") ~= nil)
answer = { code = nil }
ok, err = client:account()
check("network error logged", not ok and err:find("timeout") and Lichess.LOG[1].err:find("network error"))
answer = { code = 401, body = "" }
_, err = client:account()
check("401 explained", err:find("token is invalid, expired or lacks a permission") ~= nil)
Lichess.clearLog()
check("clear log", #Lichess.LOG == 0)

if failures > 0 then print(failures .. " failure(s)"); os.exit(1) end
print("all passed")
