# tele-nvim

Nested nvim sessions will instead open files in the parent session

Tested on nvim v0.11.5

## Features

- Mimics behavior of Vim's `--remote-wait`, `--remote-tab-wait` (somewhat)
- Automatically open files in parent session with no extra CLI flags (with
  [some setup](#automatically-open-files-in-parent-session))

## Non-goals

- Managing a "global" nvim session. tele-nvim uses the $NVIM environment
  variable and does not attempt to look for sessions anywhere else. In other
  words, tele-nvim will only work when calling nvim in a `:terminal` session by
  default. [neovim-remote] might fit your use case more if you want to share an
  nvim session across multiple terminals.

## Usage

You can use the `tele.try_attach_parent()` function or the `:TeleRemoteWait`
command to open files in the parent nvim session.

The following section presents a few common usages of tele-nvim.

<summary>
<details>

Explicitly opening files in parent session and wait for user exit (like vim
`--remote-wait`)

</details>

nvim +TeleRemoteWait file.txt

</summary>

<summary>
<details>Automatically open files in parent session</details>

## Automatically open files in parent session

Add this to the start of you init.lua:

```lua
-- This tries to open arguments supplied in the parent session
local attached_parent, err = require("tele").try_attach_parent()
if attached_parent then
    -- optional, skip the rest of your init.lua and plugins since you probably
    -- won't use them
    vim.o.loadplugins = false
    vim.o.shada = ''
    vim.o.swapfile = false
    return
elseif err ~= nil
    vim.notify(err, vim.log.levels.ERROR)
end
```

Now open `nvim file.txt` in a nested terminal session, the file will be opened
in the parent session instead. Close the window

</summary>

## Similar plugins

- [neovim-remote]: written in python and must be invoked manually with the `nvr`
  command.

[neovim-remote]: https://github.com/mhinz/neovim-remote
