-- Interface with Neovim job control and provide a simple job sequencing structure
local split = vim.split
local uv = vim.loop
local a = require 'packer.async'
local log = require 'packer.log'
local result = require 'packer.result'

local record M
  record JobResult
    exit_code: integer
    signal: integer | string
    output: JobOutput
  end

  enum StdioType
    'stdout'
    'stderr'
  end

  record StdioCallbacks
    stdout: function(string, string)
    stderr: function(string, string)
  end

  record Opts
    success_test: function(r: JobResult): Result<JobResult>
    capture_output: boolean
    cwd: string
    timeout: integer
    env: {string}
  end

  run: function(task: any, opt: any): Result<JobResult>
end

--- Utility function to make a "standard" logging callback for a given set of tables
-- Arguments:
-- - err_tbl: table to which err messages will be logged
-- - data_tbl: table to which data (non-err messages) will be logged
-- - pipe: the pipe for which this callback will be used. Passed in so that we can make sure all
--      output flushes before finishing reading
-- - disp: optional packer.display object for updating task status. Requires `name`
-- - name: optional string name for a current task. Used to update task status
local function logging_callback(err_tbl: {string}, data_tbl: {string}, disp: Display, name: string): function(string, string)
  return function(err: string, data: string)
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

--- Utility function to make a table for capturing output with "standard" structure
function M.output_table(): JobOutput
  return {
    err  = { stdout = {}, stderr = {} },
    data = { stdout = {}, stderr = {} }
  }
end

--- Utility function to merge stdout and stderr from two tables with "standard" structure (either
--  the err or data subtables, specifically)
function M.extend_output(to: JobOutput.E, from: JobOutput.E): JobOutput.E
  vim.list_extend(to.stdout, from.stdout)
  vim.list_extend(to.stderr, from.stderr)
  return to
end

--- Wrapper for vim.loop.spawn. Takes a command, options, and callback just like
--- vim.loop.spawn, but ensures that all output from the command has been
--- flushed before calling the callback.
local function spawn(cmd: string, options: uv.SpawnOpts, callback: function(integer, string))
  local handle = nil as uv.Process
  local timer = nil as uv.Timer
  handle = uv.spawn(cmd, options, function(exit_code: integer, signal: string)
    handle:close()
    if timer then
      timer:stop()
      timer:close()
    end

    local check = uv.new_check()
    assert(check)
    check:start(function()
      for _, pipe in ipairs(options.stdio) do
        if not pipe:is_closing() then
          return
        end
      end
      check:stop()
      callback(exit_code, signal)
    end)
  end)

  local timeout = (options as table).timeout as integer

  if timeout then
    timer = uv.new_timer()
    timer:start(timeout, 0, function()
      timer:stop()
      ---@diagnostic disable-next-line
      timer:close()
      if handle and handle:is_active() then
        log.warn('Killing ' .. cmd .. ' due to timeout!')
        handle:kill('sigint')
        handle:close()
        for _, pipe in ipairs(options.stdio) do
          pipe:close()
        end
        callback(-9999, 'sigint')
      end
    end)
  end
end

--- Utility function to perform a common check for process success and return a result object
---@param r JobResult
local function was_successful(r: M.JobResult): Result<M.JobResult>
  if r.exit_code == 0 then
    return result.ok(r)
  end
  return result.err(r)
end

local function setup_pipe(kind: M.StdioType, callbacks: M.StdioCallbacks, capture_output: boolean, output: JobOutput): boolean | uv.Pipe
  if not capture_output then
    return
  end

  local handle, uv_err = uv.new_pipe(false)
  if uv_err then
    log.error(string.format('Failed to open %s pipe: %s', kind, uv_err))
    return false
  end

  callbacks[kind] = logging_callback(output.err[kind], output.data[kind])

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
--- @type fun(table, table): Result
M.run = a.wrap(function(task: string|{string}, opts: M.Opts, callback: function(Result<M.JobResult>))
  ---@type JobResult
  local job_result = { exit_code = -1, signal = -1 } as M.JobResult
  local success_test = opts.success_test or was_successful
  local output = M.output_table()
  local callbacks = {}

  local stdout = setup_pipe('stdout', callbacks, opts.capture_output, output)

  if stdout == false then
    callback(success_test(job_result))
    return
  end

  stdout = stdout as uv.Pipe

  local stderr = setup_pipe('stderr', callbacks, opts.capture_output, output)

  if stderr == false then
    callback(success_test(job_result))
    return
  end

  stderr = stderr as uv.Pipe

  if task is string then
    local shell = os.getenv 'SHELL' or vim.o.shell
    local minus_c = shell:find 'cmd.exe$' and '/c' or '-c'
    task = { shell, minus_c, task }
  end

  task = task as {string}

  spawn(task[1], {
    args    = { unpack(task, 2) },
    stdio   = { nil, stdout, stderr },
    cwd     = opts.cwd,
    timeout = opts.timeout and 1000 * opts.timeout or nil,
    env     = opts.env,
    hide    = true
  }, function(exit_code: integer, signal: string)
    job_result = { exit_code = exit_code, signal = signal }
    if opts.capture_output == true then
      job_result.output = output
    end
    callback(success_test(job_result))
  end)

  for kind, pipe in pairs{ stdout = stdout, stderr = stderr } do
    if pipe and callbacks[kind as M.StdioType] then
      pipe:read_start(function(err: string, data: string)
        if data then
          callbacks[kind as M.StdioType](err, data)
        else
          pipe:read_stop()
          pipe:close()
        end
      end)
    end
  end

end, 3)

return M
