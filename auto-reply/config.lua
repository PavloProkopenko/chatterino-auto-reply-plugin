-- Loads/saves data/config.json (the plugin's data dir; relative paths in
-- io.open resolve there).
local json = require("chatterino.json")

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
