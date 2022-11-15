local a = require 'packer.async'
local log = require 'packer.log'
local plugin_utils = require 'packer.plugin_utils'

local fmt = string.format

---@async
---@param plugin PluginSpec
---@param disp Display
---@param installs {[string]: Result}
local install_plugin = a.sync(function(plugin, disp, installs)
  disp:task_start(plugin.full_name, 'installing...')
  -- TODO: If the user provided a custom function as an installer, we would like to use pcall
  -- here. Need to figure out how that integrates with async code
  local r = plugin.fn.installer(disp)

  if r.ok then
    r = plugin_utils.post_update_hook(plugin, disp)
  end

  if r.ok then
    disp:task_succeeded(plugin.full_name, 'installed')
    log.debug(fmt('Installed %s', plugin.full_name))
  else
    disp:task_failed(plugin.full_name, 'failed to install')
    log.debug(fmt('Failed to install %s: %s', plugin.full_name, vim.inspect(r.err)))
  end

  installs[plugin.name] = r
  return r
end, 3)

---@param plugins { [string]: PluginSpec }
---@param missing_plugins string[]
---@param disp Display
---@param installs {[string]: Result}
---@return table
local function install(plugins, missing_plugins, disp, installs)
  if #missing_plugins == 0 then
    return {}
  end

  local tasks = {}
  for _, v in ipairs(missing_plugins) do
    table.insert(tasks, a.curry(install_plugin, plugins[v], disp, installs))
  end

  return tasks
end

return install
