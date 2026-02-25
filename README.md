# Lazy.spoon

A plugin manager for [Hammerspoon](https://www.hammerspoon.org/), inspired by [lazy.nvim](https://github.com/folke/lazy.nvim).

## Features

- **Declarative config** — define your spoons in a simple list
- **Auto-install** — installs missing spoons from GitHub repos or ZIP downloads
- **Parallel installs** — all missing spoons are fetched concurrently
- **Lifecycle management** — runs `config` then `start` on each spoon automatically

## Installation

Add the following bootstrap snippet to `~/.hammerspoon/init.lua`:

```lua
-- Bootstrap Lazy.spoon
local lazyDir = hs.configdir .. "/Spoons/Lazy.spoon"
if not hs.fs.attributes(lazyDir) then
  hs.execute("git clone https://github.com/forked4x/Lazy.spoon " .. lazyDir)
end
hs.loadSpoon("Lazy")
```

## Usage

```lua
spoon.Lazy:setup({
  -- GitHub shorthand (clones the repo)
  { "jasonrudolph/ControlEscape.spoon" },

  -- ZIP download from a GitHub release
  { "user/Repo.spoon/releases/download/latest/Name.spoon.zip" },

  { "forked4x/Caffeine.spoon",
    -- Configure spoon
    config = function(spoon)
      spoon:bindHotkeys({
        toggle = {{"cmd", "alt", "ctrl"}, "C"}
      })
    end,
    -- Disable calling :start()
    start = false,
  },
})
```

## Keys

The optional `keys` field declares global key remappings and hotkey bindings via an always-active `hs.hotkey.modal`.

```lua
spoon.Lazy:setup({
  -- Spoon specs...
  keys = {
    -- Vim keybinds
    [{ "cmd", "h" }] = { "", "left",        { repeat_ = true, shift = true } },
    [{ "cmd", "j" }] = { "", "down",        { repeat_ = true, shift = true } },
    [{ "cmd", "k" }] = { "", "up",          { repeat_ = true, shift = true } },
    [{ "cmd", "l" }] = { "", "right",       { repeat_ = true, shift = true } },
    [{ "cmd", "b" }] = { "alt", "left",     { repeat_ = true, shift = true } },
    [{ "cmd", "e" }] = { "alt", "right",    { repeat_ = true, shift = true } },
    [{ "cmd", "d" }] = { "alt", "pagedown", { repeat_ = true, shift = true } },
    [{ "cmd", "u" }] = { "alt", "pageup",   { repeat_ = true, shift = true } },
    [{ "alt", "h" }] = { "cmd", "left",     { shift = true } },
    [{ "alt", "j" }] = { "cmd", "down",     { shift = true } },
    [{ "alt", "k" }] = { "cmd", "up",       { shift = true } },
    [{ "alt", "l" }] = { "cmd", "right",    { shift = true } },

    -- Toggle macOS dark mode
    [{ "ctrl,cmd", "n" }] = function()
      hs.osascript.applescript(
        [[tell application "System Events" to tell appearance preferences to set dark mode to ]]
        .. tostring(hs.host.interfaceStyle() ~= "Dark")
      )
    end,

    -- Reload Hammerspoon
    [{ "ctrl,cmd", "r" }] = hs.reload,

    -- App-specific keybinds (noremap avoids global remap interception)
    Things = {
      [{ "cmd", "return" }] = { "cmd",     "k", { noremap = true } },
      [{ "cmd", "delete" }] = { "alt,cmd", "k", { noremap = true } },
    },
  },
})
```

### Mods format

Mods can be a comma-separated string (`"ctrl,cmd"`) or a table (`{ "ctrl", "cmd" }`). An empty string `""` means no modifiers.

### Opts

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `repeat_` | `boolean` | `false` | Fire continuously while held (`_` suffix avoids Lua reserved word) |
| `shift` | `boolean` | `false` | Auto-create a shift variant (shift added to both lhs and rhs mods) |
| `noremap` | `boolean` | `false` | Exit all hotkey modals before sending the keystroke, then re-enter them after — prevents global remaps from intercepting the emitted key |

## LazySpec Reference

Each entry in the `setup` list is a **LazySpec** table:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `[1]` | `string` | *(required)* | Source — GitHub shorthand (`"user/Name.spoon"`), release ZIP path, or full URL |
| `config` | `function(spoon)` | `nil` | Called with the loaded spoon object before start |
| `start` | `boolean` | `true` | Whether to call `spoon:start()` after config |

## License

MIT
