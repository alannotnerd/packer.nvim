local a = require 'packer.async'
local log = require 'packer.log'
local util = require 'packer.util'
local display = require 'packer.display'
local plugin_utils = require 'packer.plugin_utils'

local fmt = string.format

---@async
---@param plugin PluginSpec
---@param display_win Display
---@param results Results
local install_plugin = a.sync(function(plugin, display_win, results)
  local plugin_name = plugin.full_name
  display_win:task_start(plugin_name, 'installing...')
  -- TODO: If the user provided a custom function as an installer, we would like to use pcall
  -- here. Need to figure out how that integrates with async code
  local r = plugin.installer(display_win)

  if r.ok then
    r = plugin_utils.post_update_hook(plugin, display_win)
  end

  if r.ok then
    display_win:task_succeeded(plugin_name, 'installed')
    log.debug(fmt('Installed %s', plugin_name))
  else
    display_win:task_failed(plugin_name, 'failed to install')
    log.debug(fmt('Failed to install %s: %s', plugin_name, vim.inspect(r.err)))
  end

  results.installs[plugin_name] = r
  results.plugins[plugin_name] = plugin
end, 3)

---@param display_cfg DisplayConfig
---@param plugins { [string]: PluginSpec }
---@param missing_plugins string[]
---@param results Results
local function install(display_cfg, plugins, missing_plugins, results)
  results = results or {}
  results.installs = results.installs or {}
  results.plugins = results.plugins or {}
  if #missing_plugins == 0 then
    return {}, nil
  end

  local tasks = {}
  local display_win = display.open(display_cfg.open_fn or display_cfg.open_cmd)
  for _, v in ipairs(missing_plugins) do
    table.insert(tasks, a.curry(install_plugin, plugins[v], display_win, results))
  end

  return tasks, display_win
end

return install
