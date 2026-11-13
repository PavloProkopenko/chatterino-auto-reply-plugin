-- Loads/saves data/config.json (the plugin's data dir; relative paths in
-- io.open resolve there).
local json = require("chatterino.json")
local names = require("names")
local util = require("util")
local rules = require("rules")

local M = {}
local FILE = "config.json"

function M.defaults()
    return {
        version = 1,
        -- nil = off, "forever" = on across restarts, number = unix expiry.
        -- "session" (on until the app closes) is never written to disk.
        active_until = nil,
        channels = {},
        ignore_users = {},
        per_user_cooldown = 60, -- seconds, per user per channel
        per_rule_cooldown = 10, -- seconds, per rule per channel
        global_min_gap = 2, -- seconds between any two auto-replies
        only_when_live = false,
        next_rule_id = 1,
        rules = {},
        -- time counters: {id, conditions = [{type, match}] (legacy: trigger = one word),
        -- channel, reply, format, on_category, enabled, started_at, game_id}
        next_timer_id = 1,
        timers = {},
        -- channel-point rewards -> /timeout|/untimeout:
        -- {id, channel, title, action = timeout|untimeout, seconds, enabled}
        next_redeem_id = 1,
        redeems = {},
        protect_users = {}, -- never muted by a redeem (mods, bots, vips)
        mute_lurkers = false, -- false: target must have chatted in the last 2h
        backfire = true, -- protected target -> the redeemer gets the mute
    }
end

local function read_all(name)
    local f = io.open(name, "r")
    if not f then
        return nil
    end
    local data = f:read("a")
    f:close()
    return data
end

local function write_all(name, data)
    local f = io.open(name, "w")
    if not f then
        return false
    end
    f:write(data)
    f:close()
    return true
end

-- Returns cfg, warning (string or nil).
function M.load()
    local raw = read_all(FILE)
    if not raw or raw == "" then
        return M.defaults(), nil
    end
    local ok, parsed = pcall(json.parse, raw)
    if not ok or type(parsed) ~= "table" then
        write_all(FILE .. ".bad", raw)
        return M.defaults(),
            "config.json was corrupt; saved a copy as config.json.bad and started fresh."
    end
    local cfg = M.defaults()
    for k, v in pairs(parsed) do
        cfg[k] = v
    end
    -- sanitize
    if type(cfg.channels) ~= "table" then cfg.channels = {} end
    if type(cfg.ignore_users) ~= "table" then cfg.ignore_users = {} end
    if type(cfg.rules) ~= "table" then cfg.rules = {} end
    if type(cfg.timers) ~= "table" then cfg.timers = {} end
    if type(cfg.next_timer_id) ~= "number" then cfg.next_timer_id = 1 end
    if type(cfg.protect_users) ~= "table" then cfg.protect_users = {} end
    if type(cfg.next_redeem_id) ~= "number" then cfg.next_redeem_id = 1 end
    if type(cfg.mute_lurkers) ~= "boolean" then cfg.mute_lurkers = false end
    if type(cfg.backfire) ~= "boolean" then cfg.backfire = true end
    if type(cfg.redeems) ~= "table" then cfg.redeems = {} end
    -- rule channel scope: never widen a bound rule to global because of bad data
    for _, r in ipairs(cfg.rules) do
        if type(r) == "table" and r.channels ~= nil then
            local clean = {}
            if type(r.channels) == "table" then
                for _, c in ipairs(r.channels) do
                    c = type(c) == "string" and c:lower():gsub("^#", "") or ""
                    if c:match("^[%w_]+$") and not util.contains(clean, c) then
                        clean[#clean + 1] = c
                    end
                end
                if #clean == 0 and #r.channels > 0 then
                    r.enabled = false
                end
            elseif r.channels ~= false then
                r.enabled = false
            end
            r.channels = clean
        end
    end
    local goodr = {}
    for _, r in ipairs(cfg.redeems) do
        if type(r) == "table" and type(r.id) == "number" and type(r.channel) == "string"
            and type(r.title) == "string" and r.title ~= ""
            and (r.action == "timeout" or r.action == "untimeout") then
            if r.action == "timeout" and not (type(r.seconds) == "number" and r.seconds >= 1 and r.seconds <= 1209600) then
                r = nil
            end
            if r then goodr[#goodr + 1] = r end
        end
    end
    cfg.redeems = goodr
    local good = {}
    for _, t in ipairs(cfg.timers) do
        if type(t) == "table" and (type(t.trigger) == "string" or type(t.conditions) == "table")
            and type(t.channel) == "string"
            and type(t.reply) == "string" and type(t.id) == "number" then
            -- every condition must be valid; otherwise disable (never match everything)
            if type(t.conditions) == "table" then
                local okc = #t.conditions > 0
                for _, c in ipairs(t.conditions) do
                    if type(c) ~= "table" or type(c.type) ~= "string" or not rules.validate(c.type, c.match) then
                        okc = false
                    end
                end
                if not okc then
                    t.enabled = false
                    t.started_at = nil
                end
            end
            if type(t.started_at) ~= "number" then
                t.started_at = nil
                t.enabled = false
            end
            if t.format ~= "full" then t.format = "smart" end
            if t.on_category ~= "stop" and t.on_category ~= "off" then t.on_category = "reset" end
            good[#good + 1] = t
        end
    end
    cfg.timers = good
    -- drop invalid or duplicate names (hand-edited files)
    for _, list in ipairs({ cfg.rules, cfg.timers, cfg.redeems }) do
        local used = {}
        for _, it in ipairs(list) do
            if type(it) == "table" and it.name ~= nil then
                local ok = type(it.name) == "string" and names.valid(it.name)
                if ok and not used[names.key(it.name)] then
                    used[names.key(it.name)] = true
                else
                    it.name = nil
                end
            end
        end
    end
    for _, key in ipairs({ "per_user_cooldown", "per_rule_cooldown", "global_min_gap" }) do
        if type(cfg[key]) ~= "number" or cfg[key] < 0 then
            cfg[key] = M.defaults()[key]
        end
    end
    return cfg, nil
end

function M.save(cfg)
    local ok, out = pcall(json.stringify, cfg)
    if not ok then
        c2.log(c2.LogLevel.Warning, "auto-reply: could not serialize config: " .. tostring(out))
        return false
    end
    if not write_all(FILE, out) then
        c2.log(c2.LogLevel.Warning, "auto-reply: could not write config.json")
        return false
    end
    return true
end

return M
