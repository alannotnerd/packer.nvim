local util = require 'packer.util'
local result = require 'packer.result'
local a = require 'packer.async'
local log = require 'packer.log'
local plugin_utils = require 'packer.plugin_utils'

local fmt = string.format
local async = a.sync

local config = require('packer.config')

local function move_plugin(plugin: Plugin, moves: {string:Result<PluginResult>}, fs_state: plugin_utils.FSState)
  local from: string
  local to: string
  if plugin.opt then
    from = util.join_paths(config.start_dir, plugin.name)
    to = util.join_paths(config.opt_dir, plugin.name)
  else
    from = util.join_paths(config.opt_dir, plugin.name)
    to = util.join_paths(config.start_dir, plugin.name)
  end

  fs_state.start[to] = true
  fs_state.opt[from] = nil
  fs_state.missing[plugin.name] = nil

  -- NOTE: If we stored all plugins somewhere off-package-path and used symlinks to put them in the
  -- right directories, this could be lighter-weight
  local success, msg = os.rename(from, to)
  if not success then
    log.error(fmt('Failed to move %s to %s: %s', from, to, msg))
    moves[plugin.name] = result.err({from = from, to = to} as PluginResult)
  else
    log.debug(fmt('Moved %s from %s to %s', plugin.name, from, to))
    moves[plugin.name] = result.ok({from = from, to = to} as PluginResult)
  end
end

local update_plugin = async(function(plugin: Plugin, disp: Display, updates: {string:Result<PluginResult>}, opts: table): string, Result<PluginResult>
  local plugin_name = plugin.full_name
  disp:task_start(plugin_name, 'updating...')

  if plugin.lock then
    disp:task_succeeded(plugin_name, 'locked')
    return
  end

  local plugin_type = require'packer.plugin_types'[plugin.type]

  local r = plugin_type.updater(plugin, disp, opts)
  local msg = 'up to date'
  if r.ok and plugin.type == 'git' then
    local revs = plugin.revs
    local actual_update = revs[1] ~= revs[2]
    if actual_update then
      msg = fmt('updated: %s...%s', revs[1], revs[2])
      if not opts.preview_updates then
        log.debug(fmt('Updated %s: %s', plugin_name, vim.inspect(r)))
        r = plugin_utils.post_update_hook(plugin, disp)
      end
    else
      msg = 'already up to date'
    end
  end

  if r.ok then
    disp:task_succeeded(plugin_name, msg)
  else
    disp:task_failed(plugin_name, 'failed to update')
    local errmsg = '<unknown error>'
    if r ~= nil and r.err ~= nil then
      errmsg = vim.inspect(r.err)
    end
    log.debug(fmt('Failed to update %s: %s', plugin_name, errmsg))
  end

  updates[plugin_name] = r
  return plugin_name, r
end, 4)

local M = {}

function M.update(
  plugins: {string:Plugin},
  update_plugins: {string},
  disp: Display,
  updates: {string:Result<PluginResult>},
  opts: table
): {a.Thunk}
  local tasks = {}
  for _, v in ipairs(update_plugins) do
    local plugin = plugins[v]
    if plugin == nil then
      log.error(fmt('Unknown plugin: %s', v))
    end
    if plugin and not plugin.lock then
      table.insert(tasks, a.curry(update_plugin, plugin, disp, updates, opts))
    end
  end

  if #tasks == 0 then
    log.info 'Nothing to update!'
  end

  return tasks
end

function M.fix_plugin_types(
  plugins: {string:Plugin},
  plugin_names: {string},
  moves: {string:Result<PluginResult>},
  fs_state: plugin_utils.FSState
)
  log.debug 'Fixing plugin types'
  -- NOTE: This function can only be run on plugins already installed
  for _, v in ipairs(plugin_names) do
    local plugin = plugins[v]
    local wrong_install_dir = util.join_paths(plugin.opt and config.start_dir or config.opt_dir, plugin.name)
    if vim.loop.fs_stat(wrong_install_dir) then
      move_plugin(plugin, moves, fs_state)
    end
  end
  log.debug 'Done fixing plugin types'
end

return M
