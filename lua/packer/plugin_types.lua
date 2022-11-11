local config

local function cfg(_config)
  config = _config
end

--- @class PluginHandler
--- @field setup    function
--- @field cfg      function
--- @field job_env? string[]

---@type {[string]: PluginHandler}
local plugin_types = setmetatable({ cfg = cfg }, {
  __index = function(self, k)
    local v = require('packer.plugin_types.' .. k)
    v.cfg(config)
    self[k] = v
    return v
  end,
})

return plugin_types
