-- Shared user-facing helpers: output, hints after adding a rule, soft warnings.
local util = require("util")
local rules = require("rules")
local E = require("engine")

local U = {}

function U.say(ctx, text)
    ctx.channel:add_system_message("[auto-reply] " .. text)
end

-- Own login (lowercase) or "".
function U.my_login()
    local ok, res = pcall(function()
        local acct = c2.current_account()
        if acct and acct:is_valid() and not acct:is_anon() then
            return util.norm_user(acct:login())
        end
        return ""
    end)
    return ok and res or ""
end

-- The one-line command equivalent to a list of conditions + reply.
function U.cmd_line(conds, reply)
    local parts = {}
    for _, c in ipairs(conds) do
        if c.type == "mention" then
            parts[#parts + 1] = "mention"
        elseif c.type == "flag" then
            parts[#parts + 1] = "flag " .. c.match
        else
            parts[#parts + 1] = c.type .. ' "' .. c.match .. '"'
        end
    end
    return "/autoreply add " .. table.concat(parts, " + ") .. " " .. reply
end

-- Non-blocking advice about a rule that was just added.
-- unquoted: the first condition whose text was taken as a single unquoted word (or nil).
function U.soft_warnings(ctx, conds, reply, unquoted)
    if unquoted then
        local words = 0
        for _ in reply:gmatch("%S+") do
            words = words + 1
        end
        if words >= 2 then
            U.say(ctx, string.format(
                'проверьте: условие «%s» взято как одно слово. Если нужна фраза, возьмите её в кавычки: %s "...".',
                unquoted.match, unquoted.type))
        end
    end
    local noted_pattern = false
    for _, c in ipairs(conds) do
        local m = c.match
        if c.type == "keyword" and m and m:match("^[%w_\128-\255]+$") and (utf8.len(m) or #m) <= 5 then
            U.say(ctx, string.format(
                "keyword «%s» сработает и внутри других слов; для отдельного слова используйте word.", m))
        elseif (c.type == "keyword" or c.type == "word") and m and m:find("|", 1, true) then
            U.say(ctx, "знак | в keyword/word — обычный символ; для списка слов используйте anyword.")
        elseif c.type == "pattern" then
            if not noted_pattern then
                noted_pattern = true
                U.say(ctx, "pattern — это шаблон Lua, не regex.")
            end
            if m and not m:find("[%^%$%(%)%%%.%[%]%*%+%-%?]") then
                U.say(ctx, "в шаблоне нет спецсимволов; проще использовать keyword.")
            end
        end
    end
end

-- Context and next steps after a rule was added.
function U.after_add(ctx, id, conds)
    local cfg = E.cfg
    if not E.active then
        U.say(ctx, "авто-ответ сейчас выключен: включите командой /autoreply on [30m|2h|forever].")
    end
    if #cfg.channels == 0 then
        U.say(ctx, "каналов пока нет: добавьте командой /autoreply channel add <канал>.")
    else
        U.say(ctx, string.format("правило действует во всех добавленных каналах (%d).", #cfg.channels))
    end
    local text, flags = rules.sample(conds, U.my_login())
    if text == "" then
        text = "<сообщение>"
    end
    local fl = #flags > 0 and ("flags=" .. table.concat(flags, ",") .. " ") or ""
    U.say(ctx, string.format("проверить без отправки: /autoreply test %d %s%s", id, fl, text))
    local rule = E.find_rule(id)
    if rule and not rule.name then
        U.say(ctx, string.format("дать правилу имя: /autoreply rename rule %d <имя> (или сразу при создании: add name=<имя> ...)", id))
    end
end

return U
