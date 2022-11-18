local api = vim.api
local fn = vim.fn
local fmt = string.format

local a = require('packer.async')
local config = require('packer.config')
local log = require('packer.log')
local util = require('packer.util')

local join_paths = util.join_paths








local plugins = {}

local M = {}











M.clean = a.void(function()
   require('packer.clean')(plugins)
end)

local function helptags_stale(dir)

   local txts = fn.glob(util.join_paths(dir, '*.txt'), true, true)
   vim.list_extend(txts, fn.glob(util.join_paths(dir, '*.[a-z][a-z]x'), true, true))

   if #txts == 0 then
      return false
   end

   local tags = fn.glob(util.join_paths(dir, 'tags'), true, true)
   vim.list_extend(tags, fn.glob(util.join_paths(dir, 'tags-[a-z][a-z]'), true, true))

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
      if r.ok then
         paths[#paths + 1] = plugins[plugin_name].install_path
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
   disp:update_headline_message(fmt('updating %d / %d plugins', #tasks, #tasks))
   return a.join(limit, check, tasks)
end

local function measure(f)
   local start_time = vim.loop.hrtime()
   f()
   return (vim.loop.hrtime() - start_time) / 1e9
end



M.install = a.sync(function()
   log.debug('packer.install: requiring modules')

   local plugin_utils = require('packer.plugin_utils')
   local fs_state = plugin_utils.get_fs_state(plugins)
   local install_plugins = vim.tbl_keys(fs_state.missing)
   if #install_plugins == 0 then
      log.info('All configured plugins are installed')
      return
   end

   a.main()

   log.debug('Gathering install tasks')

   local disp = require('packer.display').open()
   local installs = {}

   local delta = measure(function()
      local install = require('packer.install')
      local install_tasks = install(plugins, install_plugins, disp, installs)
      run_tasks(install_tasks, disp)

      a.main()
      update_helptags(installs)
   end)

   disp:final_results({ installs = installs }, delta)
end)



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
   return opts, #args > 0 and args or vim.tbl_keys(plugins)
end







M.update = a.void(function(first, ...)
   local opts, update_plugins = filter_opts_from_plugins(first, ...)
   local plugin_utils = require('packer.plugin_utils')
   local fs_state = plugin_utils.get_fs_state(plugins)
   local missing_plugins, installed_plugins = util.partition(vim.tbl_keys(fs_state.missing), update_plugins)

   local update = require('packer.update')

   local results = {
      moves = {},
      removals = {},
      installs = {},
      updates = {},
   }

   update.fix_plugin_types(plugins, missing_plugins, results.moves, fs_state)
   require('packer.clean')(plugins, fs_state, results.removals)

   missing_plugins = ({ util.partition(vim.tbl_keys(results.moves), missing_plugins) })[2]

   a.main()

   local disp = require('packer.display').open()

   local delta = measure(function()
      local tasks = {}

      log.debug('Gathering install tasks')
      local install_tasks = require('packer.install')(plugins, missing_plugins, disp, results.installs)
      vim.list_extend(tasks, install_tasks)

      log.debug('Gathering update tasks')
      a.main()

      local update_tasks = update.update(plugins, installed_plugins, disp, results.updates, opts)
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

   require('packer.display').open():set_status(_G.packer_plugins)
end)

local function apply_config(plugin)
   if plugin.config and plugin.loaded then
      local c = plugin.config
      if type(c) == "function" then
         c()
      else
         loadstring(c, plugin.name .. '.config()')()
      end
   end
end

local function loader(lplugins)
   for _, plugin in ipairs(lplugins) do
      if not plugin.loaded then


         plugin.loaded = true
         vim.cmd.packadd(plugin.name)
         apply_config(plugin)
      end
   end
end



function M.plugin_complete(lead, _)
   local completion_list = vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
   end, vim.tbl_keys(_G.packer_plugins))
   table.sort(completion_list)
   return completion_list
end


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
         snapshot_path = join_paths(config.snapshot_path, snapshot_path)
      end
   end

   local target_plugins = plugins
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
      plugins)

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

   local snapshot_path = vim.loop.fs_realpath(join_paths(config.snapshot_path, snapshot_name)) or
   vim.loop.fs_realpath(snapshot_name)

   if snapshot_path == nil then
      local warn = fmt("Snapshot '%s' is wrong or doesn't exist", snapshot_name)
      log.warn(warn)
      return
   end

   local target_plugins = plugins

   if next(args) ~= nil then
      target_plugins = vim.tbl_filter(function(plugin)
         for _, plugin_sname in ipairs(args) do
            if plugin_sname == plugin.name then
               return true
            end
         end
         return false
      end, plugins)
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

M.config = config

local function load_plugin_configs()
   local cond_plugins = {
      cmd = {},
      keys = {},
      ft = {},
      event = {},
   }

   local uncond_plugins = {}

   for name, plugin in pairs(plugins) do
      local has_cond = false
      for _, cond in ipairs({ 'cmd', 'keys', 'ft', 'event' }) do
         if (plugin)[cond] then
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

   for _, cond in ipairs({ 'cmd', 'keys', 'ft', 'event' }) do
      if next(cond_plugins[cond]) then
         require('packer.handlers')(cond, cond_plugins[cond], loader)
      end
   end
end

local function do_snapshot(k)
   return function(arglead, cmdline)
      (require('packer.snapshot'))[k](arglead, cmdline)
   end
end

local function do_snapshot_cmpl(k)
   return function(arglead, cmdline)
      (require('packer.snapshot').completion)[k](arglead, cmdline)
   end
end

local function make_commands()
   for _, cmd in ipairs({
         { 'PackerSnapshot', '+', do_snapshot('create'), do_snapshot_cmpl('create') },
         { 'PackerSnapshotRollback', '+', do_snapshot('rollback'), do_snapshot_cmpl('rollback') },
         { 'PackerSnapshotDelete', '+', do_snapshot('delete'), do_snapshot_cmpl('snapshot') },
         { 'PackerInstall', '*', M.install, M.plugin_complete },
         { 'PackerUpdate', '*', M.update, M.plugin_complete },
         { 'PackerClean', '*', M.clean },
         { 'PackerStatus', '*', M.status },
      }) do
      api.nvim_create_user_command(cmd[1], function(args)
         cmd[3](unpack(args.fargs))
      end, { nargs = cmd[2], complete = cmd[4] })
   end
end










function M.startup(spec)
   assert(type(spec) == 'table')
   assert(type(spec[1]) == 'table')

   plugins = {}

   config(spec.config)

   for _, dir in ipairs({ config.opt_dir, config.start_dir }) do
      if fn.isdirectory(dir) == 0 then
         fn.mkdir(dir, 'p')
      end
   end

   make_commands()

   if fn.mkdir(config.snapshot_path, 'p') ~= 1 then
      log.warn("Couldn't create " .. config.snapshot_path)
   end


   plugins = require('packer.plugin').process_spec({
      spec = spec[1],
      line = debug.getinfo(2, 'l').currentline,
   })

   load_plugin_configs()

   if config.snapshot then
      M.rollback(config.snapshot)
   end
end

return M
