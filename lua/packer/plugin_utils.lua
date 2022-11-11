local fn = vim.fn
local uv = vim.loop

local a = require 'packer.async'
local jobs = require 'packer.jobs'
local util = require 'packer.util'
local result = require 'packer.result'
local log = require 'packer.log'

local config = nil

local plugin_utils = {
  unknown_plugin_type = 'unknown',
  local_plugin_type   = 'local',
  git_plugin_type     = 'git'
}

function plugin_utils.cfg(_config)
  config = _config
end

local function guess_dir_type(dir)
  local globdir = fn.glob(dir)
  local dir_type = (uv.fs_lstat(globdir) or { type = 'noexist' }).type

  --[[ NOTE: We're assuming here that:
             1. users only create custom plugins for non-git repos;
             2. custom plugins don't use symlinks to install;
             otherwise, there's no consistent way to tell from a dir alone… ]]
  if dir_type == 'link' then
    return plugin_utils.local_plugin_type
  elseif uv.fs_stat(globdir .. '/.git') then
    return plugin_utils.git_plugin_type
  elseif dir_type ~= 'noexist' then
    return plugin_utils.custom_plugin_type
  end
end

local function helptags_stale(dir)
  -- Adapted directly from minpac.vim
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

  local txt_newest = math.max(unpack(util.map(fn.getftime, txts)))
  local tag_oldest = math.min(unpack(util.map(fn.getftime, tags)))
  return txt_newest > tag_oldest
end

plugin_utils.update_helptags = vim.schedule_wrap(function(...)
  for _, dir in ipairs(...) do
    local doc_dir = util.join_paths(dir, 'doc')
    if helptags_stale(doc_dir) then
      log.info('Updating helptags for ' .. doc_dir)
      vim.cmd('silent! helptags ' .. fn.fnameescape(doc_dir))
    end
  end
end)

function plugin_utils.ensure_dirs()
  if fn.isdirectory(config.opt_dir) == 0 then
    fn.mkdir(config.opt_dir, 'p')
  end

  if fn.isdirectory(config.start_dir) == 0 then
    fn.mkdir(config.start_dir, 'p')
  end
end

function plugin_utils.list_installed_plugins()
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
---@param plugins       PluginSpec[]
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
    elseif guessed_type == plugin_utils.git_plugin_type then
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
        local normalized_plugin_name = plugin.name:gsub('https://', ''):gsub('ssh://git@', ''):gsub('\\', '/')
        if (normalized_remote ~= normalized_plugin_name) and (repo_name ~= normalized_plugin_name) then
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
---@param plugins PluginSpec[]
---@return FSState
plugin_utils.get_fs_state = a.sync(function(plugins)
  log.debug 'Updating FS state'
  local opt_plugins, start_plugins = plugin_utils.list_installed_plugins()
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
plugin_utils.post_update_hook = a.sync(function(plugin, disp)
  local plugin_name = plugin.full_name
  if plugin.run or not plugin.opt then
    a.main()
    load_plugin(plugin)
  end

  if not plugin.run then
    return result.ok()
  end

  if type(plugin.run) ~= 'table' then
    plugin.run = { plugin.run }
  end

  disp:task_update(plugin_name, 'running post update hooks...')

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

return plugin_utils
