-- /autoreply new: step-by-step rule creation in chat. State lives in memory only.
local rules = require("rules")
local util = require("util")
local E = require("engine")
local U = require("ux")

local W = {}
local draft = nil

local FOOT = "(шаг назад: /autoreply back, отмена: /autoreply cancel)"

function W.active()
    return draft ~= nil
end

local function say(ctx, t)
    U.say(ctx, t)
end

local function ask_type(ctx)
    draft.step = "type"
    if #draft.conds == 0 then
        say(ctx, "Что должно запускать ответ? Ответьте /autoreply <номер>:")
    else
        say(ctx, "Следующее условие (должны совпасть ВСЕ). Ответьте /autoreply <номер>:")
    end
    for i, t in ipairs(rules.TYPES) do
        say(ctx, string.format("%d — %s — %s", i, t, rules.TYPE_INFO[t].what))
    end
    say(ctx, FOOT)
end

local function ask_value(ctx)
    draft.step = "value"
    local t = draft.cur
    if t == "flag" then
        say(ctx, "Какое свойство сообщения? Ответьте /autoreply <номер>:")
        for i, n in ipairs(rules.FLAG_ORDER) do
            say(ctx, string.format("%d — %s — %s", i, n, rules.FLAG_INFO[n]))
        end
    elseif t == "anyword" then
        say(ctx, "Введите слова через | (например: /autoreply qq|привет|hi):")
    elseif t == "pattern" then
        say(ctx, "Введите шаблон Lua (это не regex), например: /autoreply ^!hello%s*$")
    else
        say(ctx, "Введите текст для поиска (можно с пробелами, без кавычек): /autoreply <текст>")
    end
    say(ctx, FOOT)
end

local function ask_more(ctx)
    draft.step = "more"
    local last = draft.conds[#draft.conds]
    say(ctx, string.format("Условие добавлено: %s. Добавить ещё одно (должны совпасть оба)? /autoreply 1 — да, /autoreply 2 — нет, перейти к ответу.",
        rules.describe({ type = last.type, match = last.match })))
    say(ctx, FOOT)
end

local function ask_reply(ctx)
    draft.step = "reply"
    say(ctx, "Введите текст ответа: /autoreply <ответ>. {user} заменится на ник написавшего; до 500 символов, нельзя начинать с / или .")
    say(ctx, FOOT)
end

local function ask_channel(ctx)
    draft.step = "channel"
    say(ctx, "Для каких каналов правило? Ответьте /autoreply all (все добавленные каналы), /autoreply here (канал этого окна) или список через запятую, например /autoreply streamer,friend")
    say(ctx, FOOT)
end

local function ask_confirm(ctx)
    draft.step = "confirm"
    local descr = {}
    for _, c in ipairs(draft.conds) do
        descr[#descr + 1] = rules.describe({ type = c.type, match = c.match })
    end
    local scope = (draft.channels and #draft.channels > 0) and ("#" .. table.concat(draft.channels, ", #")) or "все каналы"
    say(ctx, string.format("Правило: [%s] → %s (каналы: %s)", table.concat(descr, " + "), draft.reply, scope))
    say(ctx, "То же одной строкой: " .. U.cmd_line(draft.conds, draft.reply, draft.channels))
    say(ctx, "/autoreply 1 — сохранить, /autoreply 2 — отменить. " .. FOOT)
end

function W.start(ctx)
    draft = { conds = {}, step = "type" }
    say(ctx, "Мастер создания правила. Отвечайте командой /autoreply <ответ> (номер варианта или текст).")
    ask_type(ctx)
end

function W.cancel(ctx)
    draft = nil
    say(ctx, "мастер отменён.")
end

local function back(ctx)
    local step = draft.step
    if step == "type" then
        if #draft.conds == 0 then
            say(ctx, "это первый шаг; для выхода: /autoreply cancel.")
        else
            ask_more(ctx)
        end
    elseif step == "value" then
        ask_type(ctx)
    elseif step == "more" then
        local last = table.remove(draft.conds)
        draft.cur = last.type
        if last.type == "mention" then
            ask_type(ctx)
        else
            ask_value(ctx)
        end
    elseif step == "reply" then
        ask_more(ctx)
    elseif step == "channel" then
        ask_reply(ctx)
    elseif step == "confirm" then
        ask_channel(ctx)
    end
end

local YES = { ["1"] = true, ["да"] = true, yes = true, y = true }
local NO = { ["2"] = true, ["нет"] = true, no = true, n = true }

-- words: ctx.words (words[1] = "/autoreply", answer starts at words[2]).
function W.answer(ctx, words)
    local first = words[2] and words[2]:lower() or ""
    local text = table.concat(words, " ", 2)
    if #words == 2 then
        if first == "cancel" or first == "отмена" then
            W.cancel(ctx)
            return
        elseif first == "back" or first == "назад" then
            back(ctx)
            return
        end
    end
    local step = draft.step
    if step == "type" then
        local t = rules.TYPES[tonumber(first) or 0] or (rules.TYPE_INFO[first] and first)
        if not t then
            say(ctx, "не понял: ответьте номером от 1 до " .. #rules.TYPES .. ".")
            ask_type(ctx)
            return
        end
        draft.cur = t
        if t == "mention" then
            draft.conds[#draft.conds + 1] = { type = "mention" }
            ask_more(ctx)
        else
            ask_value(ctx)
        end
    elseif step == "value" then
        local t = draft.cur
        local val
        if t == "flag" then
            val = rules.FLAG_ORDER[tonumber(first) or 0] or (rules.FLAGS[first] and first)
        else
            val = text
        end
        if not val or val == "" then
            say(ctx, "не понял, попробуйте ещё раз.")
            ask_value(ctx)
            return
        end
        if val:find('"', 1, true) then
            say(ctx, 'кавычки " в тексте условия не поддерживаются; уберите их.')
            return
        end
        local ok, err = rules.validate(t, val)
        if not ok then
            say(ctx, "ошибка: " .. err)
            return
        end
        draft.conds[#draft.conds + 1] = { type = t, match = val }
        ask_more(ctx)
    elseif step == "more" then
        if YES[first] then
            ask_type(ctx)
        elseif NO[first] then
            ask_reply(ctx)
        else
            say(ctx, "ответьте /autoreply 1 (добавить условие) или /autoreply 2 (перейти к ответу).")
        end
    elseif step == "reply" then
        local ok, err = E.check_reply(text)
        if not ok then
            say(ctx, "ошибка: " .. err)
            return
        end
        draft.reply = text
        ask_channel(ctx)
    elseif step == "channel" then
        local chans, err = util.parse_channels(first == "" and "all" or text:gsub("%s+", ""), ctx.channel:get_name())
        if not chans then
            say(ctx, "ошибка: " .. err)
            return
        end
        draft.channels = chans
        ask_confirm(ctx)
    elseif step == "confirm" then
        if YES[first] or first == "save" then
            local id, err = E.add_rule(draft.conds, draft.reply, draft.channels)
            if not id then
                say(ctx, "не удалось добавить правило: " .. err)
                return
            end
            local conds, reply = draft.conds, draft.reply
            draft = nil
            say(ctx, string.format("добавлено правило #%d (%s) → %s", id,
                rules.describe(E.find_rule(id)), reply))
            for _, c in ipairs(E.find_rule(id).channels or {}) do
                if not util.contains(E.cfg.channels, c) then
                    say(ctx, "внимание: " .. c .. " нет в списке каналов; добавьте: /autoreply channel add " .. c)
                end
            end
            U.soft_warnings(ctx, conds, reply, nil)
            U.after_add(ctx, id, conds)
        elseif NO[first] then
            W.cancel(ctx)
        else
            say(ctx, "ответьте /autoreply 1 (сохранить) или /autoreply 2 (отменить).")
        end
    end
end

return W
