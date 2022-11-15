local a = require 'packer.async'
local log = require 'packer.log'
local plugin_utils = require 'packer.plugin_utils'

local fmt = string.format

---@param installs {[string]: Result}
local install_plugin = a.sync(function(
  plugin: Plugin,
  disp: Display,
  installs: {string:Result<PluginResult>}
): Result<PluginResult>
  disp:task_start(plugin.full_name, 'installing...')

  local plugin_type = require'packer.plugin_types'[plugin.type]

  local r = plugin_type.installer(plugin, disp)

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

local function install(
  plugins: {string:Plugin},
  missing_plugins: {string},
  disp: Display,
  installs: {string:Result<PluginResult>}
): {a.Thunk}
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
