local Display = require 'packer.display'.Display

local record PluginHandler
  installer   : function(plugin: Plugin, disp: Display): {string}
  updater     : function(plugin: Plugin, disp: Display, opts: table): {string}
  revert_last : function(plugin: Plugin): {string}
  diff        : function(plugin: Plugin, commit: string, callback: function): {string}
  get_rev     : function(plugin: Plugin): string, string
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
