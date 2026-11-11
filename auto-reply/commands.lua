-- /autoreply subcommands.
local util = require("util")
local rules = require("rules")
local E = require("engine")

local M = {}

local HELP = {
    "=== Авто-ответ: справка ===",
    "Включить авто-ответ. Период: 30m = 30 минут, 2h = 2 часа, 1d = 1 день, 1h30m = 1,5 часа. Без периода работает, пока открыто приложение. forever = всегда (сохраняется после перезапуска).",
    "/autoreply on [30m|2h|1d|forever]",
    "Выключить авто-ответ полностью. toggle = переключить вкл/выкл одним действием. status = показать текущее состояние и настройки.",
    "/autoreply off | toggle | status",
    "Каналы, в которых работает авто-ответ. add = добавить, remove = убрать, list = показать список. Канал должен быть открыт в окне (сплите).",
    "/autoreply channel add|remove|list <канал>",
    "Добавить правило: если сообщение подходит под условие, бот отправит ответ. keyword = текст встречается где угодно в сообщении (например !test). word = отдельное слово. pattern = шаблон Lua (для опытных, это не regex). Фразу с пробелами берите в кавычки.",
    '/autoreply add keyword|word|pattern "<текст>" <ответ>',
    "anyword = любое из нескольких слов (отдельное слово, регистр не важен, работает и с русским). Варианты через знак |. Ответ может содержать {user}: туда подставится ник написавшего. Пример: add mention + anyword \"qq|привет|hi\" @{user} qq",
    '/autoreply add anyword "<слово1|слово2|слово3>" <ответ>',
    "Правило на упоминание: срабатывает, когда кто-то пишет @ваш_ник или ваш ник.",
    "/autoreply add mention <ответ>",
    "Правило по типу сообщения: first = первое сообщение зрителя, highlighted = выделенное, reply = ответ на сообщение, announcement = объявление, sub = подписка, cheer = биты.",
    "/autoreply add flag first|highlighted|reply|announcement|sub|cheer <ответ>",
    "Несколько условий сразу: знак + означает И, то есть должны совпасть ВСЕ условия. Пример: add mention + keyword qq Привет!",
    "/autoreply add <условие> + <условие> <ответ>",
    "Управление правилами: list = показать все с номерами, remove = удалить, enable/disable = включить/выключить одно правило. <id> это номер из list.",
    "/autoreply list | remove <id> | enable <id> | disable <id>",
    "Игнор-список: сообщения этих пользователей не вызывают ответ (например, другие боты вроде Nightbot). Ваш собственный аккаунт игнорируется всегда.",
    "/autoreply ignore add|remove|list <пользователь>",
    "Настройки пауз (в секундах). usercd = пауза для одного пользователя: бот не ответит ему чаще, чем раз в N секунд (по умолчанию 60). rulecd = пауза для одного правила в канале (по умолчанию 10). gap = минимальный промежуток между любыми двумя ответами бота (по умолчанию 2, минимум 1).",
    "/autoreply set usercd|rulecd|gap <секунды>",
    "Отвечать только когда стрим идёт (live): on = да, off = в любое время.",
    "/autoreply set live on|off",
    "Перечитать настройки из файла data/config.json (если вы правили его вручную).",
    "/autoreply reload",
    "Важно: ответ работает только когда авто-ответ включён, и правило без текста ответа никогда не срабатывает.",
}

local function say(ctx, text)
    ctx.channel:add_system_message("[auto-reply] " .. text)
end

local function help(ctx)
    for _, line in ipairs(HELP) do
        ctx.channel:add_system_message(line)
    end
end

local function status(ctx)
    local cfg = E.cfg
    local state
    if not E.active then
        state = "OFF"
    elseif E.expires then
        state = "ON for " .. util.format_duration(E.expires - util.now_s()) .. " more"
    elseif E.session_only then
        state = "ON until the app closes"
    else
        state = "ON (forever)"
    end
    say(ctx, "status: " .. state)
    local chans = {}
    for _, c in ipairs(cfg.channels) do
        chans[#chans + 1] = c .. (E.hooked(c) and "" or " (not open)")
    end
    say(ctx, "channels: " .. (#chans > 0 and table.concat(chans, ", ") or "none"))
    local usable = 0
    for _, r in ipairs(cfg.rules) do
        if rules.is_usable(r) then usable = usable + 1 end
    end
    say(ctx, string.format("rules: %d (%d active) | cooldowns user %ds, rule %ds, gap %ds | only when live: %s",
        #cfg.rules, usable, cfg.per_user_cooldown, cfg.per_rule_cooldown,
        cfg.global_min_gap, cfg.only_when_live and "yes" or "no"))
    if E.active and #cfg.channels == 0 then
        say(ctx, "warning: no channels configured; use /autoreply channel add <name>")
    end
    if E.active and usable == 0 then
        say(ctx, "warning: no usable rules (each needs a trigger and a reply); use /autoreply add ...")
    end
end

local function cmd_on(ctx, words)
    local arg = words[3]
    if arg == nil then
        E.activate(nil, false)
        say(ctx, "enabled until the app closes.")
    elseif arg:lower() == "forever" then
        E.activate(nil, true)
        say(ctx, "enabled permanently (survives restarts).")
    else
        local secs = util.parse_duration(arg)
        if not secs then
            say(ctx, "invalid period '" .. arg .. "'. Use e.g. 30m, 2h, 1d, 1h30m or forever.")
            return
        end
        E.activate(secs, false)
        say(ctx, "enabled for " .. util.format_duration(secs) .. ".")
    end
    status(ctx)
end

local function cmd_channel(ctx, words)
    local sub, name = words[3], util.norm_channel(words[4])
    local list = E.cfg.channels
    if sub == "list" then
        say(ctx, "channels: " .. (#list > 0 and table.concat(list, ", ") or "none"))
    elseif sub == "add" and name ~= "" then
        if util.contains(list, name) then
            say(ctx, name .. " is already in the list.")
            return
        end
        list[#list + 1] = name
        E.save()
        E.sync_hooks()
        say(ctx, "added " .. name .. (E.hooked(name) and "." or " (channel is not open in a split yet; it will hook automatically once opened)."))
    elseif sub == "remove" and name ~= "" then
        local i = util.contains(list, name)
        if not i then
            say(ctx, name .. " is not in the list.")
            return
        end
        table.remove(list, i)
        E.save()
        E.sync_hooks()
        say(ctx, "removed " .. name .. ".")
    else
        say(ctx, "usage: /autoreply channel add|remove|list <name>")
    end
end

-- Parses: <quoted or single token> <rest>. Returns token, rest.
local function take_arg(s)
    s = s:gsub("^%s+", "")
    local q = s:sub(1, 1)
    if q == '"' then
        local tok, rest = s:match('^"(.-)"%s*(.*)$')
        if tok then
            return tok, rest
        end
        return nil, s
    end
    local tok, rest = s:match("^(%S+)%s*(.*)$")
    return tok, rest
end

local NO_ARG = { mention = true }

local function cmd_add(ctx, words)
    if not words[3] then
        say(ctx, "usage: /autoreply add <cond> [+ <cond> ...] <reply>   (cond: keyword|word|pattern \"x\", flag <name>, mention)")
        return
    end
    local rest = table.concat(words, " ", 3)
    local conditions = {}
    while true do
        local rtype
        rtype, rest = take_arg(rest)
        if not rtype then
            say(ctx, "missing condition type.")
            return
        end
        rtype = rtype:lower()
        local cond = { type = rtype }
        if not NO_ARG[rtype] then
            local match
            match, rest = take_arg(rest)
            if not match then
                say(ctx, "missing or unterminated text for '" .. rtype .. "' (use quotes for phrases).")
                return
            end
            cond.match = (rtype == "flag") and match:lower() or match
        end
        conditions[#conditions + 1] = cond
        local after = rest:match("^%+%s+(.*)$")
        if not after then
            break
        end
        rest = after
    end
    local reply = rest
    local id, err = E.add_rule(conditions, reply)
    if not id then
        say(ctx, "cannot add rule: " .. err)
        return
    end
    say(ctx, string.format("added rule #%d (%s) -> %s", id, rules.describe(E.find_rule(id)), reply))
    for _, c in ipairs(conditions) do
        if c.type == "pattern" then
            say(ctx, "note: patterns are Lua patterns, not regex.")
            break
        end
    end
end

local function cmd_list(ctx)
    if #E.cfg.rules == 0 then
        say(ctx, "no rules yet. Add one with /autoreply add ...")
        return
    end
    for _, r in ipairs(E.cfg.rules) do
        say(ctx, string.format("#%d [%s] -> %s%s", r.id, rules.describe(r),
            r.reply or "(no reply)", r.enabled == false and "  (disabled)" or ""))
    end
end

local function cmd_rule_op(ctx, words, op)
    local id = tonumber(words[3])
    local rule, idx = nil, nil
    if id then rule, idx = E.find_rule(id) end
    if not rule then
        say(ctx, "no rule with that id; see /autoreply list.")
        return
    end
    if op == "remove" then
        table.remove(E.cfg.rules, idx)
    else
        rule.enabled = (op == "enable")
    end
    E.save()
    say(ctx, string.format("rule #%d %sd.", id, op == "remove" and "remove" or op))
end

local function cmd_ignore(ctx, words)
    local sub, user = words[3], util.norm_user(words[4])
    local list = E.cfg.ignore_users
    if sub == "list" then
        say(ctx, "ignored users: " .. (#list > 0 and table.concat(list, ", ") or "none"))
    elseif sub == "add" and user ~= "" then
        if not util.contains(list, user) then
            list[#list + 1] = user
            E.save()
        end
        say(ctx, "ignoring " .. user .. ".")
    elseif sub == "remove" and user ~= "" then
        local i = util.contains(list, user)
        if i then
            table.remove(list, i)
            E.save()
        end
        say(ctx, "no longer ignoring " .. user .. ".")
    else
        say(ctx, "usage: /autoreply ignore add|remove|list <user>")
    end
end

local function cmd_set(ctx, words)
    local key, val = words[3], words[4]
    local keys = { usercd = "per_user_cooldown", rulecd = "per_rule_cooldown", gap = "global_min_gap" }
    if keys[key or ""] then
        local n = tonumber(val)
        if not n or n < 0 or n > 86400 then
            say(ctx, "value must be a number of seconds between 0 and 86400.")
            return
        end
        if key == "gap" and n < 1 then
            say(ctx, "gap must be at least 1 second (Twitch rate limits).")
            return
        end
        E.cfg[keys[key]] = n
        E.save()
        say(ctx, key .. " = " .. n .. "s")
    elseif key == "live" and (val == "on" or val == "off") then
        E.cfg.only_when_live = (val == "on")
        E.save()
        say(ctx, "only reply while live: " .. val)
    else
        say(ctx, "usage: /autoreply set usercd|rulecd|gap <seconds>  |  set live on|off")
    end
end

function M.handle(ctx)
    E.notice_channel = ctx.channel
    local words = ctx.words
    local sub = words[2] and words[2]:lower() or "help"
    if sub == "on" then
        cmd_on(ctx, words)
    elseif sub == "off" then
        E.deactivate()
        say(ctx, "disabled.")
    elseif sub == "toggle" then
        if E.active then
            E.deactivate()
            say(ctx, "disabled.")
        else
            E.activate(nil, false)
            say(ctx, "enabled until the app closes.")
        end
    elseif sub == "status" then
        status(ctx)
    elseif sub == "channel" or sub == "channels" then
        cmd_channel(ctx, words)
    elseif sub == "add" then
        cmd_add(ctx, words)
    elseif sub == "list" then
        cmd_list(ctx)
    elseif sub == "remove" or sub == "enable" or sub == "disable" then
        cmd_rule_op(ctx, words, sub)
    elseif sub == "ignore" then
        cmd_ignore(ctx, words)
    elseif sub == "set" then
        cmd_set(ctx, words)
    elseif sub == "reload" then
        E.load()
        say(ctx, "config reloaded from disk.")
        status(ctx)
    else
        help(ctx)
    end
end

return M
