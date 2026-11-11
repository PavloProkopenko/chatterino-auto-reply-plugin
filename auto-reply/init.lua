-- Auto Reply plugin for Chatterino / Leafyrino.
-- Configure with /autoreply help. Config lives in data/config.json.
local E = require("engine")
local commands = require("commands")

E.load()
E.start_poll()

local ok = c2.register_command("/autoreply", commands.handle)
if not ok then
    c2.log(c2.LogLevel.Warning, "auto-reply: /autoreply is already registered by something else")
end

-- One-click on/off from the right-click menu of any chat message.
c2.windows:on_channelview_context_menu_requested(function(args)
    local menu = args.menu
    menu:add_separator()
    local label = E.active and "Auto-reply: turn OFF" or "Auto-reply: turn ON (until app closes)"
    menu:add_action(label, function()
        E.notice_channel = args.channel or E.notice_channel
        if E.active then
            E.deactivate("disabled.")
        else
            E.activate(nil, false)
            E.notify("enabled until the app closes. Use /autoreply on <period> for a timed run.")
        end
    end)
end)

c2.log(c2.LogLevel.Info, "auto-reply loaded; use /autoreply help")
