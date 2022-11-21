local api = vim.api
local fn = vim.fn

local config = require 'packer.config'
local log    = require 'packer.log'

local plugins: {string:Plugin} = {}

local M = {}

local function apply_config(plugin: Plugin)
  if plugin.config and plugin.loaded then
    local c = plugin.config
    if c is function() then
      c()
    else
      loadstring(c, plugin.name..'.config()')()
    end
  end
end

local function loader(lplugins: {Plugin})
  for _, plugin in ipairs(lplugins) do
    if not plugin.loaded then
      -- Set the plugin as loaded before config is run in case something in the
      -- config tries to load this same plugin again
      plugin.loaded = true
      vim.cmd.packadd(plugin.name)
      apply_config(plugin)
    end
  end
end

-- Completion user plugins
-- Intended to provide completion for PackerUpdate/Sync/Install command
function M.plugin_complete(lead: string, _:string): {string}
  local completion_list = vim.tbl_filter(function(name: string): boolean
    return vim.startswith(name, lead)
  end, vim.tbl_keys(_G.packer_plugins))
  table.sort(completion_list)
  return completion_list
end

local function load_plugin_configs()
  local cond_plugins: {string:{string:Plugin}} = {
    cmd   = {},
    keys  = {},
    ft    = {},
    event = {},
  }

  local uncond_plugins = {}

  for name, plugin in pairs(plugins) do
    local has_cond = false
    for _, cond in ipairs{'cmd', 'keys', 'ft', 'event'} do
      if (plugin as {string:any})[cond] then
        has_cond = true
        cond_plugins[cond][name] = plugin
        break
      end
    end
    if not has_cond then
      uncond_plugins[name] = plugin
    end
  end

  _G.packer_plugins = plugins

  for _, plugin in pairs(uncond_plugins) do
    apply_config(plugin)
  end

  for _, cond in ipairs{'cmd', 'keys', 'ft', 'event'} do
    if next(cond_plugins[cond]) then
      require('packer.handlers')(cond, cond_plugins[cond], loader)
    end
  end
end

local function do_snapshot(k: string): function
  return function(arglead: string, cmdline: string): {string}
    (require('packer.snapshot') as {string:function})[k](arglead, cmdline)
  end
end

local function do_snapshot_cmpl(k: string): function(string, string): {string}
  return function(arglead: string, cmdline: string): {string}
    (require('packer.snapshot').completion as {string:function})[k](arglead, cmdline)
  end
end

local function do_install()
  require'packer.actions'.install()
end

local function do_update(first: string|table, ...:string)
  require'packer.actions'.update(first, ...)
end

local function do_clean()
  require'packer.actions'.clean()
end

local function do_status()
  require'packer.actions'.status()
end

local function make_commands()
  for _, cmd in ipairs {
    { 'PackerSnapshot'         , '+', do_snapshot('create')  , do_snapshot_cmpl('create')   },
    { 'PackerSnapshotRollback' , '+', do_snapshot('rollback'), do_snapshot_cmpl('rollback') },
    { 'PackerSnapshotDelete'   , '+', do_snapshot('delete')  , do_snapshot_cmpl('snapshot') },
    { 'PackerInstall'          , '*', do_install   , M.plugin_complete },
    { 'PackerUpdate'           , '*', do_update    , M.plugin_complete },
    { 'PackerClean'            , '*', do_clean },
    { 'PackerStatus'           , '*', do_status },
  } do
    api.nvim_create_user_command(cmd[1], function(args: vim.api.UserCmdParams)
      cmd[3](unpack(args.fargs))
    end, { nargs = cmd[2], complete = cmd[4] })
  end
end

local record SSpec
  {Plugin}

  config: Config
end

-- Convenience function for simple setup
-- spec can be a table with a table of plugin specifications as its first
-- element, config overrides as another element.
function M.startup(spec: SSpec)
  assert(type(spec) == 'table')
  assert(type(spec[1]) == 'table')

  plugins = {}

  config(spec.config)

  for _, dir in ipairs{config.opt_dir, config.start_dir} do
    if fn.isdirectory(dir) == 0 then
      fn.mkdir(dir, 'p')
    end
  end

  make_commands()

  if fn.mkdir(config.snapshot_path, 'p') ~= 1 then
    log.warn("Couldn't create " .. config.snapshot_path)
  end

  -- process_plugin_spec{
  plugins = require 'packer.plugin'.process_spec{
    spec = spec[1],
    line = debug.getinfo(2, 'l').currentline,
  }

  load_plugin_configs()

  if config.snapshot then
    require'packer.actions'.rollback(config.snapshot)
  end
end

return M
