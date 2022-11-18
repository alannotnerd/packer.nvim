

return function(cond, plugins, loader)
   if cond == 'keys' then
      require('packer.handlers.keys')(plugins, loader)
   elseif cond == 'event' then
      require('packer.handlers.event')(plugins, loader)
   elseif cond == 'ft' then
      require('packer.handlers.ft')(plugins, loader)
   elseif cond == 'cmd' then
      require('packer.handlers.cmd')(plugins, loader)
   end
end
