# tele-nvim

Lua implementation of `--remote-wait` and friends.

## Features

- Mimics behavior of Vim's `--remote-wait`, `--remote-tab-wait`
- Automatically open files in parent session with
  `require('tele').try_attach_parent()`

## Similar plugins

- [neovim-remote](https://github.com/mhinz/neovim-remote): written in python and
  must be invoked manually with the `nvr` command.
