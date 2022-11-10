local a = require 'packer.async'
local display = require 'packer.display'
local log = require 'packer.log'

local function is_dirty(plugin, isopt)
  return (plugin.opt and isopt == false) or (not plugin.opt and isopt == true)
end

-- Find and remove any plugins not currently configured for use
---@async
---@param plugins PluginSpec[]
---@param fs_state FSState
---@param results Results
---@param autoremove boolean
local clean_plugins = a.sync(function(plugins, fs_state, results, autoremove)
  log.debug 'Starting clean'
  local dirty_plugins = {}
  results = results or {}
  results.removals = results.removals or {}
  local opt_plugins = vim.deepcopy(fs_state.opt)
  local start_plugins = vim.deepcopy(fs_state.start)
  local missing_plugins = fs_state.missing

  -- test for dirty / 'missing' plugins
  for _, plugin_config in pairs(plugins) do
    local path = plugin_config.install_path
    local plugin_isopt = nil
    if opt_plugins[path] then
      plugin_isopt = true
      opt_plugins[path] = nil
    elseif start_plugins[path] then
      plugin_isopt = false
      start_plugins[path] = nil
    end

    -- We don't want to report paths which don't exist for removal; that will confuse people
    local path_exists = false
    if missing_plugins[plugin_config.short_name] then
      path_exists = vim.loop.fs_stat(path) ~= nil
    end

    local plugin_missing = path_exists and missing_plugins[plugin_config.short_name]
    if plugin_missing or is_dirty(plugin_config, plugin_isopt) then
      dirty_plugins[#dirty_plugins + 1] = path
    end
  end

  -- Any path which was not set to `nil` above will be set to dirty here
  local function mark_remaining_as_dirty(plugin_list)
    for path, _ in pairs(plugin_list) do
      dirty_plugins[#dirty_plugins + 1] = path
    end
  end

  mark_remaining_as_dirty(opt_plugins)
  mark_remaining_as_dirty(start_plugins)

  if next(dirty_plugins) then
    local lines = {}
    for _, path in ipairs(dirty_plugins) do
      table.insert(lines, '  - ' .. path)
    end
    a.main()
    if autoremove or display.ask_user('Removing the following directories. OK? (y/N)', lines)() then
      results.removals = dirty_plugins
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
  else
    log.info 'Already clean!'
  end
end, 4)

return clean_plugins
