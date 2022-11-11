local a = require 'packer.async'
local util = require 'packer.util'
local log = require 'packer.log'
local plugin_utils = require 'packer.plugin_utils'
local result = require 'packer.result'
local async = a.sync
local fmt = string.format
local uv = vim.loop

local config = require'packer.config'

local M = {
  completion = {},
}

--- Completion for listing snapshots in `config.snapshot_path`
--- Intended to provide completion for PackerSnapshotDelete command
M.completion.snapshot = function(lead, _, _)
  local completion_list = {}
  if config.snapshot_path == nil then
    return completion_list
  end

  local dir = uv.fs_opendir(config.snapshot_path)

  if dir ~= nil then
    local res = uv.fs_readdir(dir)
    while res ~= nil do
      for _, entry in ipairs(res) do
        if entry.type == 'file' and vim.startswith(entry.name, lead) then
          completion_list[#completion_list + 1] = entry.name
        end
      end

      res = uv.fs_readdir(dir)
    end
  end

  uv.fs_closedir(dir)
  return completion_list
end

-- Completion user plugins
-- Intended to provide completion for PackerUpdate/Sync/Install command
local function plugin_complete(lead, _, _)
  local completion_list = vim.tbl_filter(function(name)
    return vim.startswith(name, lead)
  end, vim.tbl_keys(_G.packer_plugins))
  table.sort(completion_list)
  return completion_list
end

--- Completion for listing single plugins before taking snapshot
--- Intended to provide completion for PackerSnapshot command
M.completion.create = function(lead, cmdline, pos)
  local cmd_args = (vim.fn.split(cmdline, ' '))

  if #cmd_args > 1 then
    return plugin_complete(lead, cmdline, pos)
  end

  return {}
end

--- Completion for listing snapshots in `config.snapshot_path` and single plugins after
--- the first argument is provided
--- Intended to provide completion for PackerSnapshotRollback command
M.completion.rollback = function(lead, cmdline, pos)
  local cmd_args = vim.split(cmdline, ' ')

  if #cmd_args > 2 then
    return plugin_complete(lead)
  else
    return M.completion.snapshot(lead, cmdline, pos)
  end
end

---Creates a with with `completed` and `failed` keys, each containing a map with plugin name as key and commit hash/error as value
---@async
---@param plugins PluginSpec[]
---@return Result
local generate_snapshot = async(function(plugins)
  local completed = {}
  local failed = {}
  local opt, start = plugin_utils.list_installed_plugins()
  local installed = vim.tbl_extend('error', start, opt)

  plugins = vim.tbl_filter(function(plugin)
    if installed[plugin.install_path] and plugin.type == 'git' then
      return true
    end
    return false
  end, plugins)

  for _, plugin in pairs(plugins) do
    local rev = plugin.get_rev()

    if rev.err then
      failed[plugin.short_name] =
        fmt("Snapshotting %s failed because of error '%s'", plugin.short_name, vim.inspect(rev.err.msg))
    else
      completed[plugin.short_name] = { commit = rev.ok.data }
    end
  end

  return result.ok { failed = failed, completed = completed }
end, 1)

---Serializes a table of git-plugins with `short_name` as table key and another
---table with `commit`; the serialized tables will be written in the path `snapshot_path`
---provided, if there is already a snapshot it will be overwritten
---Snapshotting work only with git plugins,
---other will be ignored.
---@async
---@param snapshot_path string realpath for snapshot file
---@param plugins PluginSpec[]
---@return Result
M.create = async(function(snapshot_path, plugins)
  assert(type(snapshot_path) == 'string', fmt("filename needs to be a string but '%s' provided", type(snapshot_path)))
  assert(type(plugins) == 'table', fmt("plugins needs to be an array but '%s' provided", type(plugins)))
  local commits = generate_snapshot(plugins)

  a.main()
  local snapshot_content = vim.fn.json_encode(commits.ok.completed)

  local status, res = pcall(function()
    return vim.fn.writefile({ snapshot_content }, snapshot_path) == 0
  end)

  if status and res then
    return result.ok {
      message = fmt("Snapshot '%s' complete", snapshot_path),
      completed = commits.ok.completed,
      failed = commits.ok.failed,
    }
  else
    return result.err {
      message = fmt("Error on creation of snapshot '%s': '%s'", snapshot_path, res)
    }
  end
end, 2)

local fetch = async(function(cwd)
  local git = require 'packer.plugin_types.git'
  return require('packer.jobs').run('git ' .. config.git.subcommands.fetch, {
    capture_output = true,
    cwd = cwd,
    env = git.job_env
  })
end, 1)

---Rollbacks `plugins` to the hash specified in `snapshot_path` if exists.
---It automatically runs `git fetch --depth 999999 --progress` to retrieve the history
---@param snapshot_path string @ realpath to the snapshot file
---@param plugins table<string, PluginSpec> @ of git plugins
---@return Result
M.rollback = async(function(snapshot_path, plugins)
  assert(type(snapshot_path) == 'string', 'snapshot_path: expected string but got ' .. type(snapshot_path))
  assert(type(plugins) == 'table', 'plugins: expected table but got ' .. type(snapshot_path))
  log.debug('Rolling back to ' .. snapshot_path)

  ---@type string[]
  local content = vim.fn.readfile(snapshot_path)

  local plugins_snapshot = vim.fn.json_decode(content) --[[@as {[string]: PluginSpec}?]]
  if not plugins_snapshot then -- not valid snapshot file
    return result.err(fmt("Couldn't load '%s' file", snapshot_path))
  end

  local completed = {}
  local failed = {}

  for _, plugin in pairs(plugins) do
    if plugins_snapshot[plugin.short_name] then
      local commit = plugins_snapshot[plugin.short_name].commit
      if commit then
        local r = fetch(plugin.install_path)
        if r.ok then
          r = plugin.revert_to(commit)
        end

        if r.ok then
          completed[plugin.short_name] = r.ok
        else
          failed[plugin.short_name] = failed[plugin.short_name] or {}
          table.insert(failed[plugin.short_name], r.err)
        end
      end
    end
  end

  return result.ok {
    completed = completed,
    failed    = failed
  }
end, 2)

---Deletes the snapshot provided
---@param snapshot_name string absolute path or just a snapshot name
function M.delete(snapshot_name)
  assert(type(snapshot_name) == 'string', fmt('Expected string, got %s', type(snapshot_name)))
  local snapshot_path = uv.fs_realpath(snapshot_name)
    or uv.fs_realpath(util.join_paths(config.snapshot_path, snapshot_name))

  if snapshot_path == nil then
    log.warn(fmt("Snapshot '%s' is wrong or doesn't exist", snapshot_name))
    return
  end

  log.debug('Deleting ' .. snapshot_path)
  if uv.fs_unlink(snapshot_path) then
    log.info('Deleted ' .. snapshot_path)
  else
    log.warn("Couldn't delete " .. snapshot_path)
  end
end

return M
