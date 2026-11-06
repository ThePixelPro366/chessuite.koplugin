-- Pairing server request handling, with a fake client socket. Run: luajit spec/pairing_spec.lua
package.path = "./spec/stubs/?.lua;./?.lua;" .. package.path
local UIManager = require("ui/uimanager")
local Pairing = require("chessuite/pairing")
local Store = require("chessuite/store")
local failures = 0
local function check(name, cond) print((cond and "ok   " or "FAIL ") .. name); if not cond then failures = failures + 1 end end

local function client(body)
    return {
        sent = nil,
        send = function(self, s) self.sent = s end,
        close = function() end,
        settimeout = function() end,
        receive = function(_, n) return body and body:sub(1, n) or nil end,
    }
end

local paired_user
local p = Pairing:new{ apk_path = "companion/chessuite-companion.apk", on_done = function(u) paired_user = u end }
p.ip, p.port, p.code = "192.168.1.20", 8765, "ABCD2345"
p.stop = function() p.stopped = true end

local c = client()
p:onRequest("GET /pair?c=ABCD2345 HTTP/1.1\r\nHost: x\r\n\r\n", c)
check("pair page served", c.sent:find("^HTTP/1.0 200") and c.sent:find("intent://pair%?h=192.168.1.20&p=8765&c=ABCD2345"))
check("page links the app download", c.sent:find("/app.apk") ~= nil)

c = client()
p:onRequest("GET /app.apk HTTP/1.1\r\n\r\n", c)
check("apk served from the plugin", c.sent:find("^HTTP/1.0 200") and c.sent:find("application/vnd.android.package%-archive"))

local body = "c=WRONG123&user=bob&cookie=abc&ua=x"
c = client(body)
p:onRequest("POST /pair HTTP/1.1\r\nContent-Length: " .. #body .. "\r\n\r\n", c)
check("wrong code refused", c.sent:find("^HTTP/1.0 403") and Store.webSession() == nil)

body = "c=ABCD2345&user=tester&cookie=" .. "sessionId%3Dabc%26sid%3Dxyz" .. "&ua=Mozilla%2F5.0+Phone"
c = client(body)
p:onRequest("POST /pair HTTP/1.1\r\nHost: x\r\nContent-Length: " .. #body .. "\r\n\r\n", c)
UIManager:run(nil, 1)
local s = Store.webSession()
check("right code stores the website login", c.sent:find("^HTTP/1.0 200") and s and s.cookie == "sessionId=abc&sid=xyz"
    and s.user == "tester" and s.ua == "Mozilla/5.0 Phone")
check("server stops and reports", p.stopped and paired_user == "tester")
check("codes are random letters", Pairing.newCode():match("^[A-Z2-9]+$") and #Pairing.newCode() == 8
    and Pairing.newCode() ~= Pairing.newCode())

if failures > 0 then print(failures .. " failure(s)"); os.exit(1) end
print("all passed")
