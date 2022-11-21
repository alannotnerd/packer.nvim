local a = require('packer.async')
local util = require('packer.util')
local log = require('packer.log')
local config = require('packer.config')
local result = require('packer.result')
local Display = require('packer.display').Display

local fn = vim.fn
local uv = vim.loop

local M = {FSState = {}, Error = {}, }















local function guess_dir_type(dir)
   local globdir = fn.glob(dir)
   local dir_type = (uv.fs_lstat(globdir) or { type = 'noexist' }).type







   if dir_type == 'link' then
      return 'local'
   end

   if uv.fs_stat(globdir .. '/.git') then
      return 'git'
   end

   return 'unknown'
end

function M.list_installed_plugins()
   local opt_plugins = {}
   local start_plugins = {}
   local opt_dir_handle = uv.fs_opendir(config.opt_dir, nil, 50)
   if opt_dir_handle then
      local opt_dir_items = uv.fs_readdir(opt_dir_handle)
      while opt_dir_items do
         for _, item in ipairs(opt_dir_items) do
            opt_plugins[util.join_paths(config.opt_dir, item.name)] = true
         end

         opt_dir_items = uv.fs_readdir(opt_dir_handle)
      end
   end

   local start_dir_handle = uv.fs_opendir(config.start_dir, nil, 50)
   if start_dir_handle then
      local start_dir_items = uv.fs_readdir(start_dir_handle)
      while start_dir_items do
         for _, item in ipairs(start_dir_items) do
            start_plugins[util.join_paths(config.start_dir, item.name)] = true
         end

         start_dir_items = uv.fs_readdir(start_dir_handle)
      end
   end

   return opt_plugins, start_plugins
end

local find_missing_plugins = a.sync(function(
   plugins,
   opt_plugins,
   start_plugins)



   local missing_plugins = {}
   for plugin_name, plugin in pairs(plugins) do
      local dir = plugin.opt and config.opt_dir or config.start_dir
      local plugin_path = util.join_paths(dir, plugin.name)

      local plugin_installed = (plugin.opt and opt_plugins or start_plugins)[plugin_path]

      a.main()
      local guessed_type = guess_dir_type(plugin_path)
      if not plugin_installed or plugin.type ~= guessed_type then
         missing_plugins[plugin_name] = true
      elseif guessed_type == 'git' then
         local remote = require('packer.plugin_types.git').remote_url(plugin)
         if remote then

            local parts = vim.split(remote, '[:/]')
            local repo_name = parts[#parts - 1] .. '/' .. parts[#parts]
            repo_name = repo_name:gsub('%.git', '')



            local normalized_remote = remote:gsub('https://', ''):gsub('ssh://git@', '')
            local normalized_plugin_url = plugin.url:gsub('https://', ''):gsub('ssh://git@', ''):gsub('\\', '/')
            if (normalized_remote ~= normalized_plugin_url) and (repo_name ~= normalized_plugin_url) then
               missing_plugins[plugin_name] = true
            end
         end
      end
   end

   return missing_plugins
end, 3)

M.get_fs_state = a.sync(function(plugins)
   log.debug('Updating FS state')
   local opt_plugins, start_plugins = M.list_installed_plugins()
   return {
      opt = opt_plugins,
      start = start_plugins,
      missing = find_missing_plugins(plugins, opt_plugins, start_plugins),
   }
end, 1)

local function load_plugin(plugin)
   if plugin.opt then
      vim.cmd.packadd(plugin.name)
      return
   end

   vim.o.runtimepath = vim.o.runtimepath .. ',' .. plugin.install_path

   for _, path in ipairs({
         util.join_paths(plugin.install_path, 'plugin', '**', '*.vim'),
         util.join_paths(plugin.install_path, 'plugin', '**', '*.lua'),
         util.join_paths(plugin.install_path, 'after', 'plugin', '**', '*.vim'),
         util.join_paths(plugin.install_path, 'after', 'plugin', '**', '*.lua'),
      }) do
      local ok, files = pcall(fn.glob, path, false, true)
      if not ok then
         if (files):find('E77') then
            vim.cmd('silent exe "source ' .. path .. '"')
         else
            error(files)
         end
      else
         for _, file in ipairs(files) do
            vim.cmd.source({ file, mods = { silent = true } })
         end
      end
   end
end

M.post_update_hook = a.sync(function(plugin, disp)
   local plugin_name = plugin.full_name
   if plugin.run or not plugin.opt then
      a.main()
      load_plugin(plugin)
   end

   if not plugin.run then
      return result.ok({})
   end

   disp:task_update(plugin_name, 'running post update hooks...')

   for _, run_task in ipairs(plugin.run) do
      if type(run_task) == "function" then
         local ok, err = pcall(run_task, plugin, disp)
         if not ok then
            return result.err({
               msg = 'Error running post update hook: ' .. vim.inspect(err),
            })
         end
      elseif type(run_task) == 'string' and run_task:sub(1, 1) == ':' then

         a.main()
         vim.cmd(run_task:sub(2))
      else
         local jobs = require('packer.jobs')
         local jr = jobs.run(run_task, {
            capture_output = true,
            cwd = plugin.install_path,
         })

         if jr.err then
            return result.err({
               msg = string.format('Error running post update hook: %s', table.concat(jr.err.output.data.stderr, '\n')),
               data = jr.err,
            })
         end
      end
   end

   return result.ok({})
end, 2)

return M