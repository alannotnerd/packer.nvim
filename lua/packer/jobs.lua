-- Interface with Neovim job control and provide a simple job sequencing structure
local split = vim.split
local uv = vim.loop
local a = require 'packer.async'
local log = require 'packer.log'
local result = require 'packer.result'

--- Utility function to make a "standard" logging callback for a given set of tables
-- Arguments:
-- - err_tbl: table to which err messages will be logged
-- - data_tbl: table to which data (non-err messages) will be logged
-- - pipe: the pipe for which this callback will be used. Passed in so that we can make sure all
--      output flushes before finishing reading
-- - disp: optional packer.display object for updating task status. Requires `name`
-- - name: optional string name for a current task. Used to update task status
---@param err_tbl string[]
---@param data_tbl string[]
---@param disp any
---@param name? string
local function make_logging_callback(err_tbl, data_tbl, disp, name)
  return function(err, data)
    if err then
      table.insert(err_tbl, vim.trim(err))
    end
    if data ~= nil then
      local trimmed = vim.trim(data)
      table.insert(data_tbl, trimmed)
      if disp then
        disp:task_update(name, split(trimmed, '\n')[1])
      end
    end
  end
end

---@class JobOutput0
---@field stdout string[]
---@field stderr string[]

---@class JobOutput
---@field err JobOutput0
---@field data JobOutput0
--
---@class JobResult
---@field output JobOutput
---@field exit_code integer
---@field signal string|integer

--- Utility function to make a table for capturing output with "standard" structure
---@return JobOutput
local function make_output_table()
  return {
    err  = { stdout = {}, stderr = {} },
    data = { stdout = {}, stderr = {} }
  }
end

--- Utility function to merge stdout and stderr from two tables with "standard" structure (either
--  the err or data subtables, specifically)
local function extend_output(to, from)
  vim.list_extend(to.stdout, from.stdout)
  vim.list_extend(to.stderr, from.stderr)
  return to
end

--- Wrapper for vim.loop.spawn. Takes a command, options, and callback just like
--- vim.loop.spawn, but ensures that all output from the command has been
--- flushed before calling the callback.
---
--- @param cmd string
--- @param options table
--- @param callback function(integer, string)
local function spawn(cmd, options, callback)
  local handle = nil
  local timer = nil
  handle = uv.spawn(cmd, options, function(exit_code, signal)
    handle:close()
    if timer then
      timer:stop()
      timer:close()
    end

    local check, uv_err = uv.new_check()
    check:start(function()
      for _, pipe in pairs(options.stdio) do
        if not pipe:is_closing() then
          return
        end
      end
      check:stop()
      callback(exit_code, signal)
    end)
  end)

  if options.timeout then
    timer = uv.new_timer()
    timer:start(options.timeout, 0, function()
      timer:stop()
      timer:close()
      if handle:is_active() then
        log.warn('Killing ' .. cmd .. ' due to timeout!')
        handle:kill('sigint')
        handle:close()
        for _, pipe in pairs(options.stdio) do
          pipe:close()
        end
        callback(-9999, 'sigint')
      end
    end)
  end
end

--- Utility function to perform a common check for process success and return a result object
---@param r JobResult
local function was_successful(r)
  if r.exit_code == 0 and (not r.output or not r.output.err or #r.output.err == 0) then
    return result.ok(r)
  end
  return result.err(r)
end

local function setup_pipe(kind, callbacks, capture_output, output)
  if not capture_output then
    return
  elseif not capture_output[kind] then
    return
  end

  local handle, uv_err = uv.new_pipe(false)
  if uv_err then
    log.error(string.format('Failed to open %s pipe: %s', kind, uv_err))
    return false
  end

  if type(capture_output) == 'boolean' then
    callbacks[kind] = make_logging_callback(output.err[kind], output.data[kind])
  elseif type(capture_output) == 'table' then
    callbacks[kind] = capture_output[kind]
  end

  return handle
end

--- Main exposed function for the jobs module. Takes a task and options and returns an async
-- function that will run the task with the given opts via vim.loop.spawn
-- Arguments:
--  - task: either a string or table. If string, split, and the first component is treated as the
--    command. If table, first element is treated as the command. All subsequent elements are passed
--    as args
--  - opts: table of options. Can include the keys "options" (like the options table passed to
--    vim.loop.spawn), "success_test" (a function, called like `was_successful` (above)),
--    "capture_output" (either a boolean, in which case default output capture is set up and the
--    resulting tables are included in the result, or a set of tables, in which case output is logged
--    to the given tables)
---@async
local run_job = a.wrap(function(task, opts, callback)
  ---@type JobResult
  local job_result = { exit_code = -1, signal = -1 }
  local success_test = opts.success_test or was_successful
  local output = make_output_table()
  local callbacks = {}

  local stdout = setup_pipe('stdout', opts.capture_output, callbacks, output)

  if stdout == false then
    return job_result
  end

  local stderr = setup_pipe('stderr', opts.capture_output, callbacks, output)

  if stderr == false then
    return job_result
  end

  if type(task) == 'string' then
    local shell = os.getenv 'SHELL' or vim.o.shell
    local minus_c = shell:find 'cmd.exe$' and '/c' or '-c'
    task = { shell, minus_c, task }
  end

  spawn(task[1], {
    args    = { unpack(task, 2) },
    stdio   = { nil, stdout, stderr },
    cwd     = opts.cwd,
    timeout = opts.timeout and 1000 * opts.timeout or nil,
    env     = opts.env,
    hide    = true
  }, function(exit_code, signal)
    job_result = { exit_code = exit_code, signal = signal }
    if opts.capture_output == true then
      job_result.output = output
    end
    callback(success_test(job_result))
  end)

  for kind, pipe in pairs{ stdout = stdout, stderr = stderr } do
    if pipe and callbacks[kind] then
      pipe:read_start(function(err, data)
        if data then
          callbacks[kind](err, data)
        else
          pipe:read_stop()
          pipe:close()
        end
      end)
    end
  end

end, 3)

return {
  run = run_job,
  logging_callback = make_logging_callback,
  output_table = make_output_table,
  extend_output = extend_output,
}
