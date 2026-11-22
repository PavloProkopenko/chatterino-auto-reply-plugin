-- Optional Twitch Helix / EventSub layer (opt-in: `set helix on` + `helix login`).
-- The plugin API cannot read Chatterino's own login, so this module has its own token,
-- obtained with the OAuth device-code flow and kept in data/helix.json (never in
-- config.json, never printed). Needs the "Network" permission in info.json.
local json = require("chatterino.json")
local util = require("util")

local H = {}

-- Client ID of a registered Twitch application (public client type). Empty by default:
-- set it with `/autoreply helix clientid <id>` (stored in helix.json).
H.CLIENT_ID = ""

local FILE = "helix.json"
local SCOPES = "channel:read:redemptions moderation:read channel:read:vips"
local ID_URL = "https://id.twitch.tv/oauth2"
local API_URL = "https://api.twitch.tv/helix"
local ES_URL = "wss://eventsub.wss.twitch.tv/ws"
local REFRESH_MARGIN_S = 300
local MAX_PAGES = 20

H.notify = function(text) c2.log(c2.LogLevel.Info, "auto-reply: " .. text) end -- engine overrides
H.enabled = function() return false end -- engine overrides (config.helix_enabled)

-- ---------- token store ----------
local store = {} -- client_id, access_token, refresh_token, expires_at, user_id, login, scopes

local function read_all(name)
    local f = io.open(name, "r")
    if not f then return nil end
    local d = f:read("a")
    f:close()
    return d
end

function H.load()
    store = {}
    local raw = read_all(FILE)
    if raw and raw ~= "" then
        local ok, t = pcall(json.parse, raw)
        if ok and type(t) == "table" then
            store = t
        end
    end
end

local function save()
    local ok, out = pcall(json.stringify, store)
    if not ok then return false end
    local f = io.open(FILE, "w")
    if not f then return false end
    f:write(out)
    f:close()
    return true
end

function H.client_id()
    local id = store.client_id
    if type(id) ~= "string" or id == "" then id = H.CLIENT_ID end
    if type(id) ~= "string" or not id:match("^[%w]+$") then return nil end
    return id
end

function H.set_client_id(id)
    if type(id) ~= "string" or not id:match("^[%w]+$") or #id < 10 then
        return false
    end
    store.client_id = id
    save()
    return true
end

function H.logged_in()
    return type(store.access_token) == "string" and store.access_token ~= ""
end

function H.login_name() return store.login end
function H.user_id() return store.user_id end

-- opted in and logged in
function H.ready()
    return H.enabled() and H.logged_in()
end

function H.status_text()
    local parts = {}
    parts[#parts + 1] = H.enabled() and "включён" or "выключен (set helix on)"
    if H.logged_in() then
        parts[#parts + 1] = "вход выполнен: " .. tostring(store.login or "?")
    else
        parts[#parts + 1] = "вход не выполнен (helix login)"
    end
    if not H.client_id() then
        parts[#parts + 1] = "Client ID не задан (helix clientid <id>)"
    end
    return table.concat(parts, "; ")
end

-- ---------- transport ----------
local function urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function form(t, order)
    local parts = {}
    for _, k in ipairs(order) do
        parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(t[k])
    end
    return table.concat(parts, "&")
end

-- cb(status, body, err). Replaced in tests.
function H.http(method, url, headers, body, cb)
    local ok, err = pcall(function()
        local req = c2.HTTPRequest.create(c2.HTTPMethod[method], url)
        for k, v in pairs(headers or {}) do req:set_header(k, v) end
        if body then req:set_payload(body) end
        req:set_timeout(15000)
        req:on_success(function(res) cb(res:status(), res:data(), nil) end)
        req:on_error(function(res) cb(res:status(), res:data(), res:error()) end)
        req:execute()
    end)
    if not ok then
        cb(nil, "", tostring(err))
    end
end

local function parse_body(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, t = pcall(json.parse, body)
    if ok and type(t) == "table" then return t end
    return nil
end

-- ---------- device-code login ----------
local login_gen = 0 -- bumping it cancels a running login

local function adopt_token(t, cb)
    store.access_token = t.access_token
    if type(t.refresh_token) == "string" then store.refresh_token = t.refresh_token end
    store.expires_at = util.now_s() + (tonumber(t.expires_in) or 3600)
    save()
    -- who is this and which scopes were granted
    H.http("GET", ID_URL .. "/validate", { Authorization = "OAuth " .. store.access_token }, nil, function(st, body)
        local v = parse_body(body)
        if st == 200 and v then
            store.user_id = v.user_id
            store.login = type(v.login) == "string" and v.login:lower() or nil
            store.scopes = v.scopes
            save()
        end
        if cb then cb(true) end
    end)
end

function H.login(say)
    local cid = H.client_id()
    if not cid then
        say("не задан Client ID приложения Twitch: /autoreply helix clientid <id> (см. /autoreply help helix).")
        return
    end
    login_gen = login_gen + 1
    local gen = login_gen
    H.http("POST", ID_URL .. "/device", { ["Content-Type"] = "application/x-www-form-urlencoded" },
        form({ client_id = cid, scopes = SCOPES }, { "client_id", "scopes" }), function(st, body, err)
            local d = parse_body(body)
            if st ~= 200 or not d or not d.device_code then
                say("не удалось начать вход: " .. tostring((d and d.message) or err or st))
                return
            end
            say(string.format("откройте %s и введите код %s (действует %d мин). Жду подтверждения...",
                tostring(d.verification_uri), tostring(d.user_code), math.floor((tonumber(d.expires_in) or 1800) / 60)))
            local interval = math.max(1, tonumber(d.interval) or 5)
            local deadline = util.now_s() + (tonumber(d.expires_in) or 1800)
            local function poll()
                if gen ~= login_gen then return end
                if util.now_s() > deadline then
                    say("время на подтверждение вышло; повторите: /autoreply helix login")
                    return
                end
                H.http("POST", ID_URL .. "/token", { ["Content-Type"] = "application/x-www-form-urlencoded" },
                    form({ client_id = cid, scopes = SCOPES, device_code = d.device_code,
                        grant_type = "urn:ietf:params:oauth:grant-type:device_code" },
                        { "client_id", "scopes", "device_code", "grant_type" }), function(st2, body2, err2)
                        if gen ~= login_gen then return end
                        local t = parse_body(body2)
                        if st2 == 200 and t and t.access_token then
                            adopt_token(t, function()
                                say("вход выполнен: " .. tostring(store.login or "?") .. ".")
                                H.sync_eventsub()
                            end)
                            return
                        end
                        local msg = t and t.message or ""
                        if msg == "authorization_pending" or msg == "slow_down" then
                            if msg == "slow_down" then interval = interval + 5 end
                            c2.later(poll, interval * 1000)
                        else
                            say("вход не выполнен: " .. tostring(msg ~= "" and msg or err2 or st2))
                        end
                    end)
            end
            c2.later(poll, interval * 1000)
        end)
end

function H.logout()
    login_gen = login_gen + 1
    local tok = store.access_token
    local cid = H.client_id()
    if tok and cid then
        H.http("POST", ID_URL .. "/revoke", { ["Content-Type"] = "application/x-www-form-urlencoded" },
            form({ client_id = cid, token = tok }, { "client_id", "token" }), function() end)
    end
    local keep = store.client_id
    store = { client_id = keep }
    save()
    H.close_eventsub()
end

-- ---------- token refresh ----------
local refreshing = nil -- list of waiting callbacks while a refresh runs

-- cb(token|nil, err)
local function with_token(cb, force)
    if not H.logged_in() then
        cb(nil, "вход не выполнен (/autoreply helix login)")
        return
    end
    local fresh = (store.expires_at or 0) - util.now_s() > REFRESH_MARGIN_S
    if fresh and not force then
        cb(store.access_token)
        return
    end
    if type(store.refresh_token) ~= "string" or not H.client_id() then
        cb(nil, "токен истёк; войдите заново: /autoreply helix login")
        return
    end
    if refreshing then
        refreshing[#refreshing + 1] = cb
        return
    end
    refreshing = { cb }
    H.http("POST", ID_URL .. "/token", { ["Content-Type"] = "application/x-www-form-urlencoded" },
        form({ client_id = H.client_id(), grant_type = "refresh_token", refresh_token = store.refresh_token },
            { "client_id", "grant_type", "refresh_token" }), function(st, body)
            local t = parse_body(body)
            local waiting = refreshing
            refreshing = nil
            if st == 200 and t and t.access_token then
                store.access_token = t.access_token
                if type(t.refresh_token) == "string" then store.refresh_token = t.refresh_token end
                store.expires_at = util.now_s() + (tonumber(t.expires_in) or 3600)
                save()
                for _, w in ipairs(waiting) do w(store.access_token) end
            else
                if st == 400 or st == 401 then
                    store.access_token = nil -- refresh token is dead: ask for a new login
                    save()
                end
                for _, w in ipairs(waiting) do w(nil, "не удалось обновить токен; войдите заново: /autoreply helix login") end
            end
        end)
end

-- ---------- Helix calls ----------
local function query_string(q)
    local keys = {}
    for k in pairs(q or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(q[k]) end
    return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

-- cb(status, table|nil, err). Retries once after a forced refresh on 401.
local function api(method, path, query, body, cb, retried)
    with_token(function(tok, err)
        if not tok then
            cb(nil, nil, err)
            return
        end
        local headers = { Authorization = "Bearer " .. tok, ["Client-Id"] = H.client_id() or "" }
        if body then headers["Content-Type"] = "application/json" end
        H.http(method, API_URL .. path .. query_string(query), headers, body, function(st, raw, herr)
            if st == 401 and not retried then
                with_token(function(tok2)
                    if tok2 then api(method, path, query, body, cb, true) else cb(st, nil, "токен отклонён") end
                end, true)
                return
            end
            cb(st, parse_body(raw), herr)
        end)
    end)
end

local function api_error(st, t, err)
    local m = t and (t.message or t.error)
    if st == 403 then
        return "нет прав: токен должен принадлежать стримеру (или модератору) этого канала, вход с нужными правами: /autoreply helix login"
    end
    return tostring(m or err or st or "ошибка сети")
end

-- cb(user|nil, err). user.login is canonical; (nil, nil) = no such account.
function H.get_user(login, cb)
    api("GET", "/users", { login = login }, nil, function(st, t, err)
        if st == 200 and t and type(t.data) == "table" then
            local u = t.data[1]
            if u then
                cb({ id = u.id, login = tostring(u.login or login):lower(), display_name = u.display_name })
            else
                cb(nil, nil)
            end
        else
            cb(nil, api_error(st, t, err))
        end
    end)
end

-- Paginated list; cb(list_of_logins|nil, err)
local function list_logins(path, query, cb)
    local out, pages = {}, 0
    local function page(after)
        local q = {}
        for k, v in pairs(query) do q[k] = v end
        q.first = "100"
        q.after = after
        api("GET", path, q, nil, function(st, t, err)
            if st ~= 200 or not t or type(t.data) ~= "table" then
                cb(nil, api_error(st, t, err))
                return
            end
            for _, u in ipairs(t.data) do
                if type(u.user_login) == "string" then out[#out + 1] = u.user_login:lower() end
            end
            pages = pages + 1
            local cur = t.pagination and t.pagination.cursor
            if type(cur) == "string" and cur ~= "" and pages < MAX_PAGES then
                page(cur)
            else
                cb(out)
            end
        end)
    end
    page(nil)
end

function H.get_mods(broadcaster_id, cb)
    list_logins("/moderation/moderators", { broadcaster_id = broadcaster_id }, cb)
end

function H.get_vips(broadcaster_id, cb)
    list_logins("/channels/vips", { broadcaster_id = broadcaster_id }, cb)
end

-- ---------- EventSub (channel point redemptions) ----------
local ES_TYPE = "channel.channel_points_custom_reward_redemption.add"
local es = { sock = nil, gen = 0, session = nil, subscribed = {}, seen_msgs = {}, seen_n = 0,
    last_rx = 0, keepalive_s = 10, backoff = 5, url = ES_URL, connected = false }

-- wanted(): list of broadcaster logins that need redemption events; set by the engine.
H.wanted = function() return {} end
-- on_redemption({id, channel, reward_id, title, user_input, user_login}); set by the engine.
H.on_redemption = function() end

function H.close_eventsub()
    es.gen = es.gen + 1
    if es.sock then
        local s = es.sock
        es.sock = nil
        pcall(function() s:close() end)
    end
    es.session, es.subscribed, es.connected = nil, {}, false
    es.url, es.backoff = ES_URL, 5
end

-- True when redemption events for this channel are being delivered.
function H.covers(channel)
    return es.connected and es.session ~= nil and es.subscribed[channel] == true
end

local function subscribe_all()
    if not es.session then return end
    local uid = store.user_id
    for _, login in ipairs(H.wanted()) do
        if login == store.login and uid and es.subscribed[login] == nil then
            es.subscribed[login] = false -- request in flight
            local body = json.stringify({
                type = ES_TYPE, version = "1",
                condition = { broadcaster_user_id = uid },
                transport = { method = "websocket", session_id = es.session },
            })
            api("POST", "/eventsub/subscriptions", nil, body, function(st, t, err)
                if st == 200 or st == 202 then
                    es.subscribed[login] = true
                else
                    es.subscribed[login] = nil
                    H.notify("не удалось подписаться на награды канала " .. login .. ": " .. api_error(st, t, err))
                end
            end)
        end
    end
end

local function handle_text(data)
    local m = parse_body(data)
    if not m or type(m.metadata) ~= "table" then return end
    es.last_rx = util.now_s()
    local mid = m.metadata.message_id
    if mid then
        if es.seen_msgs[mid] then return end
        if es.seen_n > 200 then es.seen_msgs, es.seen_n = {}, 0 end
        es.seen_msgs[mid] = true
        es.seen_n = es.seen_n + 1
    end
    local kind = m.metadata.message_type
    local p = m.payload or {}
    if kind == "session_welcome" and p.session then
        es.session = p.session.id
        es.keepalive_s = tonumber(p.session.keepalive_timeout_seconds) or 10
        es.connected = true
        es.backoff = 5
        es.url = ES_URL
        subscribe_all()
    elseif kind == "session_reconnect" and p.session and type(p.session.reconnect_url) == "string" then
        es.url = p.session.reconnect_url
        H.reconnect_eventsub(true)
    elseif kind == "notification" and type(p.event) == "table" then
        local e = p.event
        local reward = type(e.reward) == "table" and e.reward or {}
        H.on_redemption({
            id = e.id, channel = tostring(e.broadcaster_user_login or ""):lower(),
            reward_id = reward.id, title = reward.title, user_input = e.user_input or "",
            user_login = tostring(e.user_login or ""):lower(),
        })
    end
end

local function open_eventsub()
    es.gen = es.gen + 1
    local gen = es.gen
    local ok, sock = pcall(function()
        return c2.WebSocket.new(es.url, {
            on_text = function(data)
                if gen == es.gen then pcall(handle_text, data) end
            end,
            on_close = function()
                if gen ~= es.gen then return end
                es.sock, es.session, es.connected, es.subscribed = nil, nil, false, {}
                es.url = ES_URL -- a stale reconnect URL is useless after a close
                -- the poll tick (H.sync_eventsub) reopens it when still wanted
            end,
        })
    end)
    if ok then
        es.sock = sock
        es.last_rx = util.now_s()
    else
        H.notify("не удалось открыть EventSub: " .. tostring(sock))
    end
end

function H.reconnect_eventsub(keep_subs)
    local old = es.sock
    local subs = es.subscribed
    open_eventsub() -- new generation first: the old socket's on_close is then ignored
    if old then pcall(function() old:close() end) end
    es.session, es.connected = nil, false
    es.subscribed = keep_subs and subs or {}
end

-- Called from the engine's poll tick: opens/closes/repairs the EventSub connection.
function H.sync_eventsub()
    local want = H.ready() and #H.wanted() > 0 and store.login ~= nil
    if want then
        local mine = false
        for _, l in ipairs(H.wanted()) do if l == store.login then mine = true end end
        want = mine
    end
    if not want then
        if es.sock then H.close_eventsub() end
        return
    end
    if not es.sock then
        open_eventsub()
        return
    end
    if es.connected and util.now_s() - es.last_rx > es.keepalive_s * 2 + 5 then
        H.reconnect_eventsub(false) -- silent connection
        return
    end
    subscribe_all() -- new redeems added after the welcome
end

-- test hooks
function H._state() return store, es end

return H
