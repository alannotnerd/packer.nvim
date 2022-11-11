-- A simple Result<V, E> type to simplify control flow with installers and updaters

---@class JobResOk
---@field message string
---@field completed table<string, string>
---@field failed table<string, string>
---@field output JobOutput

---@class JobResFail
---@field message string
---@field msg string
---@field data any
---@field output JobOutput

---@class Result
---@field ok JobResOk
---@field err JobResFail

local M = {}

---@return Result
M.ok = function(val)
  if val == nil then
    val = true
  end
  return {
    ok = val
  }
end

---@return Result
M.err = function(err)
  if err == nil then
    err = true
  end
  return {
    err = err
  }
end

return M
