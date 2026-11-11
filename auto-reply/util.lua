-- Small helpers shared by all modules.
local M = {}

function M.now_s()
    return c2.DateTime.current_utc():to_unix_seconds()
end

function M.now_ms()
    return c2.DateTime.current_utc():to_unix_milliseconds()
end

function M.norm_channel(name)
    name = tostring(name or ""):lower()
    name = name:gsub("^#", "")
    return name
end

function M.norm_user(name)
    name = tostring(name or ""):lower()
    name = name:gsub("^@", "")
    return name
end

-- "90s" "30m" "2h" "1d" "1h30m" -> seconds, or nil
function M.parse_duration(str)
    if not str or str == "" then
        return nil
    end
    str = str:lower()
    local total, pos = 0, 1
    local units = { s = 1, m = 60, h = 3600, d = 86400 }
    while pos <= #str do
        local num, unit, nxt = str:match("^(%d+)([smhd])()", pos)
        if not num then
            return nil
        end
        total = total + tonumber(num) * units[unit]
        pos = nxt
    end
    if total <= 0 then
        return nil
    end
    return total
end

function M.format_duration(sec)
    sec = math.max(0, math.floor(sec))
    local d = sec // 86400
    local h = (sec % 86400) // 3600
    local m = (sec % 3600) // 60
    local s = sec % 60
    local out = {}
    if d > 0 then out[#out + 1] = d .. "d" end
    if h > 0 then out[#out + 1] = h .. "h" end
    if m > 0 then out[#out + 1] = m .. "m" end
    if s > 0 and d == 0 and h == 0 then out[#out + 1] = s .. "s" end
    if #out == 0 then return "0s" end
    return table.concat(out, " ")
end

M.JUST_STARTED = "только начал"

-- Elapsed time for the {time} placeholder.
-- "smart": <1 min -> "только начал", <1h -> "45 мин", else "2 ч 35 мин" / "2 ч".
-- "full": "h:mm:ss".
function M.format_elapsed(sec, fmt)
    sec = math.max(0, math.floor(sec or 0))
    if fmt == "full" then
        return string.format("%d:%02d:%02d", sec // 3600, (sec % 3600) // 60, sec % 60)
    end
    local h = sec // 3600
    local m = (sec % 3600) // 60
    if h == 0 and m == 0 then
        return M.JUST_STARTED
    end
    if h == 0 then
        return m .. " мин"
    end
    if m == 0 then
        return h .. " ч"
    end
    return h .. " ч " .. m .. " мин"
end

function M.contains(list, value)
    for i, v in ipairs(list) do
        if v == value then
            return i
        end
    end
    return nil
end

return M
