---Executes a future with a callback when it is done
---@param func function: the future to execute
local function execute(func, ...)
  local thread = coroutine.create(func)

  local function step(...)
    local ret = {coroutine.resume(thread, ...)}
    local stat, err_or_fn, nargs = unpack(ret)

    if not stat then
      error(string.format("The coroutine failed with this message: %s\n%s",
        err_or_fn, debug.traceback(thread)))
    end

    if coroutine.status(thread) == 'dead' then
      return
    end

    local args = {select(4, unpack(ret))}
    args[nargs] = step
    err_or_fn(unpack(args, 1, nargs))
  end

  step(...)
end

local M = {}

---Creates an async function with a callback style function.
---@param func function: A callback style function to be converted. The last argument must be the callback.
---@param argc number: The number of arguments of func. Must be included.
---@return function: Returns an async function
-- function M.wrap(func, argc)
--   return function(...)
--     local args = {...}
--     return function(cb)
--       args[argc] = cb
--     if not coroutine.running() or select('#', unpack(args, 1, argc)) == argc then
--       return func(unpack(args, 1, argc))
--     end
--     return coroutine.yield(func, argc, unpack(args, 1, argc))
--     end
--   end
-- end

function M.wrap(func, argc)
  return function(...)
    local params = { ... }
    return function(tick)
      params[#params + 1] = tick
      return coroutine.yield(func, argc, unpack(params))
    end
  end
end


---Use this to create a function which executes in an async context but
---called from a non-async context. Inherently this cannot return anything
---since it is non-blocking
---@param func function
function M.sync(func)
  return function(...)
    if coroutine.running() then
      return func(...)
    end
    execute(func, ...)
  end
end

function M.wait(fn)
  return fn()
end

local function pool(n, interrupt_check, ...)
  local thunks = { ... }
  print('DDD1')
  return function(s)
  print('DDD2')
    if #thunks == 0 then
      return s()
    end
  print('DDD3')
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
  return coroutine.yield(pool, 1, ...)
end

local scheduler = M.wrap(vim.schedule, 1)
---An async function that when called will yield to the Neovim scheduler to be
---able to call the API.
M.main = scheduler()

return M
