# Auto Reply plugin for Leafyrino

## What is auto-reply-plugin?

A Lua plugin for [Leafyrino](https://github.com/leafyzito/leafyrino) (a Chatterino fork) that watches the chats you choose and automatically sends a reply when a message matches a trigger you defined.

- Pick one or many channels.
- Define rules: a trigger (keyword, whole word, a list of words, mention of you, message type, Lua pattern) plus a reply. Conditions can be combined with `+` (all must match).
- Turn it on for a period (`30m`, `2h`, `1d`), until the app closes, or permanently, and turn it off in one command or one right-click.
- A rule without a reply never fires.
- Built-in safeguards: ignores your own messages and system messages, per-user and per-rule cooldowns, a minimum gap between replies, an optional "only while live" mode, and an ignore list for bots.
- Replies can contain `{user}`, which becomes the name of the person who wrote the message.

Chatterino plugins cannot add windows or settings pages, so everything is configured with the `/autoreply` chat command. Run `/autoreply help` for the full command list with explanations in Russian. Settings are stored in `data/config.json` inside the plugin folder.

## Use cases

- **Greet people who greet you.** Reply to a mention plus a greeting:
  ```
  /autoreply add mention + anyword "qq|hi|привет|приветствую" @{user} qq
  ```
- **Answer a chat command.** Reply to `!test`:
  ```
  /autoreply add keyword "!test" Test works!
  ```
- **Away mode.** Leave the app open and enable for a fixed time, so mentions get a "I'm away, back soon" reply:
  ```
  /autoreply add mention I'm away, will reply later
  /autoreply on 3h
  ```
- **Welcome first-time chatters.**
  ```
  /autoreply add flag first Welcome to the chat, @{user}!
  ```

Handy commands: `/autoreply status`, `/autoreply list`, `/autoreply off`.

## How to install (mac && windows)

1. **Get the plugin.** Download or clone this repository. The plugin is the `auto-reply` folder; it contains `info.json` and `init.lua`.
2. **Enable plugins in Leafyrino.** Open *Settings → Plugins* and tick **Enable plugins**.
3. **Open the Plugins folder.** Click the "Plugins directory" link on that settings page. If you prefer to find it yourself:
   - **macOS:** `~/Library/Application Support/<app folder>/Plugins` (for stock Chatterino the folder is `chatterino`; in Finder use *Go → Go to Folder…* and paste the path).
   - **Windows:** `%APPDATA%\<app folder>\Plugins` (press `Win + R`, paste the path, press Enter; for stock Chatterino the folder is `Chatterino`).

   The app folder name can differ between builds, so the link in Settings is the most reliable way.
4. **Copy the folder.** Put the whole `auto-reply` folder into `Plugins`. The result must be `Plugins/auto-reply/init.lua`, not a nested `auto-reply/auto-reply`.
5. **Enable and load it.** Back in *Settings → Plugins*, find **Auto Reply**, click **Enable** (or **Reload** if it was already there). Fix any error shown there before continuing.
6. **Set it up** in any chat:
   ```
   /autoreply channel add <channel>
   /autoreply add keyword "!test" Test works!
   /autoreply on 30m
   /autoreply status
   ```

To update, replace the `auto-reply` folder with the new version and click **Reload**. Your `data/config.json` is kept if you only overwrite the code files.

> Plugins can run arbitrary code. Install only plugins you trust, and read the source if you are unsure.
