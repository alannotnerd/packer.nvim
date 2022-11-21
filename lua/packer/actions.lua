local fn = vim.fn
local fmt = string.format

local a = require('packer.async')
local config = require('packer.config')
local log = require('packer.log')
local util = require('packer.util')
local plugin_utils = require('packer.plugin_utils')

local display = require('packer.display')

local Display = display.Display

local M = {}








local function open_display()
   return display.display.open({
      diff = function(plugin, commit, callback)
         local plugin_type = require('packer.plugin_types')[plugin.type]
         return plugin_type.diff(plugin, commit, callback)
      end,
      revert_last = function(plugin)
         local plugin_type = require('packer.plugin_types')[plugin.type]
         plugin_type.revert_last(plugin)
      end,
      update = M.update,
      install = M.install,
   })
end

local function run_tasks(tasks, disp)
   if #tasks == 0 then
      print('Nothing to do')
      log.info('Nothing to do!')
      return
   end

   local function check()
      return not disp.running
   end

   local limit = config.max_jobs and config.max_jobs or #tasks

   log.debug('Running tasks')
   disp:update_headline_message(string.format('updating %d / %d plugins', #tasks, #tasks))
   return a.join(limit, check, tasks)
end

local function measure(f)
   local start_time = vim.loop.hrtime()
   f()
   return (vim.loop.hrtime() - start_time) / 1e9
end

local function helptags_stale(dir)
   local glob = fn.glob


   local txts = glob(util.join_paths(dir, '*.txt'), true, true)
   vim.list_extend(txts, fn.glob(util.join_paths(dir, '*.[a-z][a-z]x'), true, true))

   if #txts == 0 then
      return false
   end

   local tags = glob(util.join_paths(dir, 'tags'), true, true)
   vim.list_extend(tags, glob(util.join_paths(dir, 'tags-[a-z][a-z]'), true, true))

   if #tags == 0 then
      return true
   end

   local txt_newest = math.max(unpack(vim.tbl_map(fn.getftime, txts)))
   local tag_oldest = math.min(unpack(vim.tbl_map(fn.getftime, tags)))
   return txt_newest > tag_oldest
end

local function update_helptags(results)
   local paths = {}
   for plugin_name, r in pairs(results) do
      if not r.err then
         paths[#paths + 1] = _G.packer_plugins[plugin_name].install_path
      end
   end

   for _, dir in ipairs(paths) do
      local doc_dir = util.join_paths(dir, 'doc')
      if helptags_stale(doc_dir) then
         log.info('Updating helptags for ' .. doc_dir)
         vim.cmd('silent! helptags ' .. fn.fnameescape(doc_dir))
      end
   end
end

local install_plugin = a.sync(function(
   plugin,
   disp,
   installs)

   disp:task_start(plugin.full_name, 'installing...')

   local plugin_type = require('packer.plugin_types')[plugin.type]

   local err = plugin_type.installer(plugin, disp)

   if not err then
      err = plugin_utils.post_update_hook(plugin, disp)
   end

   if not err then
      disp:task_succeeded(plugin.full_name, 'installed')
      log.debug(fmt('Installed %s', plugin.full_name))
   else
      disp:task_failed(plugin.full_name, 'failed to install')
      log.debug(fmt('Failed to install %s: %s', plugin.full_name, vim.inspect(err)))
   end

   installs[plugin.name] = err and { err = err } or {}
   return err
end, 3)

local function install(
   plugins,
   missing_plugins,
   disp,
   installs)

   if #missing_plugins == 0 then
      return {}
   end

   local tasks = {}
   for _, v in ipairs(missing_plugins) do
      table.insert(tasks, a.curry(install_plugin, plugins[v], disp, installs))
   end

   return tasks
end



M.install = a.sync(function()
   log.debug('packer.install: requiring modules')

   local fs_state = plugin_utils.get_fs_state(_G.packer_plugins)
   local install_plugins = vim.tbl_keys(fs_state.missing)
   if #install_plugins == 0 then
      log.info('All configured plugins are installed')
      return
   end

   a.main()

   log.debug('Gathering install tasks')

   local disp = open_display()
   local installs = {}

   local delta = measure(function()
      local install_tasks = install(_G.packer_plugins, install_plugins, disp, installs)
      run_tasks(install_tasks, disp)

      a.main()
      update_helptags(installs)
   end)

   disp:final_results({ installs = installs }, delta)
end)

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
      moves[plugin.name] = { from = from, to = to }
   else
      log.debug(fmt('Moved %s from %s to %s', plugin.name, from, to))
      moves[plugin.name] = { from = from, to = to }
   end
end

local update_plugin = a.sync(function(plugin, disp, updates, opts)
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

local function update(
   plugins,
   update_plugins,
   disp,
   updates,
   opts)

   local tasks = {}
   for _, v in ipairs(update_plugins) do
      local plugin = plugins[v]
      if not plugin then
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

local function fix_plugin_types(
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



local function filter_opts_from_plugins(first, ...)
   local args = { ... }
   local opts = {}
   if not vim.tbl_isempty(args) then
      if type(first) == "table" then
         table.remove(args, 1)
         opts = first
      elseif first == '--preview' then
         table.remove(args, 1)
         opts = { preview_updates = true }
      end
   end
   if config.preview_updates then
      opts.preview_updates = true
   end
   return opts, #args > 0 and args or vim.tbl_keys(_G.packer_plugins)
end














M.update = a.void(function(first, ...)
   local plugins = _G.packer_plugins
   local opts, update_plugins = filter_opts_from_plugins(first, ...)
   local fs_state = plugin_utils.get_fs_state(plugins)
   local missing_plugins, installed_plugins = util.partition(vim.tbl_keys(fs_state.missing), update_plugins)

   local results = {
      moves = {},
      removals = {},
      installs = {},
      updates = {},
   }

   fix_plugin_types(plugins, missing_plugins, results.moves, fs_state)
   require('packer.clean')(plugins, fs_state, results.removals)

   missing_plugins = ({ util.partition(vim.tbl_keys(results.moves), missing_plugins) })[2]

   a.main()

   local disp = open_display()

   local delta = measure(function()
      local tasks = {}

      log.debug('Gathering install tasks')
      local install_tasks = install(plugins, missing_plugins, disp, results.installs)
      vim.list_extend(tasks, install_tasks)

      log.debug('Gathering update tasks')
      a.main()

      local update_tasks = update(plugins, installed_plugins, disp, results.updates, opts)
      vim.list_extend(tasks, update_tasks)

      run_tasks(tasks, disp)

      a.main()
      update_helptags(vim.tbl_extend('error', results.installs, results.updates))
   end)

   disp:final_results(results, delta)
end)

M.status = a.sync(function()
   if _G.packer_plugins == nil then
      log.warn('packer_plugins table is nil! Cannot run packer.status()!')
      return
   end

   open_display():set_status(_G.packer_plugins)
end)



M.clean = a.void(function()
   require('packer.clean')(_G.packer_plugins)
end)


M.snapshot = a.void(function(snapshot_name, ...)
   local args = { ... }
   snapshot_name = snapshot_name or require('os').date('%Y-%m-%d')
   local snapshot_path = fn.expand(snapshot_name)

   log.debug(fmt('Taking snapshots of currently installed plugins to %s...', snapshot_name))
   if fn.fnamemodify(snapshot_name, ':p') ~= snapshot_path then
      if config.snapshot_path == nil then
         log.warn('config.snapshot_path is not set')
         return
      else
         snapshot_path = util.join_paths(config.snapshot_path, snapshot_path)
      end
   end

   local target_plugins = _G.packer_plugins
   if next(args) ~= nil then
      target_plugins = vim.tbl_filter(
      function(plugin)
         for i, name in ipairs(args) do
            if name == plugin.name then
               args[i] = nil
               return true
            end
         end
         return false
      end,
      _G.packer_plugins)

   end

   local write_snapshot = true

   if fn.filereadable(snapshot_path) == 1 then
      vim.ui.select(
      { 'Replace', 'Cancel' },
      { prompt = fmt("Do you want to replace '%s'?", snapshot_path) },
      function(_, idx)
         write_snapshot = idx == 1
      end)

   end

   if write_snapshot then
      local r = require('packer.snapshot').create(snapshot_path, target_plugins)
      if r.ok then
         log.info(r.ok.message)
         if next(r.ok.failed) then
            log.warn("Couldn't snapshot " .. vim.inspect(r.ok.failed))
         end
      else
         log.warn(r.err.message)
      end
   end
end)



M.rollback = a.void(function(snapshot_name, ...)
   local args = { ... }

   local snapshot_path = vim.loop.fs_realpath(util.join_paths(config.snapshot_path, snapshot_name)) or
   vim.loop.fs_realpath(snapshot_name)

   if snapshot_path == nil then
      local warn = fmt("Snapshot '%s' is wrong or doesn't exist", snapshot_name)
      log.warn(warn)
      return
   end

   local target_plugins = _G.packer_plugins

   if next(args) ~= nil then
      target_plugins = vim.tbl_filter(function(plugin)
         for _, plugin_sname in ipairs(args) do
            if plugin_sname == plugin.name then
               return true
            end
         end
         return false
      end, _G.packer_plugins)
   end

   local r = require('packer.snapshot').rollback(snapshot_path, target_plugins)

   if r.ok then
      a.main()
      log.info(fmt('Rollback to "%s" completed', snapshot_path))
      if next(r.ok.failed) then
         log.warn("Couldn't rollback " .. vim.inspect(r.ok.failed))
      end
   else
      a.main()
      log.error(r.err)
   end
end)

return M