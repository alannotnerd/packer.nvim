---Executes a future with a callback when it is done
---@param func function: the future to execute
local function execute(func, callback, ...)
  local thread = coroutine.create(func)

  local function step(...)
    local ret = {coroutine.resume(thread, ...)}
    local stat, err_or_fn_or_ret, nargs = unpack(ret)

    if not stat then
      error(string.format("The coroutine failed with this message: %s\n%s",
        err_or_fn_or_ret, debug.traceback(thread)))
    end

    if coroutine.status(thread) == 'dead' then
      if callback then
        callback(err_or_fn_or_ret)
      end
      return
    end

    local args = {select(4, unpack(ret))}
    args[nargs] = step
    err_or_fn_or_ret(unpack(args, 1, nargs))
  end

  step(...)
end

local M = {}

---Creates an async function with a callback style function.
---@param func function: A callback style function to be converted. The last argument must be the callback.
---@param argc number: The number of arguments of func. Must be included.
function M.wrap(func, argc)
  return function(...)
    if not coroutine.running() or select('#', ...) == argc then
      return func(...)
    end
    return coroutine.yield(func, argc, ...)
  end
end

---Use this to create a function which executes in an async context but
---called from a non-async context. Inherently this cannot return anything
---since it is non-blocking
---@param func function first argument must be a callback which is called when
--                      fn finishes
function M.sync(func, nargs)
  return function(...)
    if coroutine.running() then
      return func(...)
    end
    nargs = nargs or 0
    local callback = select(nargs+1, ...)
    execute(func, callback, unpack({...}, 1, nargs))
  end
end

---For functions that don't provide a callback as there last argument
function M.void(func)
  return function(...)
    if coroutine.running() then
      return func(...)
    end
    execute(func, nil, ...)
  end
end

function M.wait(fn)
  return fn()
end

function M.interruptible_wait_pool(n, interrupt_check, ...)
  local thunks = { ... }

  return coroutine.yield(function(finish)
    if #thunks == 0 then
      return finish()
    end
    local remaining = { select(n + 1, unpack(thunks)) }
    local to_go = #thunks

    local function cb()
      to_go = to_go - 1
      if to_go == 0 then
        finish()
      elseif not interrupt_check or not interrupt_check() then
        if #remaining > 0 then
          local next_task = table.remove(remaining)
          next_task(cb)
        end
      end
    end

    for i = 1, math.min(n, #thunks) do
      thunks[i](cb)
    end
  end, 1)
end

---Useful for partially applying arguments to an async function
function M.curry(fn, ...)
  local args = {...}
  local nargs = select('#', ...)
  return function(...)
    local other = {...}
    for i = 1, select('#', ...) do
      args[nargs+i] = other[i]
    end
    fn(unpack(args))
  end
end

local scheduler = M.wrap(vim.schedule, 1)
---An async function that when called will yield to the Neovim scheduler to be
---able to call the API.
M.main = scheduler

return M
