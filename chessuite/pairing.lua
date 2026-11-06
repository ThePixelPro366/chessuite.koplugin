--[[
Pairing with the Chessuite Companion phone app, to get a Lichess website
login onto the e-reader.

The Lichess API cannot ask for a server analysis ("Request computer
analysis" on the website), and the Lichess login page is meant for a real
browser. So the user logs in to lichess.org in the phone app's browser view,
and the app sends that session cookie here:

  1. start() opens a small HTTP server on the local network (KOReader's
     SimpleTCPServer, like the HTTP inspector plugin) with a one-time code;
  2. the e-reader shows a QR code of http://<ip>:<port>/pair?c=<code>;
  3. that page, opened on the phone, starts the companion app
     (chessuite://pair?h=..&p=..&c=..) or offers to download it (/app.apk);
  4. the app POSTs c, user, cookie and ua to /pair; with the right code the
     session is stored and the server stops.
--]]

local logger = require("logger")
local Store = require("chessuite/store")

local Pairing = {}

local PORT_FIRST, PORT_LAST = 8765, 8775

local function urlDecode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function urlEncode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function parseQuery(q)
    local t = {}
    for pair in (q or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k then t[urlDecode(k)] = urlDecode(v) end
    end
    return t
end
Pairing.parseQuery = parseQuery

-- A random one-time code (8 letters and digits).
function Pairing.newCode()
    local chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    local bytes
    local f = io.open("/dev/urandom", "rb")
    if f then
        bytes = f:read(8)
        f:close()
    end
    local out = {}
    for i = 1, 8 do
        local b = bytes and bytes:byte(i) or math.random(0, 255)
        local k = (b % #chars) + 1
        out[i] = chars:sub(k, k)
    end
    return table.concat(out)
end

-- The e-reader's address on the local network (no packet is sent).
function Pairing.localIp()
    local socket = require("socket")
    local udp = socket.udp()
    if not udp then return nil end
    udp:setpeername("192.0.2.1", 80)
    local ip = udp:getsockname()
    udp:close()
    if not ip or ip == "0.0.0.0" or ip:match("^127%.") then return nil end
    return ip
end

-- Pages ------------------------------------------------------------------

local function page(title, body)
    return "<!doctype html><html><head><meta charset='utf-8'>"
        .. "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        .. "<title>" .. title .. "</title><style>body{font-family:sans-serif;max-width:32em;margin:2em auto;"
        .. "padding:0 1em;line-height:1.5}a.b{display:block;padding:1em;margin:1em 0;background:#222;color:#fff;"
        .. "text-align:center;border-radius:.5em;text-decoration:none;font-size:1.1em}</style></head><body>"
        .. body .. "</body></html>"
end

function Pairing:pairPage()
    local app = "chessuite://pair?h=" .. urlEncode(self.ip) .. "&p=" .. self.port .. "&c=" .. self.code
    local apk = "http://" .. self.ip .. ":" .. self.port .. "/app.apk"
    -- Chrome opens custom schemes through an intent link, with a download as fallback
    local intent = "intent://pair?h=" .. urlEncode(self.ip) .. "&p=" .. self.port .. "&c=" .. self.code
        .. "#Intent;scheme=chessuite;package=app.chessuite.companion;S.browser_fallback_url="
        .. urlEncode(apk) .. ";end"
    return page("Chessuite", "<h2>Connect Chessuite to Lichess</h2>"
        .. "<p>Your e-reader wants to log in to Lichess so that Lichess can analyse your games.</p>"
        .. "<a class='b' href='" .. intent .. "'>Open in Chessuite Companion</a>"
        .. "<p><small>Not working? <a href='" .. app .. "'>Try this link</a>.</small></p>"
        .. "<h3>No app yet?</h3><p>Download it from your e-reader, install it (allow installing from this "
        .. "browser when Android asks), then come back to this page.</p>"
        .. "<a class='b' href='/app.apk'>Download Chessuite Companion (Android)</a>")
end

-- Server -----------------------------------------------------------------

-- on_done(user) is called once the phone has sent a valid login.
function Pairing:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Pairing:start()
    local Device = require("device")
    local UIManager = require("ui/uimanager")
    local SimpleTCPServer = require("ui/message/simpletcpserver")
    self.ip = Pairing.localIp()
    if not self.ip then return false, "The e-reader is not connected to a Wi-Fi network." end
    self.code = Pairing.newCode()
    local last_err
    for port = PORT_FIRST, PORT_LAST do
        local server = SimpleTCPServer:new{
            host = "*",
            port = port,
            receiveCallback = function(data, client) return self:onRequest(data, client) end,
        }
        local ok, err = server:start()
        if ok then
            self.port = port
            self.server = server
            break
        end
        last_err = err
    end
    if not self.server then return false, last_err or "no free port" end
    if Device:isKindle() then
        -- make a hole in the Kindle's firewall, like the HTTP inspector plugin
        os.execute("iptables -A INPUT -p tcp --dport " .. self.port .. " -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT")
        os.execute("iptables -A OUTPUT -p tcp --sport " .. self.port .. " -m conntrack --ctstate ESTABLISHED -j ACCEPT")
    end
    self.queue = UIManager:insertZMQ(self.server)
    logger.info("chessuite pairing: listening on", self.ip, self.port)
    return true
end

function Pairing:url()
    return "http://" .. self.ip .. ":" .. self.port .. "/pair?c=" .. self.code
end

function Pairing:stop()
    if not self.server then return end
    local Device = require("device")
    local UIManager = require("ui/uimanager")
    if self.queue then UIManager:removeZMQ(self.queue) end
    self.server:stop()
    if Device:isKindle() then
        os.execute("iptables -D INPUT -p tcp --dport " .. self.port .. " -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT")
        os.execute("iptables -D OUTPUT -p tcp --sport " .. self.port .. " -m conntrack --ctstate ESTABLISHED -j ACCEPT")
    end
    self.server, self.queue = nil, nil
end

local REASONS = { [200] = "OK", [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found" }

local function respond(client, code, ctype, body)
    client:send("HTTP/1.0 " .. code .. " " .. (REASONS[code] or "") .. "\r\n"
        .. "Content-Type: " .. ctype .. "\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
    client:close()
end

function Pairing:onRequest(data, client)
    local method, target = data:match("^(%u+) (%S+) HTTP")
    if not method then return respond(client, 400, "text/plain", "bad request") end
    local path = target:match("^([^?]*)")
    if method == "GET" and path == "/pair" then
        return respond(client, 200, "text/html; charset=utf-8", self:pairPage())
    elseif method == "GET" and path == "/app.apk" then
        local f = self.apk_path and io.open(self.apk_path, "rb")
        if not f then return respond(client, 404, "text/plain", "app not found on the e-reader") end
        local apk = f:read("*a")
        f:close()
        return respond(client, 200, "application/vnd.android.package-archive", apk)
    elseif method == "POST" and path == "/pair" then
        local length = tonumber(data:lower():match("\ncontent%-length:%s*(%d+)")) or 0
        local body = ""
        if length > 0 and length < 20000 then
            client:settimeout(3)
            body = client:receive(length) or ""
        end
        local form = parseQuery(body)
        if form.c ~= self.code or not form.cookie or form.cookie == "" then
            logger.warn("chessuite pairing: refused a pairing attempt with a wrong code")
            return respond(client, 403, "text/plain", "wrong code")
        end
        Store.setWebSession(form.cookie, form.user, form.ua)
        respond(client, 200, "text/plain", "ok")
        local user = form.user
        -- one pairing per code: stop listening right away
        require("ui/uimanager"):nextTick(function()
            self:stop()
            if self.on_done then self.on_done(user) end
        end)
        return
    end
    return respond(client, 404, "text/plain", "not found")
end

return Pairing
