local util = require('packer.util')
local result = require('packer.result')
local a = require('packer.async')
local log = require('packer.log')
local plugin_utils = require('packer.plugin_utils')
local Display = require('packer.display').Display

local fmt = string.format
local async = a.sync

local config = require('packer.config')

local function move_plugin(plugin, moves, fs_state)
   local from
   local to
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



   local success, msg = os.rename(from, to)
   if not success then
      log.error(fmt('Failed to move %s to %s: %s', from, to, msg))
      moves[plugin.name] = result.err({ from = from, to = to })
   else
      log.debug(fmt('Moved %s from %s to %s', plugin.name, from, to))
      moves[plugin.name] = result.ok({ from = from, to = to })
   end
end

local update_plugin = async(function(plugin, disp, updates, opts)
   local plugin_name = plugin.full_name
   disp:task_start(plugin_name, 'updating...')

   if plugin.lock then
      disp:task_succeeded(plugin_name, 'locked')
      return
   end

   local plugin_type = require('packer.plugin_types')[plugin.type]

   local err = plugin_type.updater(plugin, disp, opts)
   local msg = 'up to date'
   if not err and plugin.type == 'git' then
      local revs = plugin.revs
      local actual_update = revs[1] ~= revs[2]
      if actual_update then
         msg = fmt('updated: %s...%s', revs[1], revs[2])
         if not opts.preview_updates then
            log.debug(fmt('Updated %s', plugin_name))
            err = plugin_utils.post_update_hook(plugin, disp)
         end
      else
         msg = 'already up to date'
      end
   end

   if not err then
      disp:task_succeeded(plugin_name, msg)
   else
      disp:task_failed(plugin_name, 'failed to update')
      log.debug(fmt('Failed to update %s: %s', plugin_name, plugin.err))
   end

   updates[plugin_name] = err and { err = err } or {}
   return plugin_name, err
end, 4)

local M = {}

function M.update(
   plugins,
   update_plugins,
   disp,
   updates,
   opts)

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
      log.info('Nothing to update!')
   end

   return tasks
end

function M.fix_plugin_types(
   plugins,
   plugin_names,
   moves,
   fs_state)

   log.debug('Fixing plugin types')

   for _, v in ipairs(plugin_names) do
      local plugin = plugins[v]
      local wrong_install_dir = util.join_paths(plugin.opt and config.start_dir or config.opt_dir, plugin.name)
      if vim.loop.fs_stat(wrong_install_dir) then
         move_plugin(plugin, moves, fs_state)
      end
   end
   log.debug('Done fixing plugin types')
end

return M