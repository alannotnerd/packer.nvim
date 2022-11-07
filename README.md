# 🚧 WIP 🚧

Fork that aims to de-scope and refactor

Aims:
- heavily refactor
- remove compilation
- port to Teal

# packer.nvim

[![Gitter](https://badges.gitter.im/packer-nvim/community.svg)](https://gitter.im/packer-nvim/community?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge)

[`use-package`](https://github.com/jwiegley/use-package) inspired plugin/package management for
Neovim.

Have questions? Start a [discussion](https://github.com/wbthomason/packer.nvim/discussions).

Have a problem or idea? Make an [issue](https://github.com/wbthomason/packer.nvim/issues) or a [PR](https://github.com/wbthomason/packer.nvim/pulls).

**Packer is built on native packages. You may wish to read `:h packages` before continuing**

## Table of Contents
1. [Notices](#notices)
2. [Features](#features)
3. [Requirements](#requirements)
4. [Quickstart](#quickstart)
5. [Bootstrapping](#bootstrapping)
6. [Usage](#usage)
    1. [The startup function](#the-startup-function)
    2. [Custom Initialization](#custom-initialization)
    3. [Specifying Plugins](#specifying-plugins)
    4. [Performing plugin management operations](#performing-plugin-management-operations)
    5. [Using a floating window](#using-a-floating-window)
8. [Debugging](#debugging)
9. [Status](#status)
10. [Contributors](#contributors)

## Features
- Declarative plugin specification
- Support for dependencies
- Expressive configuration and lazy-loading options
- Uses native packages
- Extensible
- Written in Lua, configured in Lua
- Post-install/update hooks
- Uses jobs for async installation
- Support for `git` tags, branches, revisions
- Support for local plugins

## Requirements
- **You need to be running Neovim v0.5.0+**; `packer` makes use of extmarks and other newly-added Neovim
  features.
- If you are on Windows 10, you need developer mode enabled in order to use local plugins (creating
  symbolic links requires admin privileges on Windows - credit to @TimUntersberger for this note)

## Quickstart
To get started, first clone this repository to somewhere on your `packpath`, e.g.:

> Unix, Linux Installation

```shell
git clone --depth 1 https://github.com/wbthomason/packer.nvim\
 ~/.local/share/nvim/site/pack/packer/start/packer.nvim
```

If you use Arch Linux, there is also [an AUR
package](https://aur.archlinux.org/packages/nvim-packer-git/).

> Windows Powershell Installation

```shell
git clone https://github.com/wbthomason/packer.nvim "$env:LOCALAPPDATA\nvim-data\site\pack\packer\start\packer.nvim"
```

Then you can write your plugin specification in Lua, e.g. (in `~/.config/nvim/lua/plugins.lua`):

```lua
-- This file can be loaded by calling `lua require('plugins')` from your init.vim

-- Only required if you have packer configured as `opt`
vim.cmd [[packadd packer.nvim]]

require('packer').startup(function(use)
  -- Packer can manage itself
  use 'wbthomason/packer.nvim'

  -- Simple plugins can be specified as strings
  use '9mm/vim-closer'

  -- Lazy loading:
  -- Load on specific commands
  use {'tpope/vim-dispatch', cmd = {'Dispatch', 'Make', 'Focus', 'Start'}}

  -- Load on an autocommand event
  use {'andymass/vim-matchup', event = 'VimEnter'}

  -- Load on a combination of conditions: specific filetypes or commands
  -- Also run code after load (see the "config" key)
  use {
    'w0rp/ale',
    ft = {'sh', 'zsh', 'bash', 'c', 'cpp', 'cmake', 'html', 'markdown', 'racket', 'vim', 'tex'},
    cmd = 'ALEEnable',
    config = 'vim.cmd[[ALEEnable]]'
  }

  -- Local plugins can be included
  use '~/projects/personal/hover.nvim'

  -- Plugins can have post-install/update hooks
  use {'iamcco/markdown-preview.nvim', run = 'cd app && yarn install', cmd = 'MarkdownPreview'}

  -- Post-install/update hook with neovim command
  use { 'nvim-treesitter/nvim-treesitter', run = ':TSUpdate' }

  -- Post-install/update hook with call of vimscript function with argument
  use { 'glacambre/firenvim', run = function() vim.fn['firenvim#install'](0) end }

  -- Use specific branch, dependency and run lua file after load
  use {
    'glepnir/galaxyline.nvim', branch = 'main', config = function() require'statusline' end,
    requires = {'kyazdani42/nvim-web-devicons'}
  }

  -- Use dependency and run lua function after load
  use {
    'lewis6991/gitsigns.nvim', requires = { 'nvim-lua/plenary.nvim' },
    config = function() require('gitsigns').setup() end
  }
end)
```

Note that if you get linter complaints about `use` being an undefined global, these errors are
spurious - `packer` injects `use` into the scope of the function passed to `startup`.
If these errors bother you, the easiest fix is to simply specify `use` as an argument to the
function you pass to `startup`, e.g.
```lua
packer.startup(function(use)
...your config...
end)
```

`packer` provides the following commands after you've run and configured `packer` with `require('packer').startup(...)`:

```
-- Remove any disabled or unused plugins
:PackerClean

-- Clean, then install missing plugins
:PackerInstall

-- Clean, then update and install plugins
-- supports the `--preview` flag as an optional first argument to preview updates
:PackerUpdate

-- Perform `PackerUpdate` and then `PackerCompile`
-- supports the `--preview` flag as an optional first argument to preview updates
:PackerSync

-- Loads opt plugin immediately
:PackerLoad completion-nvim ale
```

You can configure Neovim to automatically run `:PackerCompile` whenever `plugins.lua` is updated with
[an autocommand](https://neovim.io/doc/user/autocmd.html#:autocmd):

```
augroup packer_user_config
  autocmd!
  autocmd BufWritePost plugins.lua source <afile> | PackerCompile
augroup end
```

This autocommand can be placed in your `init.vim`, or any other startup file as per your setup.
Placing this in `plugins.lua` could look like this:

```lua
vim.cmd([[
  augroup packer_user_config
    autocmd!
    autocmd BufWritePost plugins.lua source <afile> | PackerCompile
  augroup end
]])
```

## Bootstrapping

If you want to automatically install and set up `packer.nvim` on any machine you clone your configuration to,
add the following snippet (which is due to @Iron-E and @khuedoan) somewhere in your config **before** your first usage of `packer`:

```lua
local ensure_packer = function()
  local fn = vim.fn
  local install_path = fn.stdpath('data')..'/site/pack/packer/start/packer.nvim'
  if fn.empty(fn.glob(install_path)) > 0 then
    fn.system({'git', 'clone', '--depth', '1', 'https://github.com/wbthomason/packer.nvim', install_path})
    vim.cmd [[packadd packer.nvim]]
    return true
  end
  return false
end

local packer_bootstrap = ensure_packer()

return require('packer').startup(function(use)
  use 'wbthomason/packer.nvim'
  -- My plugins here
  -- use 'foo1/bar1.nvim'
  -- use 'foo2/bar2.nvim'

  -- Automatically set up your configuration after cloning packer.nvim
  -- Put this at the end after all plugins
  if packer_bootstrap then
    require('packer').sync()
  end
end)
```

## Usage

The above snippets give some examples of `packer` features and use. Examples include:

- My dotfiles:
  - [Specification file](https://github.com/wbthomason/dotfiles/blob/linux/neovim/.config/nvim/lua/plugins.lua)
  - [Loading file](https://github.com/wbthomason/dotfiles/blob/linux/neovim/.config/nvim/lua/plugins.lua)
  - [Generated lazy-loader file](https://github.com/wbthomason/dotfiles/blob/linux/neovim/.config/nvim/plugin/packer_compiled.lua)
- An example using the `startup` method: [tjdevries](https://github.com/tjdevries/config_manager/blob/master/xdg_config/nvim/lua/tj/plugins.lua)
    - Using this method, you do not require a "loading" file. You can simply `lua require('plugins')` from your `init.vim`

The following is a more in-depth explanation of `packer`'s features and use.

### The `startup` function
`packer` provides `packer.startup(spec)`, which is used in the above examples.

`startup` is a convenience function for simple setup and can be invoked as follows:
- `spec` can be a function: `packer.startup(function() use 'tjdevries/colorbuddy.vim' end)`
- `spec` can be a table with a function as its first element and config overrides as another element:
  `packer.startup({function() use 'tjdevries/colorbuddy.vim' end, config = { ... }})`

### Custom Initialization
You are not required to use `packer.startup` if you prefer a more manual setup with finer control
over configuration and loading.

To take this approach, load `packer` like any other Lua module. You must call `packer.init()` before
performing any operations; it is recommended to call `packer.reset()` if you may be re-running your
specification code (e.g. by sourcing your plugin specification file with `luafile`).

You may pass a table of configuration values to `packer.init()` to customize its operation. The
default configuration values (and structure of the configuration table) are:
```lua
{
  ensure_dependencies   = true, -- Should packer install plugin dependencies?
  snapshot = nil, -- Name of the snapshot you would like to load at startup
  snapshot_path = join_paths(stdpath 'cache', 'packer.nvim'), -- Default save directory for snapshots
  package_root   = util.join_paths(vim.fn.stdpath('data'), 'site', 'pack'),
  compile_path = util.join_paths(vim.fn.stdpath('config'), 'plugin', 'packer_compiled.lua'),
  plugin_package = 'packer', -- The default package for plugins
  max_jobs = nil, -- Limit the number of simultaneous jobs. nil means no limit
  auto_clean = true, -- During sync(), remove unused plugins
  disable_commands = false, -- Disable creating commands
  transitive_opt = true, -- Make dependencies of opt plugins also opt by default
  transitive_disable = true, -- Automatically disable dependencies of disabled plugins
  auto_reload_compiled = true, -- Automatically reload the compiled file after creating it.
  preview_updates = false, -- If true, always preview updates before choosing which plugins to update, same as `PackerUpdate --preview`.
  git = {
    cmd = 'git', -- The base command for git operations
    subcommands = { -- Format strings for git subcommands
      update         = 'pull --ff-only --progress --rebase=false',
      install        = 'clone --depth %i --no-single-branch --progress',
      fetch          = 'fetch --depth 999999 --progress',
      checkout       = 'checkout %s --',
      update_branch  = 'merge --ff-only @{u}',
      current_branch = 'branch --show-current',
      diff           = 'log --color=never --pretty=format:FMT --no-show-signature HEAD@{1}...HEAD',
      diff_fmt       = '%%h %%s (%%cr)',
      get_rev        = 'rev-parse --short HEAD',
      get_msg        = 'log --color=never --pretty=format:FMT --no-show-signature HEAD -n 1',
    },
    depth = 1, -- Git clone depth
    clone_timeout = 60, -- Timeout, in seconds, for git clones
    default_url_format = 'https://github.com/%s' -- Lua format string used for "aaa/bbb" style plugins
  },
  display = {
    non_interactive = false, -- If true, disable display windows for all operations
    compact = false, -- If true, fold updates results by default
    open_fn  = nil, -- An optional function to open a window for packer's display
    open_cmd = '65vnew \\[packer\\]', -- An optional command to open a window for packer's display
    working_sym = '⟳', -- The symbol for a plugin being installed/updated
    error_sym = '✗', -- The symbol for a plugin with an error in installation/updating
    done_sym = '✓', -- The symbol for a plugin which has completed installation/updating
    removed_sym = '-', -- The symbol for an unused plugin which was removed
    moved_sym = '→', -- The symbol for a plugin which was moved (e.g. from opt to start)
    header_sym = '━', -- The symbol for the header line in packer's display
    show_all_info = true, -- Should packer show all update details automatically?
    prompt_border = 'double', -- Border style of prompt popups.
    keybindings = { -- Keybindings for the display window
      quit = 'q',
      toggle_update = 'u', -- only in preview
      continue = 'c', -- only in preview
      toggle_info = '<CR>',
      diff = 'd',
      prompt_revert = 'r',
    }
  },
  log = { level = 'warn' }, -- The default print log level. One of: "trace", "debug", "info", "warn", "error", "fatal".
  autoremove = false, -- Remove disabled or unused plugins without prompting the user
}
```

### Specifying plugins

`packer` is based around declarative specification of plugins. You can declare a plugin using the
function `packer.use`, which I highly recommend locally binding to `use` for conciseness.

`use` takes either a string or a table. If a string is provided, it is treated as a plugin location
for a non-optional plugin with no additional configuration. Plugin locations may be specified as

1. Absolute paths to a local plugin
2. Full URLs (treated as plugins managed with `git`)
3. `username/repo` paths (treated as Github `git` plugins)

A table given to `use` can take two forms:

1. A list of plugin specifications (strings or tables)
2. A table specifying a single plugin. It must have a plugin location string as its first element,
   and may additionally have a number of optional keyword elements, shown below:
```lua
use {
  'myusername/example',        -- The plugin location string
  -- The following keys are all optional
  disable = boolean,           -- Mark a plugin as inactive
  updater = function,          -- Specifies custom updater. See "custom installers" below.
  branch = string,             -- Specifies a git branch to use
  tag = string,                -- Specifies a git tag to use. Supports '*' for "latest tag"
  commit = string,             -- Specifies a git commit to use
  lock = boolean,              -- Skip updating this plugin in updates/syncs. Still cleans.
  run = string, function, or table, -- Post-update/install hook. See "update/install hooks".
  requires = string or list,   -- Specifies plugin dependencies. See "dependencies".
  config = string or function, -- Specifies code to run after this plugin is loaded.
  -- The following keys all imply lazy-loading and imply opt = true
  cmd = string or list,        -- Specifies commands which load this plugin. Can be an autocmd pattern.
  ft = string or list,         -- Specifies filetypes which load this plugin.
  keys = string or list,       -- Specifies maps which load this plugin. See "Keybindings".
  event = string or list,      -- Specifies autocommand events which load this plugin.
}
```

For the `cmd` option, the command may be a full command, or an autocommand pattern. If the command contains any
non-alphanumeric characters, it is assumed to be a pattern, and instead of creating a stub command, it creates
a CmdUndefined autocmd to load the plugin when a command that matches the pattern is invoked.

#### Checking plugin statuses
You can check whether or not a particular plugin is installed with `packer` as well as if that plugin is loaded.
To do this you can check for the plugin's name in the `packer_plugins` global table.
Plugins in this table are saved using only the last section of their names
e.g. `tpope/vim-fugitive` if installed will be under the key `vim-fugitive`.

```lua
if packer_plugins["vim-fugitive"] and packer_plugins["vim-fugitive"].loaded then
print("Vim fugitive is loaded")
-- other custom logic
end
```
**NOTE:** this table is only available *after* `packer_compiled.vim` is loaded so cannot be used till *after* plugins
have been loaded.

#### Custom installers

You may specify a custom installer & updater for a plugin using the `installer` and `updater` keys.
Note that either both or none of these keys are required. These keys should be functions which take
as an argument a `display` object (from `lua/packer/display.lua`) and return an async function (per
`lua/packer/async.lua`) which (respectively) installs/updates the given plugin.

Providing the `installer`/`updater` keys overrides plugin type detection, but you still need to
provide a location string for the name of the plugin.

#### Update/install hooks

You may specify operations to be run after successful installs/updates of a plugin with the `run`
key. This key may either be a Lua function, which will be called with the `plugin` table for this
plugin (containing the information passed to `use` as well as output from the installation/update
commands, the installation path of the plugin, etc.), a string, or a table of functions and strings.

If an element of `run` is a string, then either:

1. If the first character of `run` is ":", it is treated as a Neovim command and executed.
2. Otherwise, `run` is treated as a shell command and run in the installation directory of the
   plugin via `$SHELL -c '<run>'`.

#### Dependencies

Plugins may specify dependencies via the `requires` key. This key can be a string or a list (table).

If `requires` is a string, it is treated as specifying a single plugin. If a plugin with the name
given in `requires` is already known in the managed set, nothing happens. Otherwise, the string is
treated as a plugin location string and the corresponding plugin is added to the managed set.

If `requires` is a list, it is treated as a list of plugin specifications following the format given
above.

If `ensure_dependencies` is true, the plugins specified in `requires` will be installed.

Plugins specified in `requires` are removed when no active plugins require them.

#### Keybindings

Plugins may be lazy-loaded on the use of keybindings/maps. Individual keybindings are specified either as a string (in which case they are treated as normal mode maps) or a table in the format `{mode, map}`.

### Performing plugin management operations
`packer` exposes the following functions for common plugin management operations. In all of the
below, `plugins` is an optional table of plugin names; if not provided, the default is "all managed
plugins":

- `packer.install(plugins)`: Install the specified plugins if they are not already installed
- `packer.update(plugins)`: Update the specified plugins, installing any that are missing
- `packer.update(opts, plugins)`: First argument can be a table specifying options, such as `{preview_updates = true}` to preview potential changes before updating (same as `PackerUpdate --preview`).
- `packer.clean()`: Remove any disabled or no longer managed plugins
- `packer.sync(plugins)`: Perform a `clean` followed by an `update`.
- `packer.sync(opts, plugins)`: Can take same optional options as `update`.
- `packer.snapshot(snapshot_name, ...)`: Creates a snapshot file that will live under `config.snapshot_path/<snapshot_name>`. If `snapshot_name` is an absolute path, then that will be the location where the snapshot will be taken. Optionally, a list of plugins name can be provided to selectively choose the plugins to snapshot.
- `packer.rollback(snapshot_name, ...)`: Rollback plugins status a snapshot file that will live under `config.snapshot_path/<snapshot_name>`. If `snapshot_name` is an absolute path, then that will be the location where the snapshot will be taken. Optionally, a list of plugins name can be provided to selectively choose which plugins to revert.
- `packer.delete(snapshot_name)`: Deletes a snapshot file under `config.snapshot_path/<snapshot_name>`. If `snapshot_name` is an absolute path, then that will be the location where the snapshot will be deleted.

### Using a floating window
You can configure Packer to use a floating window for command outputs by passing a utility
function to `packer`'s config:
```lua
packer.startup({function()
  -- Your plugins here
end,
config = {
  display = {
    open_fn = require('packer.util').float,
  }
}})
```

By default, this floating window will show doubled borders. If you want to customize the window
appearance, you can pass a configuration to `float`, which is the same configuration that would be
passed to `nvim_open_win`:
```lua
packer.startup({function()
  -- Your plugins here
end,
config = {
  display = {
    open_fn = function()
      return require('packer.util').float({ border = 'single' })
    end
  }
}})
```

## Debugging
`packer.nvim` logs to `stdpath(cache)/packer.nvim.log`. Looking at this file is usually a good start
if something isn't working as expected.

## Status
**tl;dr**: Beta. Things seem to work and most features are complete, but certainly not every edge
case has been tested. People willing to give it a try and report bugs/errors are very welcome!

- Basic package management works (i.e. installation, updating, cleaning, start/opt plugins,
  displaying results)
- Automatic generation of lazy-loading code works
- More testing is needed
- The code is messy and needs more cleanup and refactoring

## Contributors
Many thanks to those who have contributed to the project! PRs and issues are always welcome. This
list is infrequently updated; please feel free to bug me if you're not listed here and you would
like to be.

- @akinsho
- @nanotee
- @weilbith
- @Iron-E
- @tjdevries
- @numToStr
- @fsouza
- @gbrlsnchs
- @lewis6991
- @TimUntersberger
- @bfredl
- @sunjon
- @gwerbin
- @shadmansaleh
- @ur4ltz
- @EdenEast
- @khuedoan
