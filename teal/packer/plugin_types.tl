local record PluginHandler
  installer   : function(plugin: Plugin, disp: Display): Result<PluginResult>
  updater     : function(plugin: Plugin, disp: Display, opts: table): Result<PluginResult>
  revert_last : function(plugin: Plugin): Result<PluginResult>
  diff        : function(plugin: Plugin, commit: string, callback: function): Result<PluginResult>
  job_env     : {string}
end

local plugin_types: {string:PluginHandler} = {}

return setmetatable(plugin_types, {
  __index = function(self: {string:PluginHandler}, k: string): PluginHandler
    if k == 'git' then
      local v = require('packer.plugin_types.git')
      self[k] = v
      return v
    elseif k == 'local' then
      local v = require('packer.plugin_types.local')
      self[k] = v
      return v
    end
  end,
})
