local a = require 'packer.async'
local log = require 'packer.log'
local util = require 'packer.util'
local result = require 'packer.result'

local async = a.sync

local function cfg(_config)
end

-- Due to #679, we know that fs_symlink requires admin privileges on Windows. This is a workaround,
-- as suggested by @nonsleepr.

local symlink_fn
if util.is_windows then
  symlink_fn = function(path, new_path, flags, callback)
    flags = flags or {}
    flags.junction = true
    return vim.loop.fs_symlink(path, new_path, flags, callback)
  end
else
  symlink_fn = vim.loop.fs_symlink
end

local symlink = a.wrap(symlink_fn, 4)
local unlink = a.wrap(vim.loop.fs_unlink, 2)

local function setup_local(plugin)
  local from = vim.loop.fs_realpath(util.strip_trailing_sep(plugin.path))
  local to = util.strip_trailing_sep(plugin.install_path)

  local plugin_name = util.get_plugin_full_name(plugin)
  plugin.installer = function(disp)
    return async(function()
      disp:task_update(plugin_name, 'making symlink...')
      local err, success = symlink(from, to, { dir = true })()
      if not success then
        plugin.output = { err = { err } }
        return result.err(err)
      end
      return result.ok()
    end)
  end

  plugin.updater = async(function(disp)
    local r = result.ok()
    disp:task_update(plugin_name, 'checking symlink...')
    local resolved_path = vim.loop.fs_realpath(to)
    if resolved_path ~= from then
      disp:task_update(plugin_name, 'updating symlink...')
      r = unlink(to)():and_then(symlink(from, to, { dir = true }))
    end

    return r
  end, 1)

  plugin.revert_last = function(_)
    log.warn "Can't revert a local plugin!"
    return result.ok()
  end
end

return { setup = setup_local, cfg = cfg }
