local a = require 'packer.async'
local log = require 'packer.log'
local util = require 'packer.util'
local result = require 'packer.result'
local Display = require 'packer.display'.Display

local uv = vim.loop

local record M
  installer   : function(plugin: Plugin, disp: Display): Result<PluginResult>
  updater     : function(plugin: Plugin, disp: Display, opts: table): Result<PluginResult>
  revert_last : function(plugin: Plugin): Result<PluginResult>
  diff        : function(plugin: Plugin, commit: string, callback: function): Result<PluginResult>
  get_rev     : function(plugin: Plugin): string, string
end

-- Due to #679, we know that fs_symlink requires admin privileges on Windows. This is a workaround,
-- as suggested by @nonsleepr.

local symlink_fn: function(string, string, table, function(string, boolean))
if util.is_windows then
  symlink_fn = function(path: string, new_path: string, flags: table, callback: function(string, boolean)): vim.loop.FsT
    flags = flags or {}
    flags.junction = true
    return uv.fs_symlink(path, new_path, flags, callback)
  end
else
  symlink_fn = uv.fs_symlink
end

local symlink = a.wrap(symlink_fn, 4)
local unlink = a.wrap(uv.fs_unlink, 2)

M.installer = a.sync(function(plugin: Plugin, disp: Display): Result<PluginResult>
  local from = uv.fs_realpath(util.strip_trailing_sep(plugin.url))
  local to = util.strip_trailing_sep(plugin.install_path)

  disp:task_update(plugin.full_name, 'making symlink...')
  local err, success = symlink(from, to, { dir = true })
  if not success then
    plugin.err = { err }
    return result.err({msg = err} as PluginResult)
  end
  return result.ok()
end, 2)

M.updater = a.sync(function(plugin: Plugin, disp: Display): Result<PluginResult>
  local from = uv.fs_realpath(util.strip_trailing_sep(plugin.url))
  local to = util.strip_trailing_sep(plugin.install_path)
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
  return result.ok{}
end, 1)

M.revert_last = function(_: Plugin): Result<PluginResult>
  log.warn "Can't revert a local plugin!"
  return result.ok{}
end

M.diff = function(_: Plugin, _: string, _: function): Result<PluginResult>
  log.warn "Can't diff a local plugin!"
  return result.ok{}
end

return M
