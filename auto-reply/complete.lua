-- Tab-completion for /autoreply (and /ar): context-aware, real values only.
local E = require("engine")
local rules = require("rules")
local commands = require("commands")

local C = {}

local SUBCOMMANDS = {
    "on", "off", "toggle", "status", "channel", "add", "new", "list", "test", "remove",
    "enable", "disable", "timer", "ignore", "redeem", "protect", "set", "reload", "help",
    "cancel", "back", "rule", "rename",
}
local TIMER_VERBS = { "add", "list", "on", "off", "reset", "set", "remove", "format", "category" }
local REDEEM_VERBS = { "add", "list", "remove", "enable", "disable", "debug" }
local RULE_VERBS = { "enable", "disable", "remove", "channel", "test" }
local RENAME_KINDS = { "rule", "timer", "redeem" }

local function set_of(list)
    local s = {}
    for _, v in ipairs(list) do s[v] = true end
    return s
end
local TIMER_VERB_SET, REDEEM_VERB_SET = set_of(TIMER_VERBS), set_of(REDEEM_VERBS)
local DURATIONS = { "30m", "2h", "1d", "forever" }
local ON_OFF = { "on", "off" }

local function ids_of(list)
    local out = {}
    for _, item in ipairs(list) do
        out[#out + 1] = tostring(item.id)
    end
    return out
end

-- ids followed by names
local function refs_of(list)
    local out = ids_of(list)
    for _, item in ipairs(list) do
        if type(item.name) == "string" then
            out[#out + 1] = item.name
        end
    end
    return out
end

local function names_of(list)
    local out = {}
    for _, item in ipairs(list) do
        if type(item.name) == "string" then
            out[#out + 1] = item.name
        end
    end
    return out
end

local function concat_lists(a, b)
    local out = {}
    for _, v in ipairs(a) do out[#out + 1] = v end
    for _, v in ipairs(b) do out[#out + 1] = v end
    return out
end

local KIND_LIST = { rule = "rules", rules = "rules", timer = "timers", timers = "timers",
    redeem = "redeems", redeems = "redeems", mute = "redeems" }

local function help_topics()
    local out = {}
    for _, t in ipairs(commands.TOPICS) do
        out[#out + 1] = t.key
    end
    out[#out + 1] = "all"
    return out
end

-- args: completed words after the command name, lowercased. Returns candidate list or nil.
local function candidates(args)
    local n = #args
    if n == 0 then
        return SUBCOMMANDS
    end
    local sub = args[1]
    local prev = args[n]
    local prev2 = args[n - 1]
    local cfg = E.cfg
    if sub == "help" then
        if n == 1 then return help_topics() end
        if n == 2 and (prev == "add" or prev == "rule") then return rules.TYPES end
    elseif sub == "on" then
        if n == 1 then return DURATIONS end
    elseif sub == "channel" or sub == "channels" then
        if n == 1 then return { "add", "remove", "list" } end
        if n == 2 and prev == "remove" then return cfg.channels end
    elseif sub == "add" then
        if prev == "add" or prev == "+" or prev:match("^channel=") or prev:match("^name=") then
            return rules.TYPES
        end
        if prev == "flag" and (prev2 == "add" or prev2 == "+") then
            return rules.FLAG_ORDER
        end
    elseif sub == "remove" or sub == "enable" or sub == "disable" then
        if n == 1 then return refs_of(cfg.rules) end
    elseif sub == "test" then
        if n == 1 then
            local out = refs_of(cfg.rules)
            out[#out + 1] = "all"
            return out
        end
    elseif sub == "rule" then
        if n == 1 then return refs_of(cfg.rules) end
        if n == 2 then return RULE_VERBS end
        if n == 3 and prev == "channel" then return concat_lists({ "all", "here" }, cfg.channels) end
    elseif sub == "rename" then
        if n == 1 then return RENAME_KINDS end
        if n == 2 and KIND_LIST[prev] then return refs_of(cfg[KIND_LIST[prev]]) end
    elseif sub == "timer" or sub == "timers" then
        if n == 1 then return concat_lists(TIMER_VERBS, names_of(cfg.timers)) end
        if n == 2 and not TIMER_VERB_SET[prev] then return TIMER_VERBS end -- name-first form
        if args[2] == "add" then
            if prev == "add" or prev == "+" or prev:match("^name=") then return rules.TYPES end
            if prev == "flag" and (prev2 == "add" or prev2 == "+") then return rules.FLAG_ORDER end
            if prev == "=>" then return { "smart", "full" } end
            return nil
        end
        if n == 2 and prev ~= "add" and prev ~= "list" then return refs_of(cfg.timers) end
        if n == 3 and (args[2] == "format" or prev == "format") then return { "smart", "full" } end
        if n == 3 and (args[2] == "category" or prev == "category") then return { "reset", "stop", "off" } end
    elseif sub == "ignore" then
        if n == 1 then return { "add", "remove", "list" } end
        if n == 2 and prev == "remove" then return cfg.ignore_users end
    elseif sub == "protect" then
        if n == 1 then return { "add", "remove", "list" } end
        if n == 2 and prev == "remove" then return cfg.protect_users end
    elseif sub == "redeem" or sub == "mute" then
        if n == 1 then return concat_lists(REDEEM_VERBS, names_of(cfg.redeems)) end
        if n == 2 and not REDEEM_VERB_SET[prev] then return REDEEM_VERBS end -- name-first form
        if n == 2 and prev == "add" then return { "timeout", "untimeout" } end
        if n == 2 and (prev == "remove" or prev == "enable" or prev == "disable") then
            return refs_of(cfg.redeems)
        end
        if n == 2 and prev == "debug" then return ON_OFF end
    elseif sub == "set" then
        if n == 1 then return { "usercd", "rulecd", "gap", "live", "mutelurkers", "backfire" } end
        if n == 2 and (prev == "live" or prev == "mutelurkers" or prev == "backfire") then
            return ON_OFF
        end
    end
    return nil
end

-- Pure part, testable without Chatterino: text before the cursor -> values or nil.
function C.complete(text)
    local lead = text:match("^%s*(%S+)")
    if not lead then return nil end
    lead = lead:lower()
    if lead ~= "/autoreply" and lead ~= "/ar" then return nil end
    local words = {}
    for w in text:gmatch("%S+") do
        words[#words + 1] = w
    end
    local current = ""
    if not text:match("%s$") then
        current = table.remove(words) or ""
    end
    if #words == 0 then
        return nil -- still typing the command name itself
    end
    local args = {}
    for i = 2, #words do
        args[#args + 1] = words[i]:lower()
    end
    local list = candidates(args)
    if args[1] == "add" and current:lower():match("^channel=") then
        list = {}
        for _, v in ipairs(concat_lists({ "all", "here" }, E.cfg.channels)) do
            list[#list + 1] = "channel=" .. v
        end
    end
    if not list then return nil end
    local want = current:lower()
    local out = {}
    for _, v in ipairs(list) do
        if want == "" or v:lower():sub(1, #want) == want then
            out[#out + 1] = v
        end
    end
    return out
end

-- Chatterino replaces the "word under the cursor" with the chosen value on EVERY Tab
-- (QCompleter::highlighted -> insertCompletion), reusing the same value list. So values
-- must be bare words for the word being typed. After a trailing space the "word" is the
-- previous word + space; a prefixed value fixes the first Tab but every later Tab then
-- prepends it again ("/ar /ar /ar ..."), so there we offer nothing.
-- text: input up to the cursor. Returns values or nil.
function C.complete_for_event(text)
    if text:match("%s$") then
        return nil
    end
    local res = C.complete(text)
    if not res or #res == 0 then
        return nil
    end
    return res
end

function C.handler(event)
    local empty = { values = {}, hide_others = false }
    local ok, res = pcall(function()
        local text = event.full_text_content or ""
        local pos = event.cursor_position
        if type(pos) == "number" then
            local byte = utf8.offset(text, pos + 1)
            if byte then
                text = text:sub(1, byte - 1)
            end
        end
        return C.complete_for_event(text)
    end)
    if not ok or not res or #res == 0 then
        return empty
    end
    return { values = res, hide_others = true }
end

return C
