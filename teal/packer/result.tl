-- A simple Result<V, E> type to simplify control flow with installers and updaters

local M = {}

function M.ok<V>(ok: V): Result<V>
  assert(ok)
  return { ok = ok }
end

function M.err<V, E>(err: V): Result<V>
  assert(err)
  return { err = err }
end

return M
