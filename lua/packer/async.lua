-- Adapted from https://ms-jpq.github.io/neovim-async-tutorial/
local log = require 'packer.log'
local yield = coroutine.yield

local M = {}

local function EMPTY_CALLBACK() end
local function step(func, callback)
  local thread = coroutine.create(func)
  local function tick(...)
    local ok, val = coroutine.resume(thread, ...)
    if ok then
      if type(val) == 'function' then
        val(tick)
      else
        (callback or EMPTY_CALLBACK)(val)
      end
    else
      log.error('Error in coroutine: ' .. val);
      (callback or EMPTY_CALLBACK)(nil)
    end
  end

  tick()
end

--- Wrapper for functions that do take a callback to make async functions
function M.wrap(func)
  return function(...)
    local params = { ... }
    return function(tick)
      params[#params + 1] = tick
      return func(unpack(params))
    end
  end
end

M.sync = M.wrap(step)

local function pool(n, interrupt_check, ...)
  local thunks = { ... }
  return function(s)
    if #thunks == 0 then
      return s()
    end
    local remaining = { select(n + 1, unpack(thunks)) }
    local to_go = #thunks

    local function make_callback()
      return function()
        to_go = to_go - 1
        if to_go == 0 then
          s()
        elseif not interrupt_check or not interrupt_check() then
          if #remaining > 0 then
            local next_task = table.remove(remaining)
            next_task(make_callback())
          end
        end
      end
    end

    for i = 1, math.min(n, #thunks) do
      thunks[i](make_callback())
    end
  end
end

  --- Like wait_pool, but additionally checks at every function completion to see if a condition is
  --  met indicating that it should keep running the remaining tasks
function M.interruptible_wait_pool(...)
  return yield(pool(...))
end

--- Convenience function to ensure a function runs on the main "thread" (i.e. for functions which
--  use Neovim functions, etc.)
function M.main(f)
  vim.schedule(f)
end

--- Wrapper for functions that do not take a callback to make async functions
--- Alias for yielding to await the result of an async function
M.wait = yield

return M
