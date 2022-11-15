

local M = {}


function M.ok(ok)
   assert(ok)
   return { ok = ok }
end


function M.err(err)
   assert(err)
   return { err = err }
end

return M
