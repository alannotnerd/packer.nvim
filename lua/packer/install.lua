local a = require 'packer.async'
local log = require 'packer.log'
local plugin_utils = require 'packer.plugin_utils'

local fmt = string.format

---@async
---@param plugin PluginSpec
---@param disp Display
---@param results Results
local install_plugin = a.sync(function(plugin, disp, results)
  local plugin_name = plugin.full_name
  disp:task_start(plugin_name, 'installing...')
  -- TODO: If the user provided a custom function as an installer, we would like to use pcall
  -- here. Need to figure out how that integrates with async code
  local r = plugin.fn.installer(disp)

  if r.ok then
    r = plugin_utils.post_update_hook(plugin, disp)
  end

  if r.ok then
    disp:task_succeeded(plugin_name, 'installed')
    log.debug(fmt('Installed %s', plugin_name))
  else
    disp:task_failed(plugin_name, 'failed to install')
    log.debug(fmt('Failed to install %s: %s', plugin_name, vim.inspect(r.err)))
  end

  results.installs[plugin_name] = r
  results.plugins[plugin_name] = plugin
end, 3)

---@param plugins { [string]: PluginSpec }
---@param missing_plugins string[]
---@param disp Display
---@param results Results
---@return table
local function install(plugins, missing_plugins, disp, results)
  if #missing_plugins == 0 then
    return {}
  end

  results = results or {}
  results.installs = results.installs or {}
  results.plugins = results.plugins or {}

  local tasks = {}
  for _, v in ipairs(missing_plugins) do
    table.insert(tasks, a.curry(install_plugin, plugins[v], disp, results))
  end

  return tasks
end

return install
