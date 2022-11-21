
local split = vim.split
local uv = vim.loop
local a = require('packer.async')
local log = require('packer.log')
local result = require('packer.result')
local Display = require('packer.display').Display

local M = {JobResult = {}, StdioCallbacks = {}, Opts = {}, }



































local function logging_callback(err_tbl, data_tbl, disp, name)
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


function M.output_table()
   return {
      err = { stdout = {}, stderr = {} },
      data = { stdout = {}, stderr = {} },
   }
end



function M.extend_output(to, from)
   vim.list_extend(to.stdout, from.stdout)
   vim.list_extend(to.stderr, from.stderr)
   return to
end




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

   local timeout = (options).timeout

   if timeout then
      timer = uv.new_timer()
      timer:start(timeout, 0, function()
         timer:stop()

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


local function was_successful(r)
   if r.exit_code == 0 then
      return result.ok(r)
   end
   return result.err(r)
end

local function setup_pipe(kind, callbacks, capture_output, output)
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



M.run = a.wrap(function(task, opts, callback)

   local job_result = { exit_code = -1, signal = -1 }
   local success_test = opts.success_test or was_successful
   local output = M.output_table()
   local callbacks = {}

   local stdout = setup_pipe('stdout', callbacks, opts.capture_output, output)

   if stdout == false then
      callback(success_test(job_result))
      return
   end

   stdout = stdout

   local stderr = setup_pipe('stderr', callbacks, opts.capture_output, output)

   if stderr == false then
      callback(success_test(job_result))
      return
   end

   stderr = stderr

   if type(task) == "string" then
      local shell = os.getenv('SHELL') or vim.o.shell
      local minus_c = shell:find('cmd.exe$') and '/c' or '-c'
      task = { shell, minus_c, task }
   end

   task = task

   spawn(task[1], {
      args = { unpack(task, 2) },
      stdio = { nil, stdout, stderr },
      cwd = opts.cwd,
      timeout = opts.timeout and 1000 * opts.timeout or nil,
      env = opts.env,
      hide = true,
   }, function(exit_code, signal)
      job_result = { exit_code = exit_code, signal = signal }
      if opts.capture_output == true then
         job_result.output = output
      end
      callback(success_test(job_result))
   end)

   for kind, pipe in pairs({ stdout = stdout, stderr = stderr }) do
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

return M