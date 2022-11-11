local a = require 'packer.async'
local log = require 'packer.log'
local util = require 'packer.util'
local result = require 'packer.result'

local uv = vim.loop

-- Due to #679, we know that fs_symlink requires admin privileges on Windows. This is a workaround,
-- as suggested by @nonsleepr.

local symlink_fn
if util.is_windows then
  symlink_fn = function(path, new_path, flags, callback)
    flags = flags or {}
    flags.junction = true
    return uv.fs_symlink(path, new_path, flags, callback)
  end
else
  symlink_fn = uv.fs_symlink
end

local symlink = a.wrap(symlink_fn, 4)
local unlink = a.wrap(uv.fs_unlink, 2)

local M = {}

---@param plugin PluginSpec
function M.setup(plugin)
  local from = uv.fs_realpath(util.strip_trailing_sep(plugin.path))
  local to = util.strip_trailing_sep(plugin.install_path)

  ---@async
  ---@param disp Display
  ---@return Result
  plugin.installer = a.sync(function(disp)
    disp:task_update(plugin.full_name, 'making symlink...')
    local err, success = symlink(from, to, { dir = true })
    if not success then
      plugin.output = { err = { err } }
      return result.err(err)
    end
    return result.ok()
  end)

  ---@async
  ---@param disp Display
  ---@return Result
  plugin.updater = a.sync(function(disp)
    disp:task_update(plugin.full_name, 'checking symlink...')
    local resolved_path = uv.fs_realpath(to)
    if resolved_path ~= from then
      disp:task_update(plugin.full_name, 'updating symlink...')
      local err, success = unlink(to)
      if success then
        err = symlink(from, to, { dir = true })
      end
      if err then
        return result.err(err)
      end
    end
    return result.ok()
  end, 1)

  ---@return Result
  plugin.revert_last = function(_)
    log.warn "Can't revert a local plugin!"
    return result.ok()
  end
end

return M
