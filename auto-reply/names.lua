-- Optional human names for rules, timers and redeems (usable instead of ids).
local rules = require("rules")

local N = {}

-- Nouns used in messages, keyed by config list name.
N.NOUN = { rules = "правило", timers = "счётчик", redeems = "награда" }

-- Names that would clash with subcommands / verbs.
local RESERVED = {}
for w in ([[on off toggle status channel channels add new wizard list test remove enable disable
    timer timers ignore redeem mute protect set reload help cancel back rule rename reset format
    category debug timeout untimeout smart full all name]]):gmatch("%S+") do
    RESERVED[w] = true
end

function N.key(name)
    return rules.lower(name)
end

-- Returns ok, err.
function N.valid(name)
    if type(name) ~= "string" or name == "" then
        return false, "имя не может быть пустым"
    end
    local len = utf8.len(name)
    if not len then
        return false, "имя содержит недопустимые символы"
    end
    if len > 20 then
        return false, "имя длиннее 20 символов"
    end
    if not name:match("^[%w_%-\128-\255]+$") then
        return false, "в имени можно использовать только буквы, цифры, _ и -"
    end
    if not (name:find("%a") or name:find("[\128-\255]")) then
        return false, "в имени должна быть хотя бы одна буква (имя из цифр путается с номером)"
    end
    if RESERVED[N.key(name)] then
        return false, "имя «" .. name .. "» зарезервировано (это название команды)"
    end
    return true
end

-- ref: numeric string = id, anything else = name (case-insensitive).
-- Returns item, index (or nil).
function N.find(list, ref)
    if type(ref) ~= "string" or ref == "" then
        return nil
    end
    if ref:match("^%d+$") then
        local id = tonumber(ref)
        for i, it in ipairs(list) do
            if it.id == id then
                return it, i
            end
        end
        return nil
    end
    local key = N.key(ref)
    for i, it in ipairs(list) do
        if type(it.name) == "string" and N.key(it.name) == key then
            return it, i
        end
    end
    return nil
end

-- "#3" or "#3 greet"
function N.label(item)
    if type(item.name) == "string" and item.name ~= "" then
        return "#" .. item.id .. " " .. item.name
    end
    return "#" .. item.id
end

-- Validates name for a list (valid format, not used by another item).
-- except: the item being renamed (may keep/alter case of its own name).
function N.check(list, name, key, except)
    local ok, err = N.valid(name)
    if not ok then
        return false, err
    end
    local k = N.key(name)
    for _, it in ipairs(list) do
        if it ~= except and type(it.name) == "string" and N.key(it.name) == k then
            return false, string.format("имя «%s» уже занято: %s %s", name, N.NOUN[key] or "элемент", N.label(it))
        end
    end
    return true
end

-- Strips a leading "name=<token>" from a string. Returns name (maybe ""), rest;
-- or nil, rest when there is no such prefix.
function N.split_name_opt(rest)
    local name, tail = rest:match("^[nN][aA][mM][eE]=(%S*)%s*(.*)$")
    if name then
        return name, tail
    end
    return nil, rest
end

return N
