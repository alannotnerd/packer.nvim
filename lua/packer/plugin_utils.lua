local a = require 'packer.async'
local util = require 'packer.util'
local log = require 'packer.log'
local config = require 'packer.config'

local fn = vim.fn
local uv = vim.loop

local M = {}

local function guess_dir_type(dir)
  local globdir = fn.glob(dir)
  local dir_type = (uv.fs_lstat(globdir) or { type = 'noexist' }).type

  -- NOTE: We're assuming here that:
  --
  -- 1. users only create custom plugins for non-git repos;
  -- 2. custom plugins don't use symlinks to install;
  --
  -- otherwise, there's no consistent way to tell from a dir alone…
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

---@async
---@param plugins       {[string]: PluginSpec}
---@param opt_plugins   {[string]: boolean}
---@param start_plugins {[string]: boolean}
---@return {[string]: boolean}
local find_missing_plugins = a.sync(function(plugins, opt_plugins, start_plugins)
  -- NOTE/TODO: In the case of a plugin gaining/losing an alias, this will force a clean and
  -- reinstall
  local missing_plugins = {}
  for plugin_name, plugin in pairs(plugins) do
    local plugin_path = util.join_paths(config[plugin.opt and 'opt_dir' or 'start_dir'], plugin.short_name)
    local plugin_installed = (plugin.opt and opt_plugins or start_plugins)[plugin_path]

    a.main()
    local guessed_type = guess_dir_type(plugin_path)
    if not plugin_installed or plugin.type ~= guessed_type then
      missing_plugins[plugin_name] = true
    elseif guessed_type == 'git' then
      local r = plugin.remote_url()
      local remote = r.ok and r.ok.remote or nil
      if remote then
        -- Form a Github-style user/repo string
        local parts = vim.split(remote, '[:/]')
        local repo_name = parts[#parts - 1] .. '/' .. parts[#parts]
        repo_name = repo_name:gsub('%.git', '')

        -- Also need to test for "full URL" plugin names, but normalized to get rid of the
        -- protocol
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

---@class FSState
---@field start   {[string]: boolean}
---@field opt     {[string]: boolean}
---@field missing {[string]: boolean}

---@async
---@param plugins {[string]: PluginSpec}
---@return FSState
M.get_fs_state = a.sync(function(plugins)
  log.debug 'Updating FS state'
  local opt_plugins, start_plugins = M.list_installed_plugins()
  return {
    opt = opt_plugins,
    start = start_plugins,
    missing = find_missing_plugins(plugins, opt_plugins, start_plugins)
  }
end, 1)

local function load_plugin(plugin)
  if plugin.opt then
    vim.cmd.packadd(plugin.short_name)
    return
  end

  vim.o.runtimepath = vim.o.runtimepath .. ',' .. plugin.install_path

  for _, path in ipairs {
    util.join_paths(plugin.install_path, 'plugin', '**', '*.vim'),
    util.join_paths(plugin.install_path, 'after', 'plugin', '**', '*.vim'),
  } do
    local ok, files = pcall(fn.glob, path, false, true)
    if not ok then
      if files:find('E77') then
        vim.cmd('silent exe "source ' .. path .. '"')
      else
        error(files)
      end
    else
      for _, file in ipairs(files --[[@as string[] ]]) do
        vim.cmd.source{file, mods = {silent=true}}
      end
    end
  end
end

---@param plugin PluginSpec
---@param disp Display
---@return Result
M.post_update_hook = a.sync(function(plugin, disp)
  local result = require 'packer.result'
  local plugin_name = plugin.full_name
  if plugin.run or not plugin.opt then
    a.main()
    load_plugin(plugin)
  end

  if not plugin.run then
    return result.ok()
  end

  disp:task_update(plugin_name, 'running post update hooks...')

  ---@diagnostic disable-next-line
  for _, run_task in ipairs(plugin.run) do
    if type(run_task) == 'function' then
      local ok, err = pcall(run_task, plugin, disp)
      if not ok then
        return result.err {
          msg = 'Error running post update hook: ' .. vim.inspect(err),
        }
      end
    elseif type(run_task) == 'string' and run_task:sub(1, 1) == ':' then
      -- Run a vim command
      a.main()
      vim.cmd(run_task:sub(2))
    else
      -- Run a shell command
      -- run_task can be either a string or an array
      local res = { err = {}, output = {} }

      local jobs = require 'packer.jobs'
      local hook_result = jobs.run(run_task, {
        capture_output = {
          stderr = jobs.logging_callback(res.err, res.output, disp, plugin_name),
          stdout = jobs.logging_callback(res.err, res.output, disp, plugin_name),
        },
        cwd = plugin.install_path
      })

      if hook_result.err then
          return result.err {
            msg = string.format('Error running post update hook: %s', table.concat(res.output, '\n')),
            data = hook_result.err,
          }
      end
    end
  end

  return result.ok()
end, 2)

return M
