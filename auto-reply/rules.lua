-- Trigger matching. Pure functions where possible (flags are looked up lazily).
local M = {}

M.TYPES = { "keyword", "word", "anyword", "mention", "flag", "pattern" }

function M.is_type(s)
    for _, t in ipairs(M.TYPES) do
        if t == s then return true end
    end
    return false
end

-- friendly flag name -> c2.MessageFlag member
M.FLAGS = {
    first = "FirstMessage",
    highlighted = "Highlighted",
    reply = "ReplyMessage",
    announcement = "Announcement",
    sub = "Subscription",
    cheer = "CheerMessage",
}

-- display order of flag names (completion, wizard, errors)
M.FLAG_ORDER = { "first", "highlighted", "reply", "announcement", "sub", "cheer" }
M.FLAG_INFO = {
    first = "первое сообщение зрителя",
    highlighted = "выделенное сообщение",
    reply = "ответ на сообщение",
    announcement = "объявление",
    sub = "подписка",
    cheer = "биты",
}

-- Plain-language description of each condition type (help, wizard).
M.TYPE_INFO = {
    keyword = {
        what = "подстрока: текст ищется где угодно, даже внутри слова («при» сработает на «привет» и «спринт»); удобно для команд вроде !discord",
        syntax = '/autoreply add keyword "<текст>" <ответ>',
        example = "/autoreply add keyword !discord Наш дискорд: discord.gg/xxxx",
    },
    word = {
        what = "отдельное слово или фраза целиком: «привет» сработает на «Привет!», но не на «приветствую» (регистр не важен)",
        syntax = '/autoreply add word "<слово или фраза>" <ответ>',
        example = "/autoreply add word привет Привет, {user}!",
    },
    anyword = {
        what = "любое из нескольких слов (варианты через |), каждое как отдельное слово",
        syntax = '/autoreply add anyword "<слово1|слово2|слово3>" <ответ>',
        example = '/autoreply add anyword "qq|привет|hi" @{user} qq',
    },
    mention = {
        what = "сообщение упоминает вас (@ваш_ник или просто ник)",
        syntax = "/autoreply add mention <ответ>",
        example = "/autoreply add mention Слушаю, {user}!",
    },
    flag = {
        what = "свойство сообщения: first = первое сообщение зрителя, highlighted = выделенное, reply = ответ на сообщение, announcement = объявление, sub = подписка, cheer = биты",
        syntax = "/autoreply add flag first|highlighted|reply|announcement|sub|cheer <ответ>",
        example = "/autoreply add flag first Добро пожаловать, {user}!",
    },
    pattern = {
        what = "шаблон Lua для опытных (это НЕ regex); если не уверены, берите keyword или word",
        syntax = '/autoreply add pattern "<шаблон Lua>" <ответ>',
        example = '/autoreply add pattern "^!hello%s*$" Привет!',
    },
}

-- Unicode-aware lowercase (Lua's string.lower only handles ASCII).
local function lower_cp(cp)
    if cp >= 0x41 and cp <= 0x5A then return cp + 32 end
    if cp >= 0x410 and cp <= 0x42F then return cp + 32 end
    if cp >= 0x400 and cp <= 0x40F then return cp + 80 end
    if cp >= 0x490 and cp <= 0x4BF and cp % 2 == 0 then return cp + 1 end
    return cp
end

function M.lower(str)
    local ok, res = pcall(function()
        local out = {}
        for _, cp in utf8.codes(str) do
            out[#out + 1] = utf8.char(lower_cp(cp))
        end
        return table.concat(out)
    end)
    if ok then
        return res
    end
    return str:lower()
end

-- Bytes >= 128 (Cyrillic etc.) count as letters, so word edges work in any language.
local function is_wordchar_at(str, i)
    local b = str:byte(i)
    if not b then return false end
    return b >= 128 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122) or b == 95
end

local function find_word(lower_text, needle)
    if needle == "" then return false end
    local init = 1
    while true do
        local s, e = lower_text:find(needle, init, true)
        if not s then return false end
        if not is_wordchar_at(lower_text, s - 1) and not is_wordchar_at(lower_text, e + 1) then
            return true
        end
        init = s + 1
    end
end

local function split_alternatives(str)
    local out = {}
    for part in (str .. "|"):gmatch("(.-)|") do
        local trimmed = part:match("^%s*(.-)%s*$")
        if trimmed ~= "" then out[#out + 1] = trimmed end
    end
    return out
end

local function escape_pattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local function has_flag(flags, name)
    local bit = c2.MessageFlag[name]
    if not bit or bit == 0 then
        return false
    end
    return (flags & bit) ~= 0
end

-- Returns ok, err
function M.validate(rtype, match)
    if rtype == "keyword" or rtype == "word" then
        if not match or match == "" then
            return false, "нужен непустой текст для поиска"
        end
    elseif rtype == "anyword" then
        if not match or #split_alternatives(match) == 0 then
            return false, 'нужны слова через |, например "qq|hi|привет"'
        end
    elseif rtype == "mention" then
        return true
    elseif rtype == "flag" then
        if not M.FLAGS[match or ""] then
            return false, "флаг должен быть одним из: " .. table.concat(M.FLAG_ORDER, ", ")
        end
    elseif rtype == "pattern" then
        if not match or match == "" then
            return false, "нужен шаблон Lua"
        end
        local ok, err = pcall(string.find, "", match)
        if not ok then
            return false, "некорректный шаблон Lua: " .. tostring(err)
        end
    else
        return false, "неизвестный тип «" .. tostring(rtype) .. "» (доступны: " .. table.concat(M.TYPES, ", ") .. ")"
    end
    return true
end

-- Builds a flags bitmask from friendly names. Returns mask, unknown_names.
function M.flags_from_names(names)
    local mask, unknown = 0, {}
    for _, n in ipairs(names) do
        local key = M.FLAGS[n]
        local bit = key and c2.MessageFlag[key]
        if bit then
            mask = mask | bit
        else
            unknown[#unknown + 1] = n
        end
    end
    return mask, unknown
end

-- Example message (and flag names) that should trigger the given conditions.
function M.sample(conditions, me)
    local parts, flags = {}, {}
    for _, c in ipairs(conditions) do
        if c.type == "keyword" or c.type == "word" then
            parts[#parts + 1] = c.match
        elseif c.type == "anyword" then
            parts[#parts + 1] = split_alternatives(c.match)[1] or ""
        elseif c.type == "mention" then
            parts[#parts + 1] = "@" .. ((me and me ~= "") and me or "ваш_ник")
        elseif c.type == "flag" then
            flags[#flags + 1] = c.match
        end
    end
    return table.concat(parts, " "), flags
end

-- A rule can only fire if it has a non-empty reply (hard requirement).
function M.is_usable(rule)
    return rule.enabled ~= false
        and type(rule.reply) == "string"
        and rule.reply:match("%S") ~= nil
end

function M.applies_to_channel(rule, channel)
    if type(rule.channels) ~= "table" or #rule.channels == 0 then
        return true
    end
    for _, c in ipairs(rule.channels) do
        if c == channel then
            return true
        end
    end
    return false
end

-- A rule is a list of conditions that must ALL match. Old-style rules
-- (type/match on the rule itself) count as a single condition. Old-style timers
-- (a bare `trigger` word) count as one whole-word condition.
function M.conditions(rule)
    if type(rule.conditions) == "table" and #rule.conditions > 0 then
        return rule.conditions
    end
    if rule.type == nil and type(rule.trigger) == "string" then
        return { { type = "word", match = rule.trigger } }
    end
    return { { type = rule.type, match = rule.match } }
end

function M.describe(rule)
    local parts = {}
    for _, c in ipairs(M.conditions(rule)) do
        parts[#parts + 1] = c.type .. (c.match and (" " .. c.match) or "")
    end
    return table.concat(parts, " + ")
end

function M.matches(rule, text, flags, me)
    for _, c in ipairs(M.conditions(rule)) do
        if not M.matches_one(c, text, flags, me) then
            return false
        end
    end
    return true
end

-- text: message text, flags: number, me: own login (lowercase)
function M.matches_one(rule, text, flags, me)
    local rtype = rule.type
    local lower = M.lower(text)
    if rtype == "keyword" then
        return lower:find(M.lower(rule.match), 1, true) ~= nil
    elseif rtype == "word" then
        return find_word(lower, M.lower(rule.match))
    elseif rtype == "anyword" then
        for _, alt in ipairs(split_alternatives(rule.match)) do
            if find_word(lower, M.lower(alt)) then
                return true
            end
        end
        return false
    elseif rtype == "mention" then
        if not me or me == "" then
            return false
        end
        return lower:find("@" .. escape_pattern(me) .. "%f[^%w_]") ~= nil
            or lower:find("%f[%w_]" .. escape_pattern(me) .. "%f[^%w_]") ~= nil
    elseif rtype == "flag" then
        local name = M.FLAGS[rule.match or ""]
        return name ~= nil and has_flag(flags, name)
    elseif rtype == "pattern" then
        local ok, res = pcall(string.find, text, rule.match)
        return ok and res ~= nil
    end
    return false
end

-- Text of the reward line Chatterino draws for a redemption ("Redeemed <title> <cost>"),
-- read from elements flagged ChannelPointReward. nil when Chatterino doesn't know the reward.
function M.reward_title(msg)
    local bit = c2.MessageElementFlag and c2.MessageElementFlag.ChannelPointReward or 0
    if bit == 0 then
        return nil
    end
    local ok, res = pcall(function()
        local parts = {}
        for _, el in ipairs(msg:elements()) do
            if (el.flags & bit) ~= 0 and type(el.words) == "table" then
                parts[#parts + 1] = table.concat(el.words, " ")
            end
        end
        return table.concat(parts, " ")
    end)
    if ok and res ~= "" then
        return res
    end
    return nil
end

-- True when the message carries a moderator badge element.
function M.has_mod_badge(msg)
    local ok, res = pcall(function()
        for _, el in ipairs(msg:elements()) do
            if el.type == "mod-badge" then
                return true
            end
            if type(el.type) == "string" and el.type:find("badge", 1, true)
                and type(el.tooltip) == "string" and el.tooltip:lower():find("moderator", 1, true) then
                return true
            end
        end
        return false
    end)
    return ok and res
end

-- Extracts the target login from a redemption's input.
-- Accepts "nick", "@nick", or the merged "Redeemed <title> <cost> <input>" form.
-- Returns login, or nil + reason. Strict: ambiguous input is refused.
function M.parse_target(text)
    local tokens = {}
    for tok in tostring(text or ""):gmatch("%S+") do
        tokens[#tokens + 1] = tok
    end
    if tokens[1] and tokens[1]:lower() == "redeemed" then
        local cost
        for i = 2, #tokens do
            if tokens[i]:match("^%d+$") then
                cost = i
                break
            end
        end
        if not cost then
            return nil, "не нашёл ник в сообщении награды"
        end
        tokens = { table.unpack(tokens, cost + 1) }
    end
    if #tokens == 0 then
        return nil, "ник не указан"
    end
    local pick
    for _, t in ipairs(tokens) do
        if t:sub(1, 1) == "@" then
            pick = t
            break
        end
    end
    if not pick then
        if #tokens > 1 then
            return nil, "неясно, кого выбрать (укажите один ник или @ник)"
        end
        pick = tokens[1]
    end
    local login = pick:gsub("^@", "")
    login = login:gsub("[,%.!%?:;]+$", "")
    login = login:lower()
    if not login:match("^[a-z0-9_]+$") or #login < 3 or #login > 25 then
        return nil, "«" .. pick .. "» не похоже на ник Twitch"
    end
    return login
end

return M
