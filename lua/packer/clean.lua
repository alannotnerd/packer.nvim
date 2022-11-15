local a = require 'packer.async'

local function is_dirty(plugin, isopt)
  return (plugin.opt and isopt == false) or (not plugin.opt and isopt == true)
end

-- Find and remove any plugins not currently configured for use
---@async
---@param plugins PluginSpec[]
---@param fs_state? FSState
---@param removals? { [string]: Result }
return a.sync(function(plugins, fs_state, removals)
  local log = require 'packer.log'

  fs_state = fs_state or require('packer.plugin_utils').get_fs_state(plugins)

  log.debug 'Starting clean'
  local dirty_plugins = {}
  local opt_plugins = vim.deepcopy(fs_state.opt)
  local start_plugins = vim.deepcopy(fs_state.start)
  local missing_plugins = fs_state.missing

  -- test for dirty / 'missing' plugins
  for _, plugin_config in pairs(plugins) do
    local path = plugin_config.install_path
    local plugin_isopt
    if opt_plugins[path] then
      plugin_isopt = true
      opt_plugins[path] = nil
    elseif start_plugins[path] then
      plugin_isopt = false
      start_plugins[path] = nil
    end

    -- We don't want to report paths which don't exist for removal; that will confuse people
    local path_exists = false
    if missing_plugins[plugin_config.name] then
      path_exists = vim.loop.fs_stat(path) ~= nil
    end

    local plugin_missing = path_exists and missing_plugins[plugin_config.name]
    if plugin_missing or is_dirty(plugin_config, plugin_isopt) then
      dirty_plugins[#dirty_plugins + 1] = path
    end
  end

  -- Any path which was not set to `nil` above will be set to dirty here
  vim.list_extend(dirty_plugins, vim.tbl_keys(opt_plugins))
  vim.list_extend(dirty_plugins, vim.tbl_keys(start_plugins))

  if #dirty_plugins == 0 then
    log.info 'Already clean!'
    return
  end

  a.main()

  local lines = {}
  for _, path in ipairs(dirty_plugins) do
    table.insert(lines, '  - ' .. path)
  end

  local config = require 'packer.config'
  local display = require 'packer.display'

  if config.autoremove or display.ask_user('Removing the following directories. OK? (y/N)', lines) then
    if removals then
      for n, r in pairs(dirty_plugins) do
        removals[n] = r
      end
    end
    log.debug('Removed ' .. vim.inspect(dirty_plugins))
    for _, path in ipairs(dirty_plugins) do
      local result = vim.fn.delete(path, 'rf')
      if result == -1 then
        log.warn('Could not remove ' .. path)
      end
    end
  else
    log.warn 'Cleaning cancelled!'
  end
end, 4)
