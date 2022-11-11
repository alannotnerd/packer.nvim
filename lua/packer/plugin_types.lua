--- @class PluginHandler
--- @field setup    function
--- @field cfg      function
--- @field job_env? string[]

---@type {[string]: PluginHandler}
local plugin_types = setmetatable({}, {
  __index = function(self, k)
    local v = require('packer.plugin_types.' .. k)
    self[k] = v
    return v
  end,
})

return plugin_types
