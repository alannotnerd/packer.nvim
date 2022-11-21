local Display = require('packer.display').Display









local plugin_types = {}

return setmetatable(plugin_types, {
   __index = function(self, k)
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