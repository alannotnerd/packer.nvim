
---@param cond 'cmd'|'keys'|'ft'|'event'
---@param plugins {[string]:PluginSpec}
---@param loader fun(names: string[])
return function(cond, plugins, loader)
  require('packer.handlers.' .. cond)(plugins, loader)
end
