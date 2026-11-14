-- /autoreply subcommands.
local util = require("util")
local config = require("config")
local rules = require("rules")
local E = require("engine")
local U = require("ux")
local W = require("wizard")
local N = require("names")

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
            "Если убрать канал, правила, привязанные только к нему, перестают работать (глобальными они не становятся); вернёте канал, и они заработают снова.",
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
            "Канал правила: по умолчанию правило действует во всех добавленных каналах. Чтобы привязать к каналу(ам), добавьте channel= сразу после add (можно вместе с name=): channel=streamer, channel=a,b, channel=here (канал этого окна), channel=all (все).",
            "/autoreply add channel=<канал[,канал]|here|all> <условие> <ответ>",
            "Сменить канал позже: /autoreply rule <номер или имя> channel <канал[,канал]|here|all>. Правила по каналам: /autoreply list [канал].",
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
            "/autoreply test <id|all> [flags=first,sub] [as=mod|ник] <текст сообщения>",
            "Пример: проверить правило №1 на сообщении «привет всем».",
            "/autoreply test 1 привет всем",
            "as=mod проверяет, как правило отреагирует, если напишет модератор; as=<ник> — конкретный пользователь (работает вместе с настройкой skip, см. help skip).",
            "/autoreply test 1 as=mod привет всем",
        },
    },
    {
        key = "skip", aliases = { "skipmods", "mods" },
        summary = "не отвечать модераторам или выбранным пользователям",
        lines = {
            "Ограничение «кто запускает ответ»: у правила или счётчика можно указать, что сообщения модераторов и/или выбранных пользователей его не запускают. Такое сообщение считается «не совпало»: проверка идёт дальше, и другое правило ниже всё равно может ответить. Паузы при этом не тратятся.",
            "При создании: skip=mods | skip=nomods | skip=ник,ник | skip=mods,ник (после add / timer add, вместе с name=, channel=).",
            '/autoreply add skip=mods word "!донат" @{user} ссылка...  |  /autoreply timer add skip=mods,vasya "!game" Играем {time}',
            "Потом: mods = модераторы не запускают это правило, nomods = модераторы запускают, даже если включён общий запрет, add/remove = список пользователей, none = сбросить всё (модераторы по общей настройке). Без аргумента — показать текущие.",
            "/autoreply rule <номер|имя> skip [mods|nomods|add <ник>|remove <ник>|none]  |  /autoreply timer skip <номер|имя> [mods|nomods|add <ник>|remove <ник>|none]",
            "Общая настройка для всех правил и счётчиков (по умолчанию выключена; отдельное правило её переопределяет).",
            "/autoreply set skipmods on|off",
            "Важно: модератор определяется по значку в чате. Если приложение значок не показало, сообщение считается обычным и ответ сработает. Стример модератором не считается: добавьте его ник через skip add.",
            "/autoreply rule 1 skip add streamer_login  |  /autoreply test 1 as=mod !донат",
        },
    },
    {
        key = "names", aliases = { "rename", "name" },
        summary = "имена вместо номеров для правил, счётчиков и наград",
        lines = {
            "Имена: у правила, счётчика или награды может быть имя вместо номера. Формат: 1-20 символов, буквы (в том числе русские), цифры, _ и -, минимум одна буква. Нельзя занимать названия команд (on, list, add ...). Регистр не важен, имя уникально среди правил / счётчиков / наград.",
            "Задать имя при создании: name=<имя> сразу после add.",
            '/autoreply add name=greet word привет Привет!  |  /autoreply timer add name=game "!game" Играем {time}  |  /autoreply redeem add name=mute1 timeout "Мут" 10m',
            "Переименовать или убрать имя (дефис = убрать имя).",
            "/autoreply rename rule|timer|redeem <номер|имя> <новое имя|->",
            "Имя работает везде, где принимается номер, и его можно ставить вперёд.",
            "/autoreply disable greet  |  /autoreply test greet привет  |  /autoreply rule greet disable  |  /autoreply timer game on  |  /autoreply redeem mute1 off",
        },
    },
    {
        key = "rules", aliases = { "list", "remove", "enable", "disable" },
        summary = "список правил, удаление, включение/выключение",
        lines = {
            "Управление правилами: list = показать все с номерами, remove = удалить, enable/disable = включить/выключить одно правило. <id> это номер из list.",
            "/autoreply list | remove <id> | enable <id> | disable <id>",
            "Вместо номера можно использовать имя (см. /autoreply help names): /autoreply disable greet, /autoreply rule greet disable.",
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
            "skipmods on = модераторы канала по умолчанию не запускают ответы правил и счётчиков (для отдельного правила можно переопределить: help skip). Выключено по умолчанию.",
            "/autoreply set skipmods on|off",
        },
    },
    {
        key = "timer", aliases = { "timers" },
        summary = "счётчики времени ({time}: сколько прошло с момента включения)",
        lines = {
            "Счётчик времени: чат-команда, в ответ на которую бот пишет, сколько прошло с момента включения (например, сколько стример играет). В ответе обязательно {time}; можно {user}. Счётчик стартует сразу при добавлении, привязан к текущему каналу. smart = «2 ч 35 мин» (меньше минуты: «только начал»), full = 2:35:07. Если стрим ушёл в офлайн (более 2 минут), счётчик сам выключается.",
            '/autoreply timer add "<!команда>" [smart|full] <ответ с {time}>',
            "Вместо одного слова можно задать условия как у правил (типы: /autoreply help types), несколько через +; после условий обязателен разделитель => перед ответом. Счётчик сработает, только если совпали все условия.",
            '/autoreply timer add anyword "давно|сколько" + anyword "играет|играем" => smart @{user} играет уже {time}',
            "Условия счётчика потом не меняются: удалите (timer remove) и добавьте заново.",
            "Управление счётчиками: list = показать с текущим временем, on = включить (отсчёт с нуля), off = выключить, reset = начать отсчёт заново, set = задать, сколько уже прошло, remove = удалить, format = формат времени.",
            "/autoreply timer list | on <id> [время] | off <id> | reset <id> [время] | set <id> <время> | remove <id> | format <id> smart|full",
            "Если забыли включить вовремя: укажите, сколько уже прошло (15m, 1h30m). Пример: timer set 1 1h30m, и ответ сразу покажет «1 ч 30 мин».",
            "Что делать счётчику при смене категории (игры) на стриме: reset = начать заново (по умолчанию), stop = выключить, off = ничего не делать.",
            "/autoreply timer category <id> reset|stop|off",
            "Счётчику можно дать имя и управлять им по имени вместо номера (см. help names).",
            '/autoreply timer add name=game "!game" Играем уже {time}   затем: /autoreply timer game on | off | reset',
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
            "Награде можно дать имя и управлять ею по имени вместо номера (см. help names).",
            '/autoreply redeem add name=mute1 timeout "<название награды>" 10m   затем: /autoreply redeem mute1 disable',
        },
    },
    {
        key = "folder", aliases = { "config", "webui" },
        summary = "папка плагина по ссылке (для веб-интерфейса)",
        lines = {
            "Для редактирования через веб-интерфейс можно подключить свою папку: вся папка плагина становится ссылкой на выбранную вами (старая сохраняется как .bak). Плагин при этом работает как обычно, настройки лежат в data/config.json внутри этой папки.",
            "Сайт может сам установить плагин в пустую папку и обновить его (перед обновлением старый код копируется в .backup). Ссылку создаёт скрипт scripts/link-config.sh (macOS/Linux) или link-config.ps1 (Windows) либо команда ln -s / mklink /J, которую показывает сайт. Закройте приложение перед созданием ссылки. Отключить: scripts/unlink-config.",
            "После правки config.json снаружи выполните /autoreply reload. Новый код плагина подхватывается после перезапуска приложения. /autoreply status показывает, подключена ли внешняя папка (по метке data/.external). Если запись невозможна, плагин сообщит об ошибке.",
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
    out:add_system_message("Имена вместо номеров: /autoreply rename rule <номер> <имя>, затем /autoreply disable <имя> (help names).")
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

-- Channel scope of a rule: "все каналы" or "#a, #b".
local function scope_text(r)
    if type(r.channels) ~= "table" or #r.channels == 0 then
        return "все каналы"
    end
    local out = {}
    for _, c in ipairs(r.channels) do
        out[#out + 1] = "#" .. c
    end
    return table.concat(out, ", ")
end

-- A bound rule none of whose channels is watched never fires (and is NOT global).
local function is_dormant(r)
    if type(r.channels) ~= "table" or #r.channels == 0 then
        return false
    end
    for _, c in ipairs(r.channels) do
        if util.contains(E.cfg.channels, c) then
            return false
        end
    end
    return true
end

local function warn_unwatched(ctx, chans)
    for _, c in ipairs(chans) do
        if not util.contains(E.cfg.channels, c) then
            say(ctx, "внимание: " .. c .. " нет в списке каналов; добавьте: /autoreply channel add " .. c)
        end
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
    say(ctx, "файл настроек: data/config.json ("
        .. (config.is_external() and "внешняя папка по ссылке, определено по метке .external" or "стандартная папка плагина")
        .. ")")
    say(ctx, "модераторы запускают ответы: " .. (cfg.skip_mods and "нет (set skipmods off, чтобы разрешить)" or "да (set skipmods on, чтобы запретить)"))
    local dormant = 0
    for _, r in ipairs(cfg.rules) do
        if is_dormant(r) then dormant = dormant + 1 end
    end
    if dormant > 0 then
        say(ctx, string.format("внимание: правил, привязанных к неотслеживаемым каналам: %d (смотрите /autoreply list)", dormant))
    end
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
        for _, r in ipairs(E.cfg.rules) do
            if is_dormant(r) and util.contains(r.channels, name) then
                say(ctx, string.format("правило %s привязано к %s и не будет срабатывать, пока канал не добавлен снова (глобальным оно не станет).",
                    N.label(r), scope_text(r)))
            end
        end
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

-- Short description of a rule/timer sender restriction ("" when there is none).
local function skip_text(item)
    local parts = {}
    if E.skips_mods(item) then
        parts[#parts + 1] = "модераторы"
    end
    for _, u in ipairs(item.skip_users or {}) do
        parts[#parts + 1] = u
    end
    if #parts == 0 then
        return ""
    end
    return "не отвечает: " .. table.concat(parts, ", ")
end

-- Full status line for `rule <ref> skip` / `timer skip <ref>`.
local function skip_status(item)
    local mods
    if item.skip_mods == true then
        mods = "модераторы пропускаются (задано для этого элемента)"
    elseif item.skip_mods == false then
        mods = "модераторы отвечают (задано для этого элемента)"
    elseif E.cfg.skip_mods then
        mods = "модераторы пропускаются (общая настройка set skipmods on)"
    else
        mods = "модераторы отвечают (общая настройка set skipmods off)"
    end
    local users = (item.skip_users and #item.skip_users > 0) and table.concat(item.skip_users, ", ") or "нет"
    return string.format("%s: %s; пропускаются пользователи: %s", N.label(item), mods, users)
end

-- skip <mods|nomods|none|add <user>|remove <user>> for a rule or timer; args = words after "skip".
-- cmdline: how to call it again, for the hint.
local function handle_skip(ctx, item, args, cmdline)
    local verb = args[1] and args[1]:lower()
    if not verb then
        say(ctx, skip_status(item))
        say(ctx, "изменить: " .. cmdline .. " mods | nomods | add <ник> | remove <ник> | none")
        return
    end
    if verb == "mods" or verb == "nomods" then
        E.set_skip_mods(item, verb == "mods")
    elseif verb == "none" then
        E.set_skip(item, nil)
    elseif verb == "add" or verb == "remove" then
        local user = util.norm_user(args[2])
        if user == "" or not user:match("^[%w_]+$") or #user > 25 then
            say(ctx, "укажите ник (латинские буквы, цифры и _): " .. cmdline .. " " .. verb .. " <ник>")
            return
        end
        if verb == "add" then
            if not E.add_skip_user(item, user) then
                say(ctx, user .. " уже в списке.")
                return
            end
        elseif not E.remove_skip_user(item, user) then
            say(ctx, user .. " не было в списке.")
            return
        end
    else
        say(ctx, "неизвестное действие «" .. args[1] .. "»: доступны mods, nomods, add, remove, none.")
        return
    end
    say(ctx, skip_status(item))
end

local function add_usage(ctx)
    say(ctx, 'использование: /autoreply add [name=<имя>] [channel=<канал[,канал]|here|all>] [skip=<mods|nomods|ник,ник>] <условие> [+ <условие> ...] <ответ>')
    say(ctx, 'условия: keyword|word|anyword|pattern "текст", flag <имя>, mention')
    say(ctx, 'пример: /autoreply add word "привет" Привет, {user}!')
    say(ctx, "подробнее: /autoreply help add (типы: /autoreply help types), или пошагово: /autoreply new")
end

-- Parses `<type> [match] [+ <type> [match] ...]` from the start of `rest`.
-- Returns conditions, rest, unquoted (first unquoted multi-word-prone cond) or nil
-- after saying the error itself.
local function parse_conditions(ctx, rest)
    local conditions = {}
    local unquoted
    while true do
        local rtype
        rtype, rest = take_arg(rest)
        if not rtype then
            say(ctx, "не указан тип условия. Типы: " .. table.concat(rules.TYPES, ", ") .. " (что это: /autoreply help types)")
            return nil
        end
        rtype = rtype:lower()
        local cond = { type = rtype }
        if not NO_ARG[rtype] then
            local match, quoted
            match, rest, quoted = take_arg(rest)
            if not match then
                say(ctx, "для «" .. rtype .. "» не указан текст или не закрыта кавычка (фразу с пробелами берите в кавычки).")
                say(ctx, 'пример: /autoreply add word "добрый вечер" Привет, {user}!')
                return nil
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
    return conditions, rest, unquoted
end

local function cmd_add(ctx, words)
    if not words[3] then
        add_usage(ctx)
        return
    end
    local rest = table.concat(words, " ", 3)
    local opts
    opts, rest = N.split_opts(rest)
    local name = opts.name
    local channels
    if opts.channel ~= nil then
        local err
        channels, err = util.parse_channels(opts.channel, ctx.channel:get_name())
        if not channels then
            say(ctx, "не удалось добавить правило: " .. err)
            return
        end
    end
    local skip
    if opts.skip ~= nil then
        local err
        skip, err = util.parse_skip(opts.skip)
        if not skip then
            say(ctx, "не удалось добавить правило: " .. err)
            return
        end
    end
    if rest == "" then
        add_usage(ctx)
        return
    end
    local conditions, unquoted
    conditions, rest, unquoted = parse_conditions(ctx, rest)
    if not conditions then
        return
    end
    local reply = rest
    local id, err = E.add_rule(conditions, reply, channels, name, skip)
    if not id then
        say(ctx, "не удалось добавить правило: " .. err)
        say(ctx, "подробнее: /autoreply help add | пошагово: /autoreply new")
        return
    end
    local added = E.find_rule(id)
    say(ctx, string.format("добавлено правило %s (%s) → %s", N.label(added), rules.describe(added), reply))
    if skip then
        say(ctx, skip_status(added))
    end
    if channels and #channels > 0 then
        say(ctx, "действует только в: " .. scope_text(added))
        warn_unwatched(ctx, channels)
    end
    U.soft_warnings(ctx, conditions, reply, unquoted)
    U.after_add(ctx, id, conditions)
end

local function rule_line(r)
    local mark = ""
    if r.enabled == false then
        mark = "  (выключено)"
    elseif not rules.is_usable(r) then
        mark = "  (нет ответа)"
    end
    if is_dormant(r) then
        mark = mark .. "  (канал не добавлен: не работает)"
    end
    local scope = ""
    if type(r.channels) == "table" and #r.channels > 0 then
        scope = " {" .. scope_text(r) .. "}"
    end
    local st = skip_text(r)
    if st ~= "" then
        mark = mark .. "  (" .. st .. ")"
    end
    return string.format("%s [%s]%s → %s%s", N.label(r), rules.describe(r), scope, r.reply or "(нет ответа)", mark)
end

local function cmd_list(ctx, words)
    if #E.cfg.rules == 0 then
        say(ctx, "правил пока нет. Создайте: /autoreply new (пошагово) или /autoreply add ...")
        return
    end
    local only = words and words[3] and util.norm_channel(words[3])
    if only == "" then only = nil end
    local order, groups = {}, {}
    for _, r in ipairs(E.cfg.rules) do
        if not only or rules.applies_to_channel(r, only) then
            local key = (type(r.channels) == "table" and r.channels[1]) or ""
            if not groups[key] then
                groups[key] = {}
                order[#order + 1] = key
            end
            local g = groups[key]
            g[#g + 1] = r
        end
    end
    table.sort(order, function(a, b)
        if a == "" or b == "" then return a == "" and b ~= "" end
        return a < b
    end)
    if #order == 0 then
        say(ctx, "для канала " .. only .. " правил нет.")
        return
    end
    for _, key in ipairs(order) do
        say(ctx, key == "" and "— все каналы —" or ("— #" .. key .. " —"))
        for _, r in ipairs(groups[key]) do
            say(ctx, rule_line(r))
        end
    end
    say(ctx, "правила по каналу: /autoreply list <канал>; сменить канал правила: /autoreply rule <номер> channel <канал|all|here>")
    say(ctx, "проверка без отправки: /autoreply test <id> <сообщение>")
end

local RULE_OP_DONE = { remove = "удалено", enable = "включено", disable = "выключено" }

local function cmd_rule_op(ctx, words, op)
    if not words[3] then
        say(ctx, "использование: /autoreply " .. op .. " <номер или имя правила>  (список: /autoreply list)")
        return
    end
    local rule, idx = N.find(E.cfg.rules, words[3])
    if not rule then
        say(ctx, "нет правила «" .. words[3] .. "»; список: /autoreply list.")
        return
    end
    if op == "remove" then
        table.remove(E.cfg.rules, idx)
    else
        rule.enabled = (op == "enable")
    end
    E.save()
    say(ctx, string.format("правило %s %s.", N.label(rule), RULE_OP_DONE[op]))
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
    return string.format("%s [%s] \"%s\" -> %s%s%s", N.label(r), r.channel, r.title, r.action,
        r.seconds and (" " .. util.format_duration(r.seconds)) or "", r.enabled == false and "  (выключено)" or "")
end

local REDEEM_OP_DONE = { remove = "удалено", enable = "включено", disable = "выключено" }

-- Name-first form "<cmd> <name|id> <verb> ..." -> "<cmd> <verb> <name|id> ...".
-- Returns the (maybe rewritten) words, or nil when it already answered.
local function name_first(ctx, words, verbs, list, gen, listcmd, describe)
    local w3 = words[3] and words[3]:lower()
    if not w3 or verbs[w3] then
        return words
    end
    local item = N.find(list, words[3])
    if not item then
        say(ctx, string.format("нет %s «%s»; список: /autoreply %s.", gen, words[3], listcmd))
        return nil
    end
    if not words[4] then
        say(ctx, describe(item))
        return nil
    end
    local nw = { words[1], words[2], words[4], words[3] }
    for i = 5, #words do
        nw[#nw + 1] = words[i]
    end
    return nw
end

local REDEEM_VERBS = { add = true, list = true, remove = true, enable = true, disable = true, debug = true }

local function cmd_redeem(ctx, words)
    local list = E.cfg.redeems
    words = name_first(ctx, words, REDEEM_VERBS, list, "награды", "redeem list", describe_redeem)
    if not words then
        return
    end
    local sub = words[3] and words[3]:lower() or ""
    if sub == "add" then
        local ok, ismod = pcall(function() return ctx.channel:is_mod() or ctx.channel:is_broadcaster() end)
        if not ok or not ismod then
            say(ctx, "добавлять награды может только модератор или стример этого канала (и канал должен быть на Twitch).")
            return
        end
        local name
        local argi = 4
        if words[4] and words[4]:lower():match("^name=") then
            name = words[4]:sub(6)
            argi = 5
        end
        local action = words[argi] and words[argi]:lower() or ""
        local rest = table.concat(words, " ", argi + 1)
        local title
        title, rest = take_arg(rest)
        local secs
        if action == "timeout" then
            secs = util.parse_duration(rest and rest:match("^(%S+)"))
        end
        if (action ~= "timeout" and action ~= "untimeout") or not title or (action == "timeout" and not secs) then
            say(ctx, 'использование: /autoreply redeem add [name=<имя>] timeout "<название награды>" <время, например 10m>  |  redeem add [name=<имя>] untimeout "<название награды>"')
            say(ctx, "подробнее: /autoreply help redeem")
            return
        end
        local chan = util.norm_channel(ctx.channel:get_name())
        local id, err = E.add_redeem(chan, action, title, secs, name)
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
        local r, idx = N.find(list, words[4])
        if not r then
            say(ctx, "нет награды «" .. tostring(words[4] or "") .. "»; список: /autoreply redeem list.")
            return
        end
        if sub == "remove" then
            table.remove(list, idx)
        else
            r.enabled = (sub == "enable")
        end
        E.save()
        say(ctx, string.format("награда %s %s.", N.label(r), REDEEM_OP_DONE[sub]))
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
    elseif key == "skipmods" and (val == "on" or val == "off") then
        E.cfg.skip_mods = (val == "on")
        E.save()
        say(ctx, "модераторы не запускают ответы (по умолчанию для всех правил и счётчиков): " .. val)
    elseif key == "live" and (val == "on" or val == "off") then
        E.cfg.only_when_live = (val == "on")
        E.save()
        say(ctx, "отвечать только когда идёт стрим: " .. val)
    else
        say(ctx, "использование: /autoreply set usercd|rulecd|gap <секунды>  |  set live|skipmods|mutelurkers|backfire on|off   (подробнее: /autoreply help set)")
    end
end

local function timer_line(t)
    local state = "остановлен"
    if t.enabled and t.started_at then
        state = util.format_elapsed(E.timer_elapsed(t), t.format)
    end
    local st = skip_text(t)
    return string.format("%s [%s @%s, %s, при смене категории: %s] %s → %s%s", N.label(t), rules.describe(t), t.channel,
        t.format, t.on_category, state, t.reply, st ~= "" and ("  (" .. st .. ")") or "")
end

local TIMER_VERBS = { add = true, list = true, on = true, off = true, reset = true, set = true,
    remove = true, format = true, category = true, skip = true }

local TIMER_USAGE = 'использование: /autoreply timer add [name=<имя>] <условие> [+ <условие> ...] => [smart|full] <ответ с {time}>  или  timer add "<!команда>" [smart|full] <ответ с {time}>   (подробнее: /autoreply help timer)'
local TIMER_EXAMPLE = 'пример: /autoreply timer add anyword "давно|сколько" + anyword "играет|играем" => smart @{user} играет уже {time}'

local function cmd_timer(ctx, words)
    local timers = E.cfg.timers
    words = name_first(ctx, words, TIMER_VERBS, timers, "счётчика", "timer list", timer_line)
    if not words then
        return
    end
    local sub = words[3] and words[3]:lower() or ""
    if sub == "add" then
        local rest = table.concat(words, " ", 4)
        local opts
        opts, rest = N.split_opts(rest, { name = true, skip = true })
        local name = opts.name
        if rest:lower():match("^channel=") then
            say(ctx, "счётчик всегда привязан к каналу, где введена команда; channel= здесь не нужен.")
            return
        end
        local skip
        if opts.skip ~= nil then
            local serr
            skip, serr = util.parse_skip(opts.skip)
            if not skip then
                say(ctx, "не удалось добавить счётчик: " .. serr)
                return
            end
        end
        local conditions
        local first, _, first_quoted = take_arg(rest)
        if first and not first_quoted and rules.is_type(first:lower()) then
            -- rule-style: <cond> [+ <cond>...] => [smart|full] <reply>
            conditions, rest = parse_conditions(ctx, rest)
            if not conditions then
                return
            end
            local after = rest:match("^=>%s*(.*)$")
            if not after then
                say(ctx, "после условий нужен разделитель => перед ответом.")
                say(ctx, TIMER_EXAMPLE)
                return
            end
            rest = after
        else
            -- legacy: one whole-word trigger
            local trigger
            trigger, rest = take_arg(rest)
            if not trigger then
                say(ctx, TIMER_USAGE)
                return
            end
            conditions = { { type = "word", match = trigger } }
        end
        local fmt = "smart"
        local maybe, after = take_arg(rest)
        if maybe == "smart" or maybe == "full" then
            fmt, rest = maybe, after
        end
        local chan = util.norm_channel(ctx.channel:get_name())
        local id, err = E.add_timer(conditions, chan, rest, fmt, name, skip)
        if not id then
            say(ctx, "не удалось добавить счётчик: " .. err)
            say(ctx, 'пример: /autoreply timer add "!uptime" Играем уже {time}')
            say(ctx, TIMER_EXAMPLE)
            return
        end
        say(ctx, string.format("добавлен счётчик %s (%s) в %s, отсчёт с текущего момента → %s",
            N.label(E.find_timer(id)), rules.describe(E.find_timer(id)), chan, rest))
        if skip then
            say(ctx, skip_status(E.find_timer(id)))
        end
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
            say(ctx, timer_line(t))
        end
        return
    end
    local t, idx = N.find(timers, words[4])
    if not t then
        if words[4] and TIMER_VERBS[sub] then
            say(ctx, "нет счётчика «" .. words[4] .. "»; список: /autoreply timer list.")
        else
            say(ctx, "использование: /autoreply timer add|list|on|off|reset|set|remove|format|category|skip ...  (номер или имя из timer list; подробнее: /autoreply help timer)")
        end
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
        say(ctx, string.format("счётчик %s запущен с %s.", N.label(t), from))
    elseif sub == "off" then
        E.set_timer_enabled(t, false)
        say(ctx, string.format("счётчик %s остановлен.", N.label(t)))
    elseif sub == "reset" or sub == "set" then
        E.reset_timer(t, offset)
        say(ctx, string.format("счётчик %s перезапущен с %s.", N.label(t), from))
    elseif sub == "remove" then
        table.remove(timers, idx)
        E.save()
        say(ctx, string.format("счётчик %s удалён.", N.label(t)))
    elseif sub == "skip" then
        handle_skip(ctx, t, { table.unpack(words, 5) }, "/autoreply timer skip " .. words[4])
    elseif sub == "format" and (words[5] == "smart" or words[5] == "full") then
        t.format = words[5]
        E.save()
        say(ctx, string.format("формат счётчика %s: %s.", N.label(t), t.format))
    elseif sub == "category" and (words[5] == "reset" or words[5] == "stop" or words[5] == "off") then
        t.on_category = words[5]
        E.save()
        say(ctx, string.format("при смене категории счётчик %s: %s.", N.label(t), t.on_category))
    else
        say(ctx, "использование: /autoreply timer format <номер> smart|full  |  category <номер> reset|stop|off")
    end
end

-- /autoreply test <id|all> [flags=a,b] <text>: shows what would happen, sends nothing.
local function cmd_test(ctx, words)
    local target = words[3]
    local idx = 4
    local flagnames = {}
    local sender, sender_mod = "viewer", false
    while words[idx] do
        local w = words[idx]:lower()
        if w:match("^flags=") then
            for n in w:sub(7):gmatch("[^,]+") do
                flagnames[#flagnames + 1] = n
            end
        elseif w:match("^as=") then
            local who = util.norm_user(w:sub(4))
            if who == "mod" then
                sender, sender_mod = "moderator", true
            elseif who:match("^[%w_]+$") then
                sender = who
            else
                say(ctx, "as= принимает mod или ник (например as=mod, as=vasya).")
                return
            end
        else
            break
        end
        idx = idx + 1
    end
    local function is_mod() return sender_mod end
    local text = table.concat(words, " ", idx)
    if not target or text == "" then
        say(ctx, "использование: /autoreply test <номер или имя правила|all> [flags=first,sub] [as=mod|ник] <текст сообщения>")
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
        local r = N.find(E.cfg.rules, target)
        if not r then
            say(ctx, "нет правила «" .. target .. "»; список: /autoreply list. Или используйте all.")
            return
        end
        list = { r }
    end
    local me = U.my_login()
    local fake = { display_name = "Зритель", login_name = "viewer" }
    say(ctx, "проверка (ничего не отправляется): «" .. text .. "»" .. (#flagnames > 0 and (" с флагами " .. table.concat(flagnames, ",")) or "") .. (sender ~= "viewer" and (", отправитель: " .. sender) or ""))
    for _, t in ipairs(E.cfg.timers) do
        if t.enabled and t.started_at and rules.matches(t, text, mask, me) then
            if E.is_skipped(t, sender, is_mod) then
                say(ctx, string.format("счётчик %s (%s): совпал, но отправитель «%s» пропускается — не сработает.", N.label(t), rules.describe(t), sender))
            else
                say(ctx, string.format("совпал счётчик %s (%s): он срабатывает раньше правил.", N.label(t), rules.describe(t)))
            end
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
            if rules.is_usable(r) and E.is_skipped(r, sender, is_mod) then
                say(ctx, string.format("%s: условия совпали, но отправитель «%s» пропускается — не сработает, проверяются следующие правила.", N.label(r), sender))
            elseif not rules.is_usable(r) then
                say(ctx, string.format("%s: условия совпали, но правило выключено или без ответа — не сработает.", N.label(r)))
            elseif winner then
                say(ctx, string.format("%s: совпало, но выше уже сработает правило %s (побеждает первое совпавшее).", N.label(r), winner))
            else
                winner = N.label(r)
                say(ctx, string.format("%s: СОВПАЛО → ответ: %s", winner, E.render(r.reply, fake)))
            end
        else
            say(ctx, string.format("%s: не совпало (не выполнено: %s)", N.label(r), table.concat(failed, "; ")))
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

-- /autoreply rule <name|id> [enable|disable|remove|test <text>]
local function cmd_rule(ctx, words)
    if not words[3] then
        say(ctx, "использование: /autoreply rule <номер или имя> [enable|disable|remove|channel <канал|all|here>|skip ...|test <текст>]   (подробнее: /autoreply help names)")
        return
    end
    local rule = N.find(E.cfg.rules, words[3])
    if not rule then
        say(ctx, "нет правила «" .. words[3] .. "»; список: /autoreply list.")
        return
    end
    local verb = words[4] and words[4]:lower()
    if not verb then
        say(ctx, rule_line(rule))
    elseif verb == "test" then
        local nw = { words[1], "test", words[3] }
        for i = 5, #words do
            nw[#nw + 1] = words[i]
        end
        cmd_test(ctx, nw)
    elseif verb == "channel" or verb == "channels" then
        if not words[5] then
            say(ctx, string.format("правило %s действует: %s. Сменить: /autoreply rule %s channel <канал[,канал]|here|all>",
                N.label(rule), scope_text(rule), words[3]))
            return
        end
        local chans, err = util.parse_channels(words[5], ctx.channel:get_name())
        if not chans then
            say(ctx, "ошибка: " .. err)
            return
        end
        E.set_rule_channels(rule, chans)
        say(ctx, string.format("правило %s теперь действует: %s.", N.label(rule), scope_text(rule)))
        warn_unwatched(ctx, chans)
    elseif verb == "skip" then
        handle_skip(ctx, rule, { table.unpack(words, 5) }, "/autoreply rule " .. words[3] .. " skip")
    elseif RULE_OP_DONE[verb] then
        cmd_rule_op(ctx, { words[1], verb, words[3] }, verb)
    else
        say(ctx, "неизвестное действие «" .. words[4] .. "»: доступны enable, disable, remove, test, channel, skip.")
    end
end

local RENAME_KINDS = { rule = "rules", rules = "rules", timer = "timers", timers = "timers",
    redeem = "redeems", redeems = "redeems", mute = "redeems" }

-- /autoreply rename rule|timer|redeem <id|name> <new|->
local function cmd_rename(ctx, words)
    local key = words[3] and RENAME_KINDS[words[3]:lower()]
    if not key or not words[4] or not words[5] then
        say(ctx, "использование: /autoreply rename rule|timer|redeem <номер или имя> <новое имя | - чтобы убрать имя>")
        return
    end
    local item = N.find(E.cfg[key], words[4])
    if not item then
        say(ctx, "не найдено: «" .. words[4] .. "» (" .. words[3] .. "). Посмотрите список: /autoreply list | timer list | redeem list")
        return
    end
    local new = words[5]
    if new == "-" then
        new = nil
    end
    local before = N.label(item)
    local ok, err = E.rename(key, item, new)
    if not ok then
        say(ctx, "не удалось переименовать: " .. err)
        return
    end
    if new then
        say(ctx, string.format("%s %s теперь называется «%s».", N.NOUN[key], before, new))
    else
        say(ctx, string.format("имя у %s %s убрано.", N.NOUN[key], before))
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
        cmd_list(ctx, words)
    elseif sub == "test" then
        cmd_test(ctx, words)
    elseif sub == "rule" then
        cmd_rule(ctx, words)
    elseif sub == "rename" then
        cmd_rename(ctx, words)
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
