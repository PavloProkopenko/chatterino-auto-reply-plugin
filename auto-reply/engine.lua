-- Runtime: config state, channel hooks, matching, cooldowns, send queue.
local util = require("util")
local config = require("config")
local rules = require("rules")
local N = require("names")

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
local timer_offline = {} -- timer id -> unix s since which the stream looked offline
local OFFLINE_GRACE_S = 120
local SEEN_WINDOW_S = 7200 -- a mute target must have chatted within this time
local seen = {} -- "chan|login" -> unix seconds of last message
local seen_count = 0
local mods = {} -- "chan|login" -> true when seen with a moderator badge
local done_ids = {} -- redemption message ids already handled
local done_count = 0
local warned_mod = {}
local DEFAULT_BOTS = {
    nightbot = true, streamelements = true, streamlabs = true,
    moobot = true, fossabot = true, wizebot = true,
}
E.debug_redeem = false -- session-only: print what the plugin sees on redemptions

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
        E.deactivate("время вышло, авто-ответ выключен.")
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
-- Validates reply text shared by rules and timers. Returns ok, err.
function E.check_reply(reply)
    if type(reply) ~= "string" or not reply:match("%S") then
        return false, "нужен текст ответа"
    end
    if #reply > 500 then
        return false, "ответ длиннее 500 символов"
    end
    local first = reply:sub(1, 1)
    if first == "/" or first == "." then
        return false, "ответ не должен начинаться с «/» или «.» (это выполнилось бы как команда)"
    end
    return true
end

-- conditions: list of {type=, match=}; ALL must match for the rule to fire.
function E.add_rule(conditions, reply, channels, name)
    if type(conditions) ~= "table" or #conditions == 0 then
        return nil, "в правиле должно быть хотя бы одно условие"
    end
    for _, c in ipairs(conditions) do
        local ok, err = rules.validate(c.type, c.match)
        if not ok then
            return nil, c.type .. ": " .. err
        end
    end
    local rok, rerr = E.check_reply(reply)
    if not rok then
        return nil, rerr
    end
    if name ~= nil then
        local nok, nerr = N.check(E.cfg.rules, name, "rules")
        if not nok then
            return nil, nerr
        end
    end
    local cfg = E.cfg
    local id = cfg.next_rule_id
    cfg.next_rule_id = id + 1
    cfg.rules[#cfg.rules + 1] = {
        id = id, name = name, conditions = conditions, reply = reply,
        enabled = true, channels = channels or {},
    }
    E.save()
    return id
end

-- chans: list of channel logins; {} = all channels.
function E.set_rule_channels(rule, chans)
    rule.channels = chans or {}
    E.save()
end

-- key: "rules" | "timers" | "redeems"; new = nil clears the name. Returns ok, err.
function E.rename(key, item, new)
    if new ~= nil then
        local ok, err = N.check(E.cfg[key], new, key, item)
        if not ok then
            return false, err
        end
    end
    item.name = new
    E.save()
    return true
end

function E.find_rule(id)
    for i, r in ipairs(E.cfg.rules) do
        if r.id == id then
            return r, i
        end
    end
end

-- ---------- time counters ----------
function E.find_timer(id)
    for i, t in ipairs(E.cfg.timers) do
        if t.id == id then
            return t, i
        end
    end
end

-- Cached stream status of a timer's channel, or nil when unknown.
local function stream_status(t)
    local h = handles[t.channel]
    if not h then
        return nil
    end
    local ok, st = pcall(function()
        if not h.channel:is_valid() then
            return nil
        end
        return h.channel:get_stream_status()
    end)
    if ok and type(st) == "table" then
        return st
    end
    return nil
end

local function start_counting(t, offset_s)
    t.enabled = true
    t.started_at = util.now_s() - (offset_s or 0)
    timer_offline[t.id] = nil
    local st = stream_status(t)
    t.game_id = (st and st.live and st.game_id ~= "" and st.game_id) or nil
end

function E.add_timer(trigger, channel, reply, format, name)
    if not trigger or trigger == "" then
        return nil, "нужно слово-триггер"
    end
    local rok, rerr = E.check_reply(reply)
    if not rok then
        return nil, rerr
    end
    if not reply:find("{time}", 1, true) then
        return nil, "в ответе должен быть {time}"
    end
    if name ~= nil then
        local nok, nerr = N.check(E.cfg.timers, name, "timers")
        if not nok then
            return nil, nerr
        end
    end
    local cfg = E.cfg
    local t = {
        id = cfg.next_timer_id, name = name, trigger = trigger, channel = channel,
        reply = reply, format = format or "smart", on_category = "reset",
    }
    cfg.next_timer_id = t.id + 1
    start_counting(t)
    cfg.timers[#cfg.timers + 1] = t
    E.save()
    return t.id
end

function E.set_timer_enabled(t, on, offset_s)
    if on then
        start_counting(t, offset_s)
    else
        t.enabled = false
        t.started_at = nil
        t.game_id = nil
        timer_offline[t.id] = nil
    end
    E.save()
end

function E.reset_timer(t, offset_s)
    start_counting(t, offset_s)
    E.save()
end

function E.timer_elapsed(t)
    if not t.started_at then
        return nil
    end
    return math.max(0, util.now_s() - t.started_at)
end

-- Guards, called from the poll tick: stop on offline, react to category change.
function E.check_timers()
    local now = util.now_s()
    local dirty = false
    for _, t in ipairs(E.cfg.timers) do
        local st = (t.enabled and t.started_at) and stream_status(t) or nil
        if st then
            if st.live then
                timer_offline[t.id] = nil
                local gid = st.game_id or ""
                if gid ~= "" then
                    if not t.game_id or t.game_id == "" then
                        t.game_id = gid
                        dirty = true
                    elseif gid ~= t.game_id and t.on_category ~= "off" then
                        local game = (st.game_name and st.game_name ~= "") and st.game_name or gid
                        if t.on_category == "stop" then
                            E.set_timer_enabled(t, false)
                            E.notify(string.format("счётчик %s (%s) остановлен: категория сменилась на %s.",
                                N.label(t), t.trigger, game), nil)
                        else
                            t.started_at = now
                            t.game_id = gid
                            dirty = true
                            E.notify(string.format("счётчик %s (%s) перезапущен: категория сменилась на %s.",
                                N.label(t), t.trigger, game), nil)
                        end
                    end
                end
            else
                local since = timer_offline[t.id] or now
                timer_offline[t.id] = since
                if now - since >= OFFLINE_GRACE_S then
                    E.set_timer_enabled(t, false)
                    E.notify(string.format("счётчик %s (%s) остановлен: стрим ушёл в офлайн.", N.label(t), t.trigger))
                end
            end
        end
    end
    if dirty then
        E.save()
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
        pcall(E.check_timers)
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
        if item.command then
            -- moderation command built internally from a validated login: executed as a command
            ch:send_message(text, true)
        else
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
        end
        last_send_ms = util.now_ms()
    end
    if #queue > 0 then
        schedule_pump(math.max(gap_ms, 1100))
    end
end

-- {user} in the reply becomes the sender's name.
local function render(reply, msg, time_text)
    local name = msg.display_name
    if not name or name == "" then
        name = msg.login_name
    end
    local out = reply:gsub("{user}", function() return name end)
    if time_text then
        out = out:gsub("{time}", function() return time_text end)
    end
    return out:sub(1, 500)
end

E.render = render -- also used by /autoreply test

local function enqueue(channel, text, command)
    if #queue >= MAX_QUEUE then
        table.remove(queue, 1)
    end
    queue[#queue + 1] = { channel = channel, text = text, command = command }
    schedule_pump(FIRST_DELAY_MS)
end

-- ---------- channel-point rewards -> /timeout, /untimeout ----------
function E.add_redeem(channel, action, title, seconds, name)
    if action ~= "timeout" and action ~= "untimeout" then
        return nil, "действие должно быть timeout или untimeout"
    end
    if type(title) ~= "string" or not title:match("%S") then
        return nil, "нужно название награды"
    end
    if action == "timeout" and (type(seconds) ~= "number" or seconds < 1 or seconds > 1209600) then
        return nil, "время мута должно быть от 1s до 14d"
    end
    local lt = rules.lower(title)
    for _, r in ipairs(E.cfg.redeems) do
        if r.channel == channel and rules.lower(r.title) == lt then
            return nil, "для этой награды уже есть правило #" .. r.id
        end
    end
    if name ~= nil then
        local nok, nerr = N.check(E.cfg.redeems, name, "redeems")
        if not nok then
            return nil, nerr
        end
    end
    local cfg = E.cfg
    local r = {
        id = cfg.next_redeem_id, name = name, channel = channel, title = title, action = action,
        seconds = action == "timeout" and seconds or nil, enabled = true,
    }
    cfg.next_redeem_id = r.id + 1
    cfg.redeems[#cfg.redeems + 1] = r
    E.save()
    return r.id
end

function E.find_redeem(id)
    for i, r in ipairs(E.cfg.redeems) do
        if r.id == id then
            return r, i
        end
    end
end

local function has_redeems(chan_name)
    for _, r in ipairs(E.cfg.redeems) do
        if r.channel == chan_name then
            return true
        end
    end
    return false
end

-- Remembers who chatted recently and who wears a moderator badge.
local function note_user(chan_name, msg, login)
    if login == "" or not has_redeems(chan_name) then
        return
    end
    local now = util.now_s()
    if seen_count > 3000 then
        seen_count = 0
        for k, t in pairs(seen) do
            if now - t > SEEN_WINDOW_S then
                seen[k] = nil
            else
                seen_count = seen_count + 1
            end
        end
    end
    local key = chan_name .. "|" .. login
    if not seen[key] then
        seen_count = seen_count + 1
    end
    seen[key] = now
    if not mods[key] and rules.has_mod_badge(msg) then
        mods[key] = true
    end
end

local function is_protected(chan_name, login, me)
    return login == chan_name or login == me
        or util.contains(E.cfg.protect_users, login) ~= nil
        or util.contains(E.cfg.ignore_users, login) ~= nil
        or DEFAULT_BOTS[login] == true
        or mods[chan_name .. "|" .. login] == true
end

local function debug_dump(ch, msg, flags, title)
    local parts = {}
    pcall(function()
        for _, el in ipairs(msg:elements()) do
            local w = ""
            if type(el.words) == "table" then w = " words=" .. table.concat(el.words, " ") end
            parts[#parts + 1] = string.format("%s(flags=%s%s%s)", tostring(el.type), tostring(el.flags),
                (type(el.tooltip) == "string" and el.tooltip ~= "") and (" tip=" .. el.tooltip) or "", w)
        end
    end)
    E.notify(string.format("redeem debug: flags=%s text=[%s] title=[%s] id=%s", tostring(flags),
        tostring(msg.message_text), tostring(title), tostring(msg.id)), ch)
    E.notify("redeem debug elements: " .. table.concat(parts, "; "), ch)
end

-- Handles a redemption message. Returns true when it was consumed (matched a
-- redeem rule), so normal rules must not run on it.
local function handle_redeem(chan_name, ch, msg, text, me, sender, flags)
    if not has_redeems(chan_name) then
        return false
    end
    local title = rules.reward_title(msg)
    if E.debug_redeem then
        debug_dump(ch, msg, flags, title)
    end
    local hay = rules.lower(title or text)
    local rule
    for _, r in ipairs(E.cfg.redeems) do
        if r.enabled ~= false and r.channel == chan_name and hay:find(rules.lower(r.title), 1, true) then
            rule = r
            break
        end
    end
    if not rule then
        return false
    end
    if msg.id and msg.id ~= "" then
        if done_ids[msg.id] then
            return true
        end
        if done_count > 500 then
            done_ids, done_count = {}, 0
        end
        done_ids[msg.id] = true
        done_count = done_count + 1
    end
    local okmod, ismod = pcall(function() return ch:is_mod() or ch:is_broadcaster() end)
    if not okmod or not ismod then
        if not warned_mod[chan_name] then
            warned_mod[chan_name] = true
            E.notify("в " .. chan_name .. " нет прав модератора, награды-модерация не работают.", ch)
        end
        return true
    end
    local target, err = rules.parse_target(text)
    if not target then
        E.notify(string.format("%s (%s): не выполнено: %s.", sender, rule.title, err), ch)
        return true
    end
    if rule.action == "untimeout" then
        enqueue(chan_name, "/untimeout " .. target, true)
        E.notify(string.format("%s: размут %s.", sender, target), ch)
        return true
    end
    local victim = target
    if is_protected(chan_name, target, me) then
        if not E.cfg.backfire then
            E.notify(string.format("%s: мут %s не выполнен: пользователь защищён.", sender, target), ch)
            return true
        end
        if is_protected(chan_name, sender, me) then
            E.notify(string.format("%s: целился в защищённого %s, но сам тоже защищён; ничего не сделано.", sender, target), ch)
            return true
        end
        victim = sender
        E.notify(string.format("%s: целился в защищённого %s, мут получает он сам.", sender, target), ch)
    elseif not E.cfg.mute_lurkers then
        local t = seen[chan_name .. "|" .. target]
        if not t or util.now_s() - t > SEEN_WINDOW_S then
            E.notify(string.format("%s: мут %s не выполнен: его не было в чате за последние 2 часа (проверьте ник).", sender, target), ch)
            return true
        end
    end
    enqueue(chan_name, string.format("/timeout %s %d", victim, rule.seconds), true)
    E.notify(string.format("%s: мут %s на %s.", sender, victim, util.format_duration(rule.seconds)), ch)
    return true
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
    SKIP = SKIP or skip_flags()
    local flags = msg.flags or 0
    if (flags & SKIP) ~= 0 then
        return
    end
    note_user(chan_name, msg, util.norm_user(msg.login_name))
    if not E.is_active() then
        return
    end
    local acct = c2.current_account()
    if not acct or not acct:is_valid() or acct:is_anon() then
        if not warned_anon then
            warned_anon = true
            E.notify("нет аккаунта, в который выполнен вход: авто-ответ не сможет отправлять сообщения.", ch)
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

    local redeem_bit = c2.MessageFlag.RedeemedChannelPointReward or 0
    if redeem_bit ~= 0 and (flags & redeem_bit) ~= 0
        and handle_redeem(chan_name, ch, msg, text, me, sender, flags) then
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

    -- time counters (explicit commands) take priority over rules
    for _, t in ipairs(E.cfg.timers) do
        if t.enabled and t.started_at and t.channel == chan_name
            and rules.matches_one({ type = "word", match = t.trigger }, text, flags, me)
        then
            local rkey = chan_name .. "|t" .. tostring(t.id)
            local last_rule = rule_cd[rkey]
            if not (last_rule and now - last_rule < E.cfg.per_rule_cooldown) then
                user_cd[ukey] = now
                rule_cd[rkey] = now
                enqueue(chan_name, render(t.reply, msg, util.format_elapsed(E.timer_elapsed(t), t.format)))
            end
            return
        end
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
