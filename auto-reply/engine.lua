-- Runtime: config state, channel hooks, matching, cooldowns, send queue.
local util = require("util")
local config = require("config")
local rules = require("rules")

local E = {}

local MAX_QUEUE = 10
local FIRST_DELAY_MS = 800
local POLL_MS = 5000
local INVISIBLE = " \u{E0000}" -- Twitch dup-message bypass

E.cfg = config.defaults()
E.active = false
E.expires = nil -- unix seconds or nil
E.session_only = false
E.notice_channel = nil -- where to print async notices

local handles = {} -- name -> { channel=, conn= }
local user_cd = {} -- "chan|user" -> unix seconds of last reply
local rule_cd = {} -- "chan|ruleid" -> unix seconds
local queue = {}
local pump_armed = false
local last_send_ms = 0
local last_sent_text = {}
local dup_flip = {}
local warned_anon = false
local expiry_armed = false

-- ---------- notices ----------
function E.notify(text, channel)
    local ch = channel or E.notice_channel
    if ch then
        local ok = pcall(function()
            if ch:is_valid() then
                ch:add_system_message("[auto-reply] " .. text)
            else
                error("invalid")
            end
        end)
        if ok then
            return
        end
    end
    c2.log(c2.LogLevel.Info, "auto-reply: " .. text)
end

-- ---------- state ----------
function E.save()
    -- Persist activity: forever / future expiry; session-only is not saved.
    local cfg = E.cfg
    if E.active and not E.session_only then
        cfg.active_until = E.expires or "forever"
    else
        cfg.active_until = nil
    end
    return config.save(cfg)
end

function E.is_active()
    if not E.active then
        return false
    end
    if E.expires and util.now_s() >= E.expires then
        E.deactivate("time is up, auto-reply turned off.")
        return false
    end
    return true
end

function E.activate(duration_s, forever)
    E.active = true
    E.session_only = false
    E.expires = nil
    if forever then
        -- on across restarts
    elseif duration_s then
        E.expires = util.now_s() + duration_s
    else
        E.session_only = true
    end
    E.save()
    E.arm_expiry()
    E.sync_hooks()
end

function E.deactivate(reason)
    local was = E.active
    E.active = false
    E.expires = nil
    E.session_only = false
    queue = {}
    E.save()
    if was and reason then
        E.notify(reason)
    end
end

-- Timer that turns auto-reply off when the period ends, even if chat is quiet.
function E.arm_expiry()
    if expiry_armed then
        return
    end
    expiry_armed = true
    local function tick()
        expiry_armed = false
        if E.active and E.expires then
            E.is_active() -- deactivates itself when expired
            if E.active then
                E.arm_expiry()
            end
        end
    end
    c2.later(tick, 10000)
end

-- ---------- config (re)load ----------
function E.load()
    local cfg, warn = config.load()
    E.cfg = cfg
    E.active, E.expires, E.session_only = false, nil, false
    local au = cfg.active_until
    if au == "forever" then
        E.active = true
    elseif type(au) == "number" and au > util.now_s() then
        E.active, E.expires = true, au
    end
    if warn then
        E.notify(warn)
    end
    if E.active then
        E.arm_expiry()
    end
    E.sync_hooks()
end

-- ---------- rules ----------
-- conditions: list of {type=, match=}; ALL must match for the rule to fire.
function E.add_rule(conditions, reply, channels)
    if type(conditions) ~= "table" or #conditions == 0 then
        return nil, "a rule needs at least one condition"
    end
    for _, c in ipairs(conditions) do
        local ok, err = rules.validate(c.type, c.match)
        if not ok then
            return nil, c.type .. ": " .. err
        end
    end
    if type(reply) ~= "string" or not reply:match("%S") then
        return nil, "a reply message is required"
    end
    if #reply > 500 then
        return nil, "reply is longer than 500 characters"
    end
    local first = reply:sub(1, 1)
    if first == "/" or first == "." then
        return nil, "reply must not start with '/' or '.' (would run as a command)"
    end
    local cfg = E.cfg
    local id = cfg.next_rule_id
    cfg.next_rule_id = id + 1
    cfg.rules[#cfg.rules + 1] = {
        id = id, conditions = conditions, reply = reply,
        enabled = true, channels = channels or {},
    }
    E.save()
    return id
end

function E.find_rule(id)
    for i, r in ipairs(E.cfg.rules) do
        if r.id == id then
            return r, i
        end
    end
end

-- ---------- channel hooks ----------
function E.sync_hooks()
    local wanted = {}
    for _, name in ipairs(E.cfg.channels) do
        wanted[name] = true
    end
    for name, h in pairs(handles) do
        if not wanted[name] then
            pcall(function() h.conn:disconnect() end)
            handles[name] = nil
        end
    end
    for name in pairs(wanted) do
        local h = handles[name]
        local healthy = false
        if h then
            local ok, res = pcall(function()
                return h.channel:is_valid() and h.conn:is_connected()
            end)
            healthy = ok and res
            if not healthy then
                pcall(function() h.conn:disconnect() end)
                handles[name] = nil
            end
        end
        if not healthy then
            local ch = c2.Channel.by_name(name)
            if ch and ch:is_valid() then
                local conn = ch:on_message_appended(function(msg)
                    E.on_message(name, ch, msg)
                end)
                handles[name] = { channel = ch, conn = conn }
            end
        end
    end
end

function E.hooked(name)
    return handles[name] ~= nil
end

-- Re-hook channels that were opened/closed after startup.
function E.start_poll()
    local function tick()
        E.sync_hooks()
        c2.later(tick, POLL_MS)
    end
    c2.later(tick, POLL_MS)
end

-- ---------- sending ----------
local function schedule_pump(delay_ms)
    if pump_armed then
        return
    end
    pump_armed = true
    c2.later(function()
        pump_armed = false
        E.pump()
    end, math.max(1, math.floor(delay_ms)))
end

function E.pump()
    if #queue == 0 then
        return
    end
    if not E.is_active() then
        queue = {}
        return
    end
    local gap_ms = E.cfg.global_min_gap * 1000
    local wait = last_send_ms + gap_ms - util.now_ms()
    if wait > 0 then
        schedule_pump(wait + 50)
        return
    end
    local item = table.remove(queue, 1)
    local ch = c2.Channel.by_name(item.channel)
    if ch and ch:is_valid() then
        local text = item.text
        if last_sent_text[item.channel] == text then
            dup_flip[item.channel] = not dup_flip[item.channel]
        else
            dup_flip[item.channel] = false
        end
        last_sent_text[item.channel] = text
        if dup_flip[item.channel] then
            text = text .. INVISIBLE
        end
        ch:send_message(text, false) -- false: never run as a command
        last_send_ms = util.now_ms()
    end
    if #queue > 0 then
        schedule_pump(math.max(gap_ms, 1100))
    end
end

-- {user} in the reply becomes the sender's name.
local function render(reply, msg)
    local name = msg.display_name
    if not name or name == "" then
        name = msg.login_name
    end
    local out = reply:gsub("{user}", function() return name end)
    return out:sub(1, 500)
end

local function enqueue(channel, text)
    if #queue >= MAX_QUEUE then
        table.remove(queue, 1)
    end
    queue[#queue + 1] = { channel = channel, text = text }
    schedule_pump(FIRST_DELAY_MS)
end

-- ---------- incoming ----------
local function skip_flags()
    local mask = 0
    for _, n in ipairs({ "System", "RecentMessage", "Debug", "Timeout", "Untimeout", "Disabled" }) do
        mask = mask | (c2.MessageFlag[n] or 0)
    end
    return mask
end
local SKIP = nil

function E.on_message(chan_name, ch, msg)
    if not E.is_active() then
        return
    end
    SKIP = SKIP or skip_flags()
    local flags = msg.flags or 0
    if (flags & SKIP) ~= 0 then
        return
    end
    local acct = c2.current_account()
    if not acct or not acct:is_valid() or acct:is_anon() then
        if not warned_anon then
            warned_anon = true
            E.notify("no logged-in account; auto-reply cannot send messages.", ch)
        end
        return
    end
    local me = util.norm_user(acct:login())
    local sender = util.norm_user(msg.login_name)
    if sender == "" or sender == me then
        return
    end
    if util.contains(E.cfg.ignore_users, sender) then
        return
    end
    local text = msg.message_text or ""
    if text == "" then
        return
    end

    if E.cfg.only_when_live then
        local ok, status = pcall(function() return ch:get_stream_status() end)
        if not ok or not status or not status.live then
            return
        end
    end

    local now = util.now_s()
    local ukey = chan_name .. "|" .. sender
    local last_user = user_cd[ukey]
    if last_user and now - last_user < E.cfg.per_user_cooldown then
        return
    end

    for _, rule in ipairs(E.cfg.rules) do
        if rules.is_usable(rule)
            and rules.applies_to_channel(rule, chan_name)
            and rules.matches(rule, text, flags, me)
        then
            local rkey = chan_name .. "|" .. tostring(rule.id)
            local last_rule = rule_cd[rkey]
            if not (last_rule and now - last_rule < E.cfg.per_rule_cooldown) then
                user_cd[ukey] = now
                rule_cd[rkey] = now
                enqueue(chan_name, render(rule.reply, msg))
            end
            return -- first matching rule wins
        end
    end
end

return E
