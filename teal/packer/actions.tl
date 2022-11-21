local fn = vim.fn
local fmt = string.format

local a      = require 'packer.async'
local config = require 'packer.config'
local log    = require 'packer.log'
local util   = require 'packer.util'

local display = require 'packer.display'

local Display = display.Display

local record M
  install: function()
  update: function(string|table, ...: string)
  status: function()
  clean: function()
  rollback: function(snapshot_name: string, ...: string)
  snapshot: function(snapshot_name: string, ...: string)
end

local function open_display(): Display
  return display.display.open({
    diff = function(plugin: Plugin, commit: string, callback: function): {string}
      local plugin_type = require'packer.plugin_types'[plugin.type]
      return plugin_type.diff(plugin, commit, callback)
    end,
    revert_last = function(plugin: Plugin)
      local plugin_type = require'packer.plugin_types'[plugin.type]
      plugin_type.revert_last(plugin)
    end,
    update = M.update,
    install = M.install
  })
end

local function run_tasks(tasks: {a.Thunk}, disp: Display): {any}
  if #tasks == 0 then
    print('Nothing to do')
    log.info 'Nothing to do!'
    return
  end

  local function check(): boolean
    return not disp.running
  end

  local limit = config.max_jobs and config.max_jobs or #tasks

  log.debug 'Running tasks'
  disp:update_headline_message(string.format('updating %d / %d plugins', #tasks, #tasks))
  return a.join(limit, check, tasks)
end

local function measure(f: function()): number
  local start_time = vim.loop.hrtime()
  f()
  return (vim.loop.hrtime() - start_time) / 1e9
end

local function helptags_stale(dir: string): boolean
  local glob = fn.glob

  -- Adapted directly from minpac.vim
  local txts = glob(util.join_paths(dir, '*.txt'), true, true)
  vim.list_extend(txts, fn.glob(util.join_paths(dir, '*.[a-z][a-z]x'), true, true))

  if #txts == 0 then
    return false
  end

  local tags = glob(util.join_paths(dir, 'tags'), true, true)
  vim.list_extend(tags, glob(util.join_paths(dir, 'tags-[a-z][a-z]'), true, true))

  if #tags == 0 then
    return true
  end

  local txt_newest = math.max(unpack(vim.tbl_map(fn.getftime, txts)))
  local tag_oldest = math.min(unpack(vim.tbl_map(fn.getftime, tags)))
  return txt_newest > tag_oldest
end

local function update_helptags(results: {string:PluginResult})
  local paths = {}
  for plugin_name, r in pairs(results as {string:PluginResult}) do
    if not r.err then
      paths[#paths+1] = _G.packer_plugins[plugin_name].install_path
    end
  end

  for _, dir in ipairs(paths) do
    local doc_dir = util.join_paths(dir, 'doc')
    if helptags_stale(doc_dir) then
      log.info('Updating helptags for ' .. doc_dir)
      vim.cmd('silent! helptags ' .. fn.fnameescape(doc_dir))
    end
  end
end

--- Install operation:
-- Installs missing plugins, then updates helptags and rplugins
M.install = a.sync(function()
  log.debug 'packer.install: requiring modules'

  local plugin_utils = require('packer.plugin_utils')
  local fs_state = plugin_utils.get_fs_state(_G.packer_plugins)
  local install_plugins = vim.tbl_keys(fs_state.missing)
  if #install_plugins == 0 then
    log.info 'All configured plugins are installed'
    return
  end

  a.main()

  log.debug 'Gathering install tasks'

  local disp = open_display()
  local installs: {string:PluginResult} = {}

  local delta = measure(function()
    local install = require('packer.install')
    local install_tasks = install(_G.packer_plugins, install_plugins, disp, installs)
    run_tasks(install_tasks, disp)

    a.main()
    update_helptags(installs)
  end)

  disp:final_results({installs = installs}, delta)
end)


-- Filter out options specified as the first argument to update or sync
-- returns the options table and the plugin names
local function filter_opts_from_plugins(first: table|string, ...: string): table, {string}
  local args = { ... }
  local opts = {}
  if not vim.tbl_isempty(args) then
    if first is table then
      table.remove(args, 1)
      opts = first
    elseif first == '--preview' then
      table.remove(args, 1)
      opts = { preview_updates = true }
    end
  end
  if config.preview_updates then
    opts.preview_updates = true
  end
  return opts, #args > 0 and args or vim.tbl_keys(_G.packer_plugins)
end

local record Results
  removals : {string}
  installs : {string:PluginResult}
  moves    : {string:PluginResult}
  updates  : {string:PluginResult}
end

--- Update operation:
--- Takes an optional list of plugin names as an argument. If no list is given,
--- operates on all managed plugins. Fixes plugin types, installs missing
--- plugins, then updates installed plugins and updates helptags and rplugins
--- Options can be specified in the first argument as either a table
--- or explicit `'--preview'`.
M.update = a.void(function(first: string|table, ...:string)
  local plugins = _G.packer_plugins
  local opts, update_plugins = filter_opts_from_plugins(first, ...)
  local plugin_utils = require('packer.plugin_utils')
  local fs_state = plugin_utils.get_fs_state(plugins)
  local missing_plugins, installed_plugins = util.partition(vim.tbl_keys(fs_state.missing), update_plugins)

  local update = require('packer.update')

  local results: Results = {
    moves = {},
    removals = {},
    installs = {},
    updates = {}
  }

  update.fix_plugin_types(plugins, missing_plugins, results.moves, fs_state)
  require('packer.clean')(plugins, fs_state, results.removals)

  missing_plugins = ({util.partition(vim.tbl_keys(results.moves), missing_plugins)})[2]

  a.main()

  local disp = open_display()

  local delta = measure(function()
    local tasks = {}

    log.debug 'Gathering install tasks'
    local install_tasks = require('packer.install')(plugins, missing_plugins, disp, results.installs)
    vim.list_extend(tasks, install_tasks)

    log.debug 'Gathering update tasks'
    a.main()

    local update_tasks = update.update(plugins, installed_plugins, disp, results.updates, opts)
    vim.list_extend(tasks, update_tasks)

    run_tasks(tasks, disp)

    a.main()
    update_helptags(vim.tbl_extend('error', results.installs, results.updates))
  end)

  disp:final_results(results, delta)
end)

M.status = a.sync(function()
  if _G.packer_plugins == nil then
    log.warn 'packer_plugins table is nil! Cannot run packer.status()!'
    return
  end

  open_display():set_status(_G.packer_plugins)
end)

--- Clean operation:
-- Finds plugins present in the `packer` package but not in the managed set
M.clean = a.void(function()
  require('packer.clean')(_G.packer_plugins)
end)

---Snapshots installed plugins
M.snapshot = a.void(function(snapshot_name: string, ...:string)
  local args = { ... }
  snapshot_name = snapshot_name or require('os').date '%Y-%m-%d'
  local snapshot_path = fn.expand(snapshot_name)

  log.debug(fmt('Taking snapshots of currently installed plugins to %s...', snapshot_name))
  if fn.fnamemodify(snapshot_name, ':p') ~= snapshot_path then -- is not absolute path
    if config.snapshot_path == nil then
      log.warn 'config.snapshot_path is not set'
      return
    else
      snapshot_path = util.join_paths(config.snapshot_path, snapshot_path) -- set to default path
    end
  end

  local target_plugins = _G.packer_plugins
  if next(args) ~= nil then -- provided extra args
    target_plugins = vim.tbl_filter( -- filter plugins
      function(plugin: Plugin): boolean
        for i, name in ipairs(args) do
          if name == plugin.name then
            args[i] = nil
            return true
          end
        end
        return false
      end,
      _G.packer_plugins
    )
  end

  local write_snapshot = true

  if fn.filereadable(snapshot_path) == 1 then
    vim.ui.select(
      { 'Replace', 'Cancel' },
      { prompt = fmt("Do you want to replace '%s'?", snapshot_path) },
      function(_: string, idx: integer)
        write_snapshot = idx == 1
      end
    )
  end

  if write_snapshot then
    local r = require('packer.snapshot').create(snapshot_path, target_plugins)
    if r.ok then
      log.info(r.ok.message)
      if next(r.ok.failed) then
        log.warn("Couldn't snapshot " .. vim.inspect(r.ok.failed))
      end
    else
      log.warn(r.err.message)
    end
  end
end)

---Instantly rolls back plugins to a previous state specified by `snapshot_name`
---If `snapshot_name` doesn't exist an error will be displayed
M.rollback = a.void(function(snapshot_name: string, ...: string)
  local args = { ... }

  local snapshot_path = vim.loop.fs_realpath(util.join_paths(config.snapshot_path, snapshot_name))
    or vim.loop.fs_realpath(snapshot_name)

  if snapshot_path == nil then
    local warn = fmt("Snapshot '%s' is wrong or doesn't exist", snapshot_name)
    log.warn(warn)
    return
  end

  local target_plugins = _G.packer_plugins

  if next(args) ~= nil then -- provided extra args
    target_plugins = vim.tbl_filter(function(plugin: Plugin): boolean
      for _, plugin_sname in ipairs(args) do
        if plugin_sname == plugin.name then
          return true
        end
      end
      return false
    end, _G.packer_plugins)
  end

  local r = require('packer.snapshot').rollback(snapshot_path, target_plugins)

  if r.ok then
    a.main()
    log.info(fmt('Rollback to "%s" completed', snapshot_path))
    if next(r.ok.failed) then
      log.warn("Couldn't rollback " .. vim.inspect(r.ok.failed))
    end
  else
    a.main()
    log.error(r.err)
  end
end)

return M
