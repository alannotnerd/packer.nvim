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
local function make_logging_callback(err_tbl, data_tbl, pipe, disp, name)
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
    else
      pipe:read_stop()
      pipe:close()
    end
  end
end

---@class JobOutput0
---@field stdout string
---@field stderr string

---@class JobOutput
---@field err JobOutput0
---@field data JobOutput0

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

--- Wrapper for vim.loop.spawn. Takes a command, options, and callback just like vim.loop.spawn, but
--  (1) makes an async function and (2) ensures that all output from the command has been flushed
--  before calling the callback
local function spawn(cmd, options, callback)
  local handle = nil
  local timer = nil
  handle = uv.spawn(cmd, options, function(exit_code, signal)
    handle:close()
    if timer then
      timer:stop()
      timer:close()
    end

    local check = uv.new_check()
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

  if options.stdio then
    for i, pipe in pairs(options.stdio) do
      if options.stdio_callbacks[i] then
        pipe:read_start(options.stdio_callbacks[i])
      end
    end
  end

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
local function was_successful(r)
  if r.exit_code == 0 and (not r.output or not r.output.err or #r.output.err == 0) then
    return result.ok(r)
  end
  return result.err(r)
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
local run_job = a.wrap(function(task, opts, callback)
  local options = opts.options or { hide = true }
  local stdout = nil
  local stderr = nil
  local job_result = { exit_code = -1, signal = -1 }
  local success_test = opts.success_test or was_successful
  local uv_err
  local output = make_output_table()
  local callbacks = {}
  local output_valid = false
  if opts.capture_output then
    if type(opts.capture_output) == 'boolean' then
      stdout, uv_err = uv.new_pipe(false)
      if uv_err then
        log.error('Failed to open stdout pipe: ' .. uv_err)
        return result.err()
      end

      stderr, uv_err = uv.new_pipe(false)
      if uv_err then
        log.error('Failed to open stderr pipe: ' .. uv_err)
        return job_result
      end

      callbacks = {
        stdout = make_logging_callback(output.err.stdout, output.data.stdout, stdout),
        stderr = make_logging_callback(output.err.stderr, output.data.stderr, stderr)
      }
      output_valid = true
    elseif type(opts.capture_output) == 'table' then
      if opts.capture_output.stdout then
        stdout, uv_err = uv.new_pipe(false)
        if uv_err then
          log.error('Failed to open stdout pipe: ' .. uv_err)
          return job_result
        end

        callbacks.stdout = function(err, data)
          if data ~= nil then
            opts.capture_output.stdout(err, data)
          else
            stdout:read_stop()
            stdout:close()
          end
        end
      end
      if opts.capture_output.stderr then
        stderr, uv_err = uv.new_pipe(false)
        if uv_err then
          log.error('Failed to open stderr pipe: ' .. uv_err)
          return job_result
        end

        callbacks.stderr = function(err, data)
          if data ~= nil then
            opts.capture_output.stderr(err, data)
          else
            stderr:read_stop()
            stderr:close()
          end
        end
      end
    end
  end

  if type(task) == 'string' then
    local shell = os.getenv 'SHELL' or vim.o.shell
    local minus_c = shell:find 'cmd.exe$' and '/c' or '-c'
    task = { shell, minus_c, task }
  end

  local cmd = task[1]
  if opts.timeout then
    options.timeout = 1000 * opts.timeout
  end

  options.cwd = opts.cwd

  options.args = { unpack(task, 2) }
  options.stdio = { nil, stdout, stderr }
  options.stdio_callbacks = { nil, callbacks.stdout, callbacks.stderr }

  spawn(cmd, options, function(exit_code, signal)
    job_result = { exit_code = exit_code, signal = signal }
    if output_valid then
      job_result.output = output
    end
    callback(success_test(job_result))
  end)
end, 3)

return {
  run = run_job,
  logging_callback = make_logging_callback,
  output_table = make_output_table,
  extend_output = extend_output,
}
