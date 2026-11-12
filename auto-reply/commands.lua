-- /autoreply subcommands.
local util = require("util")
local rules = require("rules")
local E = require("engine")
local U = require("ux")
local W = require("wizard")

local M = {}

-- Help is layered: index -> topic -> "all". Each topic's lines keep the
-- convention "explanation line, then syntax line".
local TOPICS = {
    {
        key = "on", aliases = { "off", "toggle", "status" },
        summary = "включить/выключить авто-ответ, показать состояние",
        lines = {
            "Включить авто-ответ. Период: 30m = 30 минут, 2h = 2 часа, 1d = 1 день, 1h30m = 1,5 часа. Без периода работает, пока открыто приложение. forever = всегда (сохраняется после перезапуска).",
            "/autoreply on [30m|2h|1d|forever]",
            "Выключить авто-ответ полностью. toggle = переключить вкл/выкл одним действием. status = показать текущее состояние и настройки.",
            "/autoreply off | toggle | status",
        },
    },
    {
        key = "channel", aliases = { "channels" },
        summary = "каналы, в которых работает авто-ответ",
        lines = {
            "Каналы, в которых работает авто-ответ. add = добавить, remove = убрать, list = показать список. Канал должен быть открыт в окне (сплите).",
            "/autoreply channel add|remove|list <канал>",
        },
    },
    {
        key = "add", aliases = { "rule" },
        summary = "добавить правило (keyword, word, anyword, mention, flag, pattern, условия через +)",
        lines = {
            "Проще всего создать правило пошагово: /autoreply new. Что значит каждый тип условия: /autoreply help types (подробно с примером: help add <тип>).",
            "/autoreply new",
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
            "Важно: ответ работает только когда авто-ответ включён, и правило без текста ответа никогда не срабатывает.",
        },
    },
    {
        key = "types", aliases = {},
        summary = "какие бывают типы условий и чем они отличаются",
        lines = (function()
            local out = {}
            for _, t in ipairs(rules.TYPES) do
                out[#out + 1] = t .. " — " .. rules.TYPE_INFO[t].what
            end
            out[#out + 1] = "Пример и синтаксис конкретного типа: /autoreply help add <тип>. Несколько условий сразу: знак + (все должны совпасть)."
            out[#out + 1] = "/autoreply help add keyword|word|anyword|mention|flag|pattern"
            return out
        end)(),
    },
    {
        key = "new", aliases = { "wizard", "cancel", "back" },
        summary = "пошаговый мастер создания правила",
        lines = {
            "Пошаговый мастер: бот задаёт вопросы, вы отвечаете командой /autoreply <ответ> (номер варианта или текст). back = шаг назад, cancel = отмена. В конце мастер покажет ту же команду одной строкой.",
            "/autoreply new   (затем: /autoreply <ответ> | back | cancel)",
        },
    },
    {
        key = "test", aliases = {},
        summary = "проверить правило без отправки сообщения",
        lines = {
            "Проверка правила без отправки: покажет, сработает ли правило на примере текста, и какой будет ответ. <id> = номер из list или all (все правила). Для условий flag добавьте flags=first,sub перед текстом.",
            "/autoreply test <id|all> [flags=first,sub] <текст сообщения>",
            "Пример: проверить правило №1 на сообщении «привет всем».",
            "/autoreply test 1 привет всем",
        },
    },
    {
        key = "rules", aliases = { "list", "remove", "enable", "disable" },
        summary = "список правил, удаление, включение/выключение",
        lines = {
            "Управление правилами: list = показать все с номерами, remove = удалить, enable/disable = включить/выключить одно правило. <id> это номер из list.",
            "/autoreply list | remove <id> | enable <id> | disable <id>",
        },
    },
    {
        key = "ignore", aliases = {},
        summary = "игнор-список пользователей (например, другие боты)",
        lines = {
            "Игнор-список: сообщения этих пользователей не вызывают ответ (например, другие боты вроде Nightbot). Ваш собственный аккаунт игнорируется всегда.",
            "/autoreply ignore add|remove|list <пользователь>",
        },
    },
    {
        key = "set", aliases = {},
        summary = "паузы между ответами и режим «только на стриме»",
        lines = {
            "Настройки пауз (в секундах). usercd = пауза для одного пользователя: бот не ответит ему чаще, чем раз в N секунд (по умолчанию 60). rulecd = пауза для одного правила в канале (по умолчанию 10). gap = минимальный промежуток между любыми двумя ответами бота (по умолчанию 2, минимум 1).",
            "/autoreply set usercd|rulecd|gap <секунды>",
            "Отвечать только когда стрим идёт (live): on = да, off = в любое время.",
            "/autoreply set live on|off",
        },
    },
    {
        key = "timer", aliases = { "timers" },
        summary = "счётчики времени ({time}: сколько прошло с момента включения)",
        lines = {
            "Счётчик времени: чат-команда, в ответ на которую бот пишет, сколько прошло с момента включения (например, сколько стример играет). В ответе обязательно {time}; можно {user}. Счётчик стартует сразу при добавлении, привязан к текущему каналу. smart = «2 ч 35 мин» (меньше минуты: «только начал»), full = 2:35:07. Если стрим ушёл в офлайн (более 2 минут), счётчик сам выключается.",
            '/autoreply timer add "<!команда>" [smart|full] <ответ с {time}>',
            "Управление счётчиками: list = показать с текущим временем, on = включить (отсчёт с нуля), off = выключить, reset = начать отсчёт заново, set = задать, сколько уже прошло, remove = удалить, format = формат времени.",
            "/autoreply timer list | on <id> [время] | off <id> | reset <id> [время] | set <id> <время> | remove <id> | format <id> smart|full",
            "Если забыли включить вовремя: укажите, сколько уже прошло (15m, 1h30m). Пример: timer set 1 1h30m, и ответ сразу покажет «1 ч 30 мин».",
            "Что делать счётчику при смене категории (игры) на стриме: reset = начать заново (по умолчанию), stop = выключить, off = ничего не делать.",
            "/autoreply timer category <id> reset|stop|off",
        },
    },
    {
        key = "redeem", aliases = { "mute", "protect" },
        summary = "авто-мут и авто-размут по наградам за баллы канала",
        lines = {
            "Авто-модерация по наградам: зритель покупает награду и пишет в поле ввода ник (или @ник), бот сам пишет /timeout или /untimeout. Нужны права модератора или стримера, награда должна требовать ввод текста. Название награды берётся из строки «Redeemed ...» в чате, достаточно части названия (регистр не важен); если в названии есть пробелы, берите его в кавычки. Время мута: 10m, 1h, 1d (до 14d). Правило привязано к текущему каналу.",
            '/autoreply redeem add timeout "<название награды>" <время>',
            "Награда для размута: бот пишет /untimeout на указанный ник.",
            '/autoreply redeem add untimeout "<название награды>"',
            "Управление: list = показать, remove = удалить, enable/disable = включить/выключить. debug on = показывать в чате, что именно видит плагин при покупке награды (для проверки, только до закрытия приложения).",
            "/autoreply redeem list | remove <id> | enable <id> | disable <id> | debug on|off",
            "Защита: этих пользователей мутить нельзя (владелец канала, ваш аккаунт, игнор-список, боты вроде Nightbot, модераторы, которых плагин увидел в чате по значку). Остальных (модераторов без сообщений, VIP) добавьте вручную. Если зритель выбрал защищённого, мут получает он сам (backfire); если и он защищён, ничего не происходит.",
            "/autoreply protect add|remove|list <пользователь>",
            "mutelurkers: off = мутить можно только тех, кто писал в чат за последние 2 часа (защита от опечаток), on = мутить можно любого. backfire: on = защищённый ник возвращает мут автору (по умолчанию), off = просто отказ.",
            "/autoreply set mutelurkers on|off  |  /autoreply set backfire on|off",
        },
    },
    {
        key = "reload", aliases = {},
        summary = "перечитать data/config.json",
        lines = {
            "Перечитать настройки из файла data/config.json (если вы правили его вручную).",
            "/autoreply reload",
        },
    },
}

local TOPIC_BY_NAME = {}
for _, t in ipairs(TOPICS) do
    TOPIC_BY_NAME[t.key] = t
    for _, a in ipairs(t.aliases) do
        TOPIC_BY_NAME[a] = t
    end
end

local function say(ctx, text)
    ctx.channel:add_system_message("[auto-reply] " .. text)
end

local function help_index(ctx)
    local out = ctx.channel
    out:add_system_message("=== Авто-ответ: шпаргалка ===")
    out:add_system_message("Быстрый старт: 1) /autoreply channel add <канал>  2) /autoreply new (мастер создания правила)  3) /autoreply on")
    out:add_system_message('Правило одной строкой: /autoreply add word "привет" Привет, {user}!')
    out:add_system_message("Проверка без отправки: /autoreply test <id> <сообщение>")
    out:add_system_message("Правила: /autoreply list | remove <id> | enable <id> | disable <id>")
    out:add_system_message("Состояние: /autoreply on [30m|2h|forever] | off | status")
    out:add_system_message("Подсказка по вводу: нажмите Tab после /autoreply, подставятся команды и варианты.")
    local keys = {}
    for _, t in ipairs(TOPICS) do
        keys[#keys + 1] = t.key
    end
    out:add_system_message("Разделы: /autoreply help <" .. table.concat(keys, "|") .. ">  |  всё сразу: /autoreply help all")
end

local function help(ctx, arg, arg2)
    local out = ctx.channel
    arg = arg and arg:lower() or nil
    arg2 = arg2 and arg2:lower() or nil
    if arg == nil then
        help_index(ctx)
    elseif arg == "all" or arg == "full" then
        out:add_system_message("=== Авто-ответ: полная справка ===")
        for _, t in ipairs(TOPICS) do
            out:add_system_message("-- " .. t.key .. " --")
            for _, line in ipairs(t.lines) do
                out:add_system_message(line)
            end
        end
    elseif (arg == "add" or arg == "rule") and arg2 and rules.TYPE_INFO[arg2] then
        local info = rules.TYPE_INFO[arg2]
        out:add_system_message("=== Справка: add " .. arg2 .. " ===")
        out:add_system_message(arg2 .. " — " .. info.what)
        out:add_system_message(info.syntax)
        out:add_system_message("Пример: " .. info.example)
    elseif TOPIC_BY_NAME[arg] then
        local t = TOPIC_BY_NAME[arg]
        out:add_system_message("=== Справка: " .. t.key .. " ===")
        for _, line in ipairs(t.lines) do
            out:add_system_message(line)
        end
    else
        out:add_system_message("Нет такого раздела: " .. arg)
        help_index(ctx)
    end
end

local function status(ctx)
    local cfg = E.cfg
    local state
    if not E.active then
        state = "ВЫКЛ"
    elseif E.expires then
        state = "ВКЛ, осталось " .. util.format_duration(E.expires - util.now_s())
    elseif E.session_only then
        state = "ВКЛ до закрытия приложения"
    else
        state = "ВКЛ (навсегда)"
    end
    say(ctx, "состояние: " .. state)
    local chans = {}
    for _, c in ipairs(cfg.channels) do
        chans[#chans + 1] = c .. (E.hooked(c) and "" or " (не открыт)")
    end
    say(ctx, "каналы: " .. (#chans > 0 and table.concat(chans, ", ") or "нет"))
    local usable = 0
    for _, r in ipairs(cfg.rules) do
        if rules.is_usable(r) then usable = usable + 1 end
    end
    local running = 0
    for _, t in ipairs(cfg.timers) do
        if t.enabled and t.started_at then running = running + 1 end
    end
    say(ctx, string.format("счётчики: %d (работает %d) | награды: %d | защищённых: %d | backfire: %s | mutelurkers: %s",
        #cfg.timers, running, #cfg.redeems, #cfg.protect_users, cfg.backfire and "on" or "off",
        cfg.mute_lurkers and "on" or "off"))
    say(ctx, string.format("правила: %d (активных %d) | паузы: пользователь %dс, правило %dс, общая %dс | только на стриме: %s",
        #cfg.rules, usable, cfg.per_user_cooldown, cfg.per_rule_cooldown,
        cfg.global_min_gap, cfg.only_when_live and "да" or "нет"))
    if E.active and #cfg.channels == 0 then
        say(ctx, "внимание: каналов нет; добавьте: /autoreply channel add <канал>")
    end
    if E.active and usable == 0 then
        say(ctx, "внимание: нет рабочих правил (нужны условие и ответ); создайте: /autoreply new")
    end
end

local function cmd_on(ctx, words)
    local arg = words[3]
    if arg == nil then
        E.activate(nil, false)
        say(ctx, "включено до закрытия приложения.")
    elseif arg:lower() == "forever" then
        E.activate(nil, true)
        say(ctx, "включено навсегда (сохраняется после перезапуска).")
    else
        local secs = util.parse_duration(arg)
        if not secs then
            say(ctx, "неверный период «" .. arg .. "». Примеры: 30m, 2h, 1d, 1h30m или forever. Подробнее: /autoreply help on")
            return
        end
        E.activate(secs, false)
        say(ctx, "включено на " .. util.format_duration(secs) .. ".")
    end
    status(ctx)
end

local function cmd_channel(ctx, words)
    local sub, name = words[3], util.norm_channel(words[4])
    local list = E.cfg.channels
    if sub == "list" then
        say(ctx, "каналы: " .. (#list > 0 and table.concat(list, ", ") or "нет"))
    elseif sub == "add" and name ~= "" then
        if util.contains(list, name) then
            say(ctx, name .. " уже в списке.")
            return
        end
        list[#list + 1] = name
        E.save()
        E.sync_hooks()
        say(ctx, "добавлен " .. name .. (E.hooked(name) and "." or " (канал ещё не открыт в окне; подключится автоматически, когда вы его откроете)."))
        if #E.cfg.rules == 0 then
            say(ctx, "дальше создайте правило: /autoreply new (пошагово) или /autoreply help add")
        end
    elseif sub == "remove" and name ~= "" then
        local i = util.contains(list, name)
        if not i then
            say(ctx, name .. " нет в списке.")
            return
        end
        table.remove(list, i)
        E.save()
        E.sync_hooks()
        say(ctx, "убран " .. name .. ".")
    else
        say(ctx, "использование: /autoreply channel add|remove|list <канал>   (подробнее: /autoreply help channel)")
    end
end

-- Parses: <quoted or single token> <rest>. Returns token, rest, quoted.
local function take_arg(s)
    s = s:gsub("^%s+", "")
    local q = s:sub(1, 1)
    if q == '"' then
        local tok, rest = s:match('^"(.-)"%s*(.*)$')
        if tok then
            return tok, rest, true
        end
        return nil, s
    end
    local tok, rest = s:match("^(%S+)%s*(.*)$")
    return tok, rest, false
end

local NO_ARG = { mention = true }

local function add_usage(ctx)
    say(ctx, 'использование: /autoreply add <условие> [+ <условие> ...] <ответ>')
    say(ctx, 'условия: keyword|word|anyword|pattern "текст", flag <имя>, mention')
    say(ctx, 'пример: /autoreply add word "привет" Привет, {user}!')
    say(ctx, "подробнее: /autoreply help add (типы: /autoreply help types), или пошагово: /autoreply new")
end

local function cmd_add(ctx, words)
    if not words[3] then
        add_usage(ctx)
        return
    end
    local rest = table.concat(words, " ", 3)
    local conditions = {}
    local unquoted
    while true do
        local rtype
        rtype, rest = take_arg(rest)
        if not rtype then
            say(ctx, "не указан тип условия. Типы: " .. table.concat(rules.TYPES, ", ") .. " (что это: /autoreply help types)")
            return
        end
        rtype = rtype:lower()
        local cond = { type = rtype }
        if not NO_ARG[rtype] then
            local match, quoted
            match, rest, quoted = take_arg(rest)
            if not match then
                say(ctx, "для «" .. rtype .. "» не указан текст или не закрыта кавычка (фразу с пробелами берите в кавычки).")
                say(ctx, 'пример: /autoreply add word "добрый вечер" Привет, {user}!')
                return
            end
            cond.match = (rtype == "flag") and match:lower() or match
            if not quoted and not unquoted and rtype ~= "flag" then
                unquoted = cond
            end
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
        say(ctx, "не удалось добавить правило: " .. err)
        say(ctx, "подробнее: /autoreply help add | пошагово: /autoreply new")
        return
    end
    say(ctx, string.format("добавлено правило #%d (%s) → %s", id, rules.describe(E.find_rule(id)), reply))
    U.soft_warnings(ctx, conditions, reply, unquoted)
    U.after_add(ctx, id, conditions)
end

local function cmd_list(ctx)
    if #E.cfg.rules == 0 then
        say(ctx, "правил пока нет. Создайте: /autoreply new (пошагово) или /autoreply add ...")
        return
    end
    for _, r in ipairs(E.cfg.rules) do
        local mark = ""
        if r.enabled == false then
            mark = "  (выключено)"
        elseif not rules.is_usable(r) then
            mark = "  (нет ответа)"
        end
        say(ctx, string.format("#%d [%s] → %s%s", r.id, rules.describe(r), r.reply or "(нет ответа)", mark))
    end
    say(ctx, "проверка без отправки: /autoreply test <id> <сообщение>")
end

local RULE_OP_DONE = { remove = "удалено", enable = "включено", disable = "выключено" }

local function cmd_rule_op(ctx, words, op)
    local id = tonumber(words[3])
    if not id then
        say(ctx, "использование: /autoreply " .. op .. " <номер правила>  (номера: /autoreply list)")
        return
    end
    local rule, idx = E.find_rule(id)
    if not rule then
        say(ctx, "нет правила с номером " .. id .. "; список: /autoreply list.")
        return
    end
    if op == "remove" then
        table.remove(E.cfg.rules, idx)
    else
        rule.enabled = (op == "enable")
    end
    E.save()
    say(ctx, string.format("правило #%d %s.", id, RULE_OP_DONE[op]))
end

local function cmd_ignore(ctx, words)
    local sub, user = words[3], util.norm_user(words[4])
    local list = E.cfg.ignore_users
    if sub == "list" then
        say(ctx, "игнорируются: " .. (#list > 0 and table.concat(list, ", ") or "никто"))
    elseif sub == "add" and user ~= "" then
        if not util.contains(list, user) then
            list[#list + 1] = user
            E.save()
        end
        say(ctx, "игнорируется " .. user .. ".")
    elseif sub == "remove" and user ~= "" then
        local i = util.contains(list, user)
        if i then
            table.remove(list, i)
            E.save()
            say(ctx, user .. " больше не игнорируется.")
        else
            say(ctx, user .. " не был в списке игнорируемых.")
        end
    else
        say(ctx, "использование: /autoreply ignore add|remove|list <пользователь>   (подробнее: /autoreply help ignore)")
    end
end

local function cmd_protect(ctx, words)
    local sub, user = words[3], util.norm_user(words[4])
    local list = E.cfg.protect_users
    if sub == "list" then
        say(ctx, "защищены от мута: " .. (#list > 0 and table.concat(list, ", ") or "никто"))
    elseif sub == "add" and user ~= "" then
        if not util.contains(list, user) then
            list[#list + 1] = user
            E.save()
        end
        say(ctx, user .. " защищён от мута по наградам.")
    elseif sub == "remove" and user ~= "" then
        local i = util.contains(list, user)
        if i then
            table.remove(list, i)
            E.save()
            say(ctx, user .. " больше не защищён.")
        else
            say(ctx, user .. " не был в списке защищённых.")
        end
    else
        say(ctx, "использование: /autoreply protect add|remove|list <пользователь>   (подробнее: /autoreply help redeem)")
    end
end

local function describe_redeem(r)
    return string.format("#%d [%s] \"%s\" -> %s%s%s", r.id, r.channel, r.title, r.action,
        r.seconds and (" " .. util.format_duration(r.seconds)) or "", r.enabled == false and "  (выключено)" or "")
end

local REDEEM_OP_DONE = { remove = "удалено", enable = "включено", disable = "выключено" }

local function cmd_redeem(ctx, words)
    local sub = words[3] and words[3]:lower() or ""
    local list = E.cfg.redeems
    if sub == "add" then
        local ok, ismod = pcall(function() return ctx.channel:is_mod() or ctx.channel:is_broadcaster() end)
        if not ok or not ismod then
            say(ctx, "добавлять награды может только модератор или стример этого канала (и канал должен быть на Twitch).")
            return
        end
        local action = words[4] and words[4]:lower() or ""
        local rest = table.concat(words, " ", 5)
        local title
        title, rest = take_arg(rest)
        local secs
        if action == "timeout" then
            secs = util.parse_duration(rest and rest:match("^(%S+)"))
        end
        if (action ~= "timeout" and action ~= "untimeout") or not title or (action == "timeout" and not secs) then
            say(ctx, 'использование: /autoreply redeem add timeout "<название награды>" <время, например 10m>  |  redeem add untimeout "<название награды>"')
            say(ctx, "подробнее: /autoreply help redeem")
            return
        end
        local chan = util.norm_channel(ctx.channel:get_name())
        local id, err = E.add_redeem(chan, action, title, secs)
        if not id then
            say(ctx, "не удалось добавить награду: " .. err)
            return
        end
        say(ctx, "добавлена награда " .. describe_redeem(E.find_redeem(id)))
        if not util.contains(E.cfg.channels, chan) then
            say(ctx, "внимание: " .. chan .. " нет в списке каналов; добавьте: /autoreply channel add " .. chan)
        end
        say(ctx, "совет: добавьте своих модераторов и VIP: /autoreply protect add <ник>; проверить, что видит плагин: /autoreply redeem debug on.")
    elseif sub == "list" then
        if #list == 0 then
            say(ctx, 'правил по наградам пока нет. Пример: /autoreply redeem add timeout "<название>" 10m')
            return
        end
        for _, r in ipairs(list) do
            say(ctx, describe_redeem(r))
        end
    elseif sub == "debug" and (words[4] == "on" or words[4] == "off") then
        E.debug_redeem = (words[4] == "on")
        say(ctx, "отладка наград: " .. words[4] .. (E.debug_redeem and " (купите награду, и увидите, что получает плагин; сбрасывается при закрытии приложения)." or "."))
    elseif sub == "remove" or sub == "enable" or sub == "disable" then
        local id = tonumber(words[4])
        local r, idx
        if id then r, idx = E.find_redeem(id) end
        if not r then
            say(ctx, "нет награды с таким номером; список: /autoreply redeem list.")
            return
        end
        if sub == "remove" then
            table.remove(list, idx)
        else
            r.enabled = (sub == "enable")
        end
        E.save()
        say(ctx, string.format("награда #%d %s.", id, REDEEM_OP_DONE[sub]))
    else
        say(ctx, "использование: /autoreply redeem add|list|remove|enable|disable|debug ...   (подробнее: /autoreply help redeem)")
    end
end

local function cmd_set(ctx, words)
    local key, val = words[3], words[4]
    local keys = { usercd = "per_user_cooldown", rulecd = "per_rule_cooldown", gap = "global_min_gap" }
    if keys[key or ""] then
        local n = tonumber(val)
        if not n or n < 0 or n > 86400 then
            say(ctx, "значение: число секунд от 0 до 86400. Пример: /autoreply set " .. key .. " 60")
            return
        end
        if key == "gap" and n < 1 then
            say(ctx, "gap должен быть не меньше 1 секунды (ограничения Twitch).")
            return
        end
        E.cfg[keys[key]] = n
        E.save()
        say(ctx, key .. " = " .. n .. "с")
    elseif (key == "mutelurkers" or key == "backfire") and (val == "on" or val == "off") then
        E.cfg[key == "mutelurkers" and "mute_lurkers" or "backfire"] = (val == "on")
        E.save()
        say(ctx, key .. ": " .. val)
    elseif key == "live" and (val == "on" or val == "off") then
        E.cfg.only_when_live = (val == "on")
        E.save()
        say(ctx, "отвечать только когда идёт стрим: " .. val)
    else
        say(ctx, "использование: /autoreply set usercd|rulecd|gap <секунды>  |  set live|mutelurkers|backfire on|off   (подробнее: /autoreply help set)")
    end
end

local function cmd_timer(ctx, words)
    local sub = words[3] and words[3]:lower() or ""
    local timers = E.cfg.timers
    if sub == "add" then
        local rest = table.concat(words, " ", 4)
        local trigger
        trigger, rest = take_arg(rest)
        if not trigger then
            say(ctx, 'использование: /autoreply timer add "<!команда>" [smart|full] <ответ с {time}>   (подробнее: /autoreply help timer)')
            return
        end
        local fmt = "smart"
        local maybe, after = take_arg(rest)
        if maybe == "smart" or maybe == "full" then
            fmt, rest = maybe, after
        end
        local chan = util.norm_channel(ctx.channel:get_name())
        local id, err = E.add_timer(trigger, chan, rest, fmt)
        if not id then
            say(ctx, "не удалось добавить счётчик: " .. err)
            say(ctx, 'пример: /autoreply timer add "!uptime" Играем уже {time}')
            return
        end
        say(ctx, string.format("добавлен счётчик #%d (%s) в %s, отсчёт с текущего момента → %s", id, trigger, chan, rest))
        if not util.contains(E.cfg.channels, chan) then
            say(ctx, "внимание: " .. chan .. " нет в списке каналов; добавьте: /autoreply channel add " .. chan)
        end
        return
    elseif sub == "list" then
        if #timers == 0 then
            say(ctx, 'счётчиков пока нет. Пример: /autoreply timer add "!uptime" Играем уже {time}')
            return
        end
        for _, t in ipairs(timers) do
            local state = "остановлен"
            if t.enabled and t.started_at then
                state = util.format_elapsed(E.timer_elapsed(t), t.format)
            end
            say(ctx, string.format("#%d [%s @%s, %s, при смене категории: %s] %s → %s", t.id, t.trigger, t.channel,
                t.format, t.on_category, state, t.reply))
        end
        return
    end
    local id = tonumber(words[4])
    local t, idx
    if id then t, idx = E.find_timer(id) end
    if not t then
        say(ctx, "использование: /autoreply timer add|list|on|off|reset|set|remove|format|category ...  (номер из timer list; подробнее: /autoreply help timer)")
        return
    end
    -- optional start offset for on/reset/set, e.g. 1h30m = "already running for 1h30m"
    local offset
    if sub == "on" or sub == "reset" or sub == "set" then
        if words[5] then
            offset = util.parse_duration(words[5])
            if not offset then
                say(ctx, "неверное время «" .. words[5] .. "». Примеры: 15m, 1h30m.")
                return
            end
        elseif sub == "set" then
            say(ctx, "использование: /autoreply timer set <номер> <время>, например: timer set 1 1h30m")
            return
        end
    end
    local from = offset and util.format_elapsed(offset, "smart") or "0"
    if sub == "on" then
        E.set_timer_enabled(t, true, offset)
        say(ctx, string.format("счётчик #%d запущен с %s.", id, from))
    elseif sub == "off" then
        E.set_timer_enabled(t, false)
        say(ctx, string.format("счётчик #%d остановлен.", id))
    elseif sub == "reset" or sub == "set" then
        E.reset_timer(t, offset)
        say(ctx, string.format("счётчик #%d перезапущен с %s.", id, from))
    elseif sub == "remove" then
        table.remove(timers, idx)
        E.save()
        say(ctx, string.format("счётчик #%d удалён.", id))
    elseif sub == "format" and (words[5] == "smart" or words[5] == "full") then
        t.format = words[5]
        E.save()
        say(ctx, string.format("формат счётчика #%d: %s.", id, t.format))
    elseif sub == "category" and (words[5] == "reset" or words[5] == "stop" or words[5] == "off") then
        t.on_category = words[5]
        E.save()
        say(ctx, string.format("при смене категории счётчик #%d: %s.", id, t.on_category))
    else
        say(ctx, "использование: /autoreply timer format <номер> smart|full  |  category <номер> reset|stop|off")
    end
end

-- /autoreply test <id|all> [flags=a,b] <text>: shows what would happen, sends nothing.
local function cmd_test(ctx, words)
    local target = words[3]
    local idx = 4
    local flagnames = {}
    if words[4] and words[4]:lower():match("^flags=") then
        for n in words[4]:sub(7):gmatch("[^,]+") do
            flagnames[#flagnames + 1] = n:lower()
        end
        idx = 5
    end
    local text = table.concat(words, " ", idx)
    if not target or text == "" then
        say(ctx, "использование: /autoreply test <номер правила|all> [flags=first,sub] <текст сообщения>")
        say(ctx, "пример: /autoreply test 1 привет всем   (номера: /autoreply list; подробнее: /autoreply help test)")
        return
    end
    local mask, unknown = rules.flags_from_names(flagnames)
    if #unknown > 0 then
        say(ctx, "неизвестные флаги: " .. table.concat(unknown, ", ") .. ". Допустимы: " .. table.concat(rules.FLAG_ORDER, ", "))
        return
    end
    local list
    if target:lower() == "all" then
        list = E.cfg.rules
        if #list == 0 then
            say(ctx, "правил пока нет. Создайте: /autoreply new")
            return
        end
    else
        local id = tonumber(target)
        local r = id and E.find_rule(id)
        if not r then
            say(ctx, "нет правила с номером «" .. target .. "»; список: /autoreply list. Или используйте all.")
            return
        end
        list = { r }
    end
    local me = U.my_login()
    local fake = { display_name = "Зритель", login_name = "viewer" }
    say(ctx, "проверка (ничего не отправляется): «" .. text .. "»" .. (#flagnames > 0 and (" с флагами " .. table.concat(flagnames, ",")) or ""))
    for _, t in ipairs(E.cfg.timers) do
        if t.enabled and t.started_at and rules.matches_one({ type = "word", match = t.trigger }, text, mask, me) then
            say(ctx, string.format("совпал счётчик #%d (%s): он срабатывает раньше правил.", t.id, t.trigger))
        end
    end
    local winner
    for _, r in ipairs(list) do
        local failed = {}
        for _, c in ipairs(rules.conditions(r)) do
            if not rules.matches_one(c, text, mask, me) then
                failed[#failed + 1] = rules.describe({ type = c.type, match = c.match })
            end
        end
        if #failed == 0 then
            if not rules.is_usable(r) then
                say(ctx, string.format("#%d: условия совпали, но правило выключено или без ответа — не сработает.", r.id))
            elseif winner then
                say(ctx, string.format("#%d: совпало, но выше уже сработает правило #%d (побеждает первое совпавшее).", r.id, winner))
            else
                winner = r.id
                say(ctx, string.format("#%d: СОВПАЛО → ответ: %s", r.id, E.render(r.reply, fake)))
            end
        else
            say(ctx, string.format("#%d: не совпало (не выполнено: %s)", r.id, table.concat(failed, "; ")))
        end
    end
    if winner then
        if not E.active then
            say(ctx, "но авто-ответ выключен: /autoreply on")
        elseif #E.cfg.channels == 0 then
            say(ctx, "но каналов нет: /autoreply channel add <канал>")
        end
    end
end

-- Single bare words that still work while the wizard is running.
local WIZARD_PASS = { help = true, status = true, list = true }

function M.handle(ctx)
    E.notice_channel = ctx.channel
    local words = ctx.words
    local sub = words[2] and words[2]:lower() or "help"
    if sub == "new" or sub == "wizard" then
        W.start(ctx)
        return
    end
    if W.active() and not (#words == 2 and WIZARD_PASS[sub]) then
        W.answer(ctx, words)
        return
    end
    if sub == "cancel" or sub == "back" then
        say(ctx, "мастер сейчас не запущен; начать: /autoreply new")
    elseif sub == "on" then
        cmd_on(ctx, words)
    elseif sub == "off" then
        E.deactivate()
        say(ctx, "выключено.")
    elseif sub == "toggle" then
        if E.active then
            E.deactivate()
            say(ctx, "выключено.")
        else
            E.activate(nil, false)
            say(ctx, "включено до закрытия приложения.")
        end
    elseif sub == "status" then
        status(ctx)
    elseif sub == "channel" or sub == "channels" then
        cmd_channel(ctx, words)
    elseif sub == "add" then
        cmd_add(ctx, words)
    elseif sub == "list" then
        cmd_list(ctx)
    elseif sub == "test" then
        cmd_test(ctx, words)
    elseif sub == "remove" or sub == "enable" or sub == "disable" then
        cmd_rule_op(ctx, words, sub)
    elseif sub == "timer" or sub == "timers" then
        cmd_timer(ctx, words)
    elseif sub == "ignore" then
        cmd_ignore(ctx, words)
    elseif sub == "redeem" or sub == "mute" then
        cmd_redeem(ctx, words)
    elseif sub == "protect" then
        cmd_protect(ctx, words)
    elseif sub == "set" then
        cmd_set(ctx, words)
    elseif sub == "reload" then
        E.load()
        say(ctx, "настройки перечитаны из файла.")
        status(ctx)
    elseif sub == "help" then
        help(ctx, words[3], words[4])
    else
        say(ctx, "неизвестная команда «" .. words[2] .. "».")
        help_index(ctx)
    end
end

M.TOPICS = TOPICS

return M
