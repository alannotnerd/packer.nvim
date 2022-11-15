--- @class PluginHandler
--- @field installer fun(plugin: PluginSpec, disp: Display): Result
--- @field updater   fun(plugin: PluginSpec, disp: Display, opts: table): Result
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
