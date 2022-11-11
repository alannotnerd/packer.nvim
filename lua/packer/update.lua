local util = require 'packer.util'
local result = require 'packer.result'
local display = require 'packer.display'
local a = require 'packer.async'
local log = require 'packer.log'
local plugin_utils = require 'packer.plugin_utils'

local fmt = string.format
local async = a.sync

local config = require('packer.config')

local function fix_plugin_type(plugin, results, fs_state)
  local from
  local to
  if plugin.opt then
    from = util.join_paths(config.start_dir, plugin.short_name)
    to = util.join_paths(config.opt_dir, plugin.short_name)
    fs_state.opt[to] = true
    fs_state.start[from] = nil
    fs_state.missing[plugin.short_name] = nil
  else
    from = util.join_paths(config.opt_dir, plugin.short_name)
    to = util.join_paths(config.start_dir, plugin.short_name)
    fs_state.start[to] = true
    fs_state.opt[from] = nil
    fs_state.missing[plugin.short_name] = nil
  end

  -- NOTE: If we stored all plugins somewhere off-package-path and used symlinks to put them in the
  -- right directories, this could be lighter-weight
  local success, msg = os.rename(from, to)
  if not success then
    log.error(fmt('Failed to move %s to %s: %s', from, to, msg))
    results.moves[plugin.short_name] = { from = from, to = to, result = result.err(success) }
  else
    log.debug(fmt('Moved %s from %s to %s', plugin.short_name, from, to))
    results.moves[plugin.short_name] = { from = from, to = to, result = result.ok(success) }
  end
end

---@async
---@param plugin PluginSpec
---@param display_win Display
---@param results Results
---@param opts table
local update_plugin = async(function(plugin, display_win, results, opts)
  local plugin_name = plugin.full_name
  -- TODO: This will have to change when separate packages are implemented
  local install_path = util.join_paths(config.pack_dir, plugin.opt and 'opt' or 'start', plugin.short_name)
  plugin.install_path = install_path
  if plugin.lock then
    return
  end
  display_win:task_start(plugin_name, 'updating...')
  local r = plugin.updater(display_win, opts)
  if r.ok then
    local msg = 'up to date'
    if plugin.type == 'git' then
      local info = r.info
      local actual_update = info.revs[1] ~= info.revs[2]
      msg = actual_update and fmt('updated: %s...%s', info.revs[1], info.revs[2]) or 'already up to date'
      if actual_update and not opts.preview_updates then
        log.debug(fmt('Updated %s: %s', plugin_name, vim.inspect(info)))
        r = plugin_utils.post_update_hook(plugin, display_win)
      end
    end

    if r.ok then
      display_win:task_succeeded(plugin_name, msg)
    end
  else
    display_win:task_failed(plugin_name, 'failed to update')
    local errmsg = '<unknown error>'
    if r ~= nil and r.err ~= nil then
      errmsg = r.err
    end
    log.debug(fmt('Failed to update %s: %s', plugin_name, vim.inspect(errmsg)))
  end

  results.updates[plugin_name] = r
  results.plugins[plugin_name] = plugin
end, 4)

local M = {}

---@param plugins { [string]: PluginSpec }
---@param update_plugins string[]
---@param display_win? Display
---@param results Results
---@param opts { pull_head: boolean, preview_updates: boolean}
function M.update(plugins, update_plugins, display_win, results, opts)
  results = results or {}
  results.updates = results.updates or {}
  results.plugins = results.plugins or {}
  local tasks = {}
  for _, v in ipairs(update_plugins) do
    local plugin = plugins[v]
    if plugin == nil then
      log.error(fmt('Unknown plugin: %s', v))
    end
    if plugin and not plugin.lock then
      if not display_win then
        display_win = display.open(config.display.open_fn or config.display.open_cmd)
      end

      table.insert(tasks, a.curry(update_plugin, plugin, display_win, results, opts))
    end
  end

  if #tasks == 0 then
    log.info 'Nothing to update!'
  end

  return tasks, display_win
end

function M.fix_plugin_types(plugins, plugin_names, results, fs_state)
  log.debug 'Fixing plugin types'
  results = results or {}
  results.moves = results.moves or {}
  -- NOTE: This function can only be run on plugins already installed
  for _, v in ipairs(plugin_names) do
    local plugin = plugins[v]
    local install_dir = util.join_paths(plugin.opt and config.start_dir or config.opt_dir, plugin.short_name)
    if vim.loop.fs_stat(install_dir) ~= nil then
      fix_plugin_type(plugin, results, fs_state)
    end
  end
  log.debug 'Done fixing plugin types'
end

return M
