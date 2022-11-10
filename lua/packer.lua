local api = vim.api
local fn = vim.fn
local fmt = string.format

local util = require 'packer.util'
local join_paths = util.join_paths

local a = require 'packer.async'

-- Config
local packer = {}

---@class DisplayConfig
---@field open_fn string
---@field open_cmd string

---@class Config
---@field max_jobs        integer
---@field start_dir       string
---@field opt_dir         string
---@field snapshot_path   string
---@field preview_updates boolean
---@field auto_clean      boolean
---@field autoremove      boolean
---@field display         DisplayConfig
---@field snapshot        string
---@field git             table
local config

---@class PluginSpec
---@field name         string
---@field path         string
---@field short_name   string
---@field install_path string
---@field keys         string|string[]
---@field event        string|string[]
---@field ft           string|string[]
---@field cmd          string|string[]
---@field type         string
---@field url          string
---@field from_requires boolean
---@field after_files  string[]
---@field breaking_commits string[]
---@field opt          boolean
---@field remote_url   function
---@field installer    function

---@class PluginData
---@field line integer
---@field spec PluginSpec

---@class Results
---@field removals {[string]: Result}
---@field installs {[string]: Result}
---@field moves    {[string]: Result}
---@field updates  {[string]: Result}
---@field plugins  {[string]: PluginSpec}

---@type table<string, PluginSpec>
local plugins = nil

---@type PluginData[]
local plugin_specifications = nil

local display

---@module 'packer.install'
local install

---@module 'packer.log'
local log

---@module 'packer.plugin_types'
local plugin_types

---@module 'packer.plugin_utils'
local plugin_utils

---@module 'packer.update'
local update

---@module 'packer.snapshot'
local snapshot

local function init_modules()
  local function require_and_configure(module_name)
    local module = require('packer.' .. module_name)
    module.cfg(config)
    return module
  end
  display      = require_and_configure 'display'
  install      = require_and_configure 'install'
  log          = require_and_configure 'log'
  plugin_types = require_and_configure 'plugin_types'
  plugin_utils = require_and_configure 'plugin_utils'
  snapshot     = require_and_configure 'snapshot'
  update       = require_and_configure 'update'
  init_modules = function() end
end

local function make_commands()
  for _, cmd in ipairs {
    { 'PackerSnapshot'         , '+', snapshot.snapshot, snapshot.completion.create   },
    { 'PackerSnapshotRollback' , '+', snapshot.rollback, snapshot.completion.rollback },
    { 'PackerSnapshotDelete'   , '+', snapshot.delete  , snapshot.completion.snapshot },
    { 'PackerInstall'          , '*', packer.install   , packer.plugin_complete },
    { 'PackerUpdate'           , '*', packer.update    , packer.plugin_complete },
    { 'PackerSync'             , '*', packer.sync      , packer.plugin_complete },
    { 'PackerClean'            , '*', packer.clean },
    { 'PackerStatus'           , '*', packer.status },
  } do
    api.nvim_create_user_command(cmd[1], function(args)
      cmd[3](unpack(args.fargs))
    end, { nargs = cmd[2], complete = cmd[4] })
  end
end

---@return string, string
local function guess_plugin_type(path)
  if fn.isdirectory(path) ~= 0 then
    return path, 'local'
  end

  if vim.startswith(path, 'git://')
    or vim.startswith(path, 'http')
    or path:match('@') then
    return path, 'git'
  end

  ---@diagnostic disable-next-line
  path = table.concat(vim.split(path, '\\', true), '/')
  return config.git.default_url_format:format(path), 'git'
end

--- The main logic for adding a plugin (and any dependencies) to the managed set
-- Can be invoked with (1) a single plugin spec as a string, (2) a single plugin spec table, or (3)
-- a list of plugin specs
-- TODO: This should be refactored into its own module and the various keys should be implemented
-- (as much as possible) as ordinary handlers
---@param plugin_data PluginData
local function process_plugin_spec(plugin_data)
  local spec = plugin_data.spec
  local spec_line = plugin_data.line

  if type(spec) == 'table' and #spec > 1 then
    for _, s in ipairs(spec) do
      process_plugin_spec { spec = s, line = spec_line }
    end
    return
  end

  if type(spec) == 'string' then
    spec = { spec }
  end

  if spec[1] == nil then
    log.warn(fmt('No plugin name provided at line %s!', spec_line))
    return
  end

  local short_name, path = util.get_plugin_short_name(spec[1])

  if short_name == '' then
    log.warn(fmt('"%s" is an invalid plugin name!', spec[1]))
    return
  end

  if plugins[short_name] and not plugins[short_name].from_requires then
    log.warn(fmt('Plugin "%s" is used twice! (line %s)', short_name, spec_line))
    return
  end

  -- Handle aliases
  spec.short_name = short_name
  spec.name = path
  spec.path = path

  -- Some config keys modify a plugin type
  if spec.opt then
    spec.manual_opt = true
  end

  if spec.keys or spec.ft or spec.cmd or spec.event then
    spec.opt = true
  end

  -- Normalize
  for _, cond in ipairs{'cmd', 'keys', 'ft', 'event'} do
    if type(spec[cond]) == 'string' then
      spec[cond] = { spec[cond] }
    end
  end

  spec.install_path = join_paths(spec.opt and config.opt_dir or config.start_dir, short_name)

  spec.url, spec.type = guess_plugin_type(spec.path)

  -- Add the git URL for displaying in PackerStatus and PackerSync.
  spec.url = util.remove_ending_git_url(spec.url)

  plugin_types[spec.type].setup(spec)

  plugins[short_name] = spec

  if spec.requires then
    -- Handle single plugins given as strings or single plugin specs given as tables
    if type(spec.requires) == 'string' or (
        type(spec.requires) == 'table'
        and not vim.tbl_islist(spec.requires)
        and #spec.requires == 1
      ) then
      spec.requires = { spec.requires }
    end

    for _, req in ipairs(spec.requires) do
      if type(req) == 'string' then
        req = { req }
      end
      ---@diagnostic disable-next-line
      local req_name_segments = vim.split(req[1], '/')
      local req_name = req_name_segments[#req_name_segments]
      -- this flag marks a plugin as being from a require which we use to allow
      -- multiple requires for a plugin without triggering a duplicate warning *IF*
      -- the plugin is from a `requires` field and the full specificaiton has not been called yet.
      -- @see: https://github.com/wbthomason/packer.nvim/issues/258#issuecomment-876568439
      req.from_requires = true
      if not plugins[req_name] then
        if spec.manual_opt then
          req.opt = true
          req.after = spec.short_name
        end

        process_plugin_spec { spec = req, line = spec_line }
      end
    end
  end
end

--- Add a plugin to the managed set
---@param plugin_spec PluginSpec
local function use(plugin_spec)
  plugin_specifications[#plugin_specifications + 1] = {
    spec = plugin_spec,
    line = debug.getinfo(2, 'l').currentline,
  }
end

packer.__use = use

local function process_plugin_specs()
  log.debug 'Processing plugin specs'
  if plugins == nil or next(plugins) == nil then
    for _, spec in ipairs(plugin_specifications) do
      process_plugin_spec(spec)
    end
  end
end

-- Use by tests
packer.__manage_all = process_plugin_specs

--- Clean operation:
-- Finds plugins present in the `packer` package but not in the managed set
---@async
---@param results Results
packer.clean = a.sync(function(results)
  process_plugin_specs()
  local fs_state = plugin_utils.get_fs_state(plugins)
  require('packer.clean')(plugins, fs_state, results, config.autoremove)
end, 1)

local function reltime(start)
  if start == nil then
    ---@diagnostic disable-next-line
    return fn.reltime()
  end
  ---@diagnostic disable-next-line
  return fn.reltime(start)
end

--- Install operation:
-- Installs missing plugins, then updates helptags and rplugins
---@async
packer.install = a.sync(function()
  log.debug 'packer.install: requiring modules'

  process_plugin_specs()
  local fs_state = plugin_utils.get_fs_state(plugins)
  local install_plugins = vim.tbl_keys(fs_state.missing)
  if #install_plugins == 0 then
    log.info 'All configured plugins are installed'
    return
  end

  a.main()
  local start_time = reltime()

  ---@type Results
  local results = {}

  require('packer.clean')(plugins, fs_state, results, config.autoremove)
  a.main()
  log.debug 'Gathering install tasks'
  local tasks, display_win = install(plugins, install_plugins, results)
  if next(tasks) then
    local function check()
      return not display.status.running
    end
    local limit = config.max_jobs and config.max_jobs or #tasks
    log.debug 'Running tasks'
    display_win:update_headline_message(fmt('installing %d / %d plugins', #tasks, #tasks))
    a.join(limit, check, unpack(tasks))
    local install_paths = {}
    for plugin_name, r in pairs(results.installs) do
      if r.ok then
        table.insert(install_paths, results.plugins[plugin_name].install_path)
      end
    end

    a.main()
    plugin_utils.update_helptags(install_paths)
    plugin_utils.update_rplugins()
    local delta = string.gsub(fn.reltimestr(reltime(start_time)), ' ', '')
    display_win:final_results(results, delta)
  else
    log.info 'Nothing to install!'
  end
end)

-- Filter out options specified as the first argument to update or sync
-- returns the options table and the plugin names
local function filter_opts_from_plugins(...)
  local args = { ... }
  local opts = {}
  if not vim.tbl_isempty(args) then
    local first = args[1]
    if type(first) == 'table' then
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
  return opts, #args > 0 and args or vim.tbl_keys(plugins)
end

--- Update operation:
-- Takes an optional list of plugin names as an argument. If no list is given, operates on all
-- managed plugins.
-- Fixes plugin types, installs missing plugins, then updates installed plugins and updates helptags
-- and rplugins
-- Options can be specified in the first argument as either a table or explicit `'--preview'`.
---@async
packer.update = a.void(function(...)
  log.debug 'packer.update: requiring modules'

  process_plugin_specs()

  local opts, update_plugins = filter_opts_from_plugins(...)
  local start_time = reltime()
  local results = {}
  local fs_state = plugin_utils.get_fs_state(plugins)
  local missing_plugins, installed_plugins = util.partition(vim.tbl_keys(fs_state.missing), update_plugins)
  update.fix_plugin_types(plugins, missing_plugins, results, fs_state)

  require('packer.clean')(plugins, fs_state, results, config.autoremove)

  missing_plugins = ({util.partition(vim.tbl_keys(results.moves), missing_plugins)})[2]

  log.debug 'Gathering install tasks'
  a.main()
  local tasks, display_win = install(plugins, missing_plugins, results)

  log.debug 'Gathering update tasks'
  a.main()

  local update_tasks
  update_tasks, display_win = update(plugins, installed_plugins, display_win, results, opts)
  vim.list_extend(tasks, update_tasks)

  if #tasks == 0 then
    return
  end

  local function check()
    return not display.status.running
  end
  local limit = config.max_jobs and config.max_jobs or #tasks

  display_win:update_headline_message('updating ' .. #tasks .. ' / ' .. #tasks .. ' plugins')
  log.debug 'Running tasks'
  a.join(limit, check, unpack(tasks))
  local install_paths = {}
  for plugin_name, r in pairs(results.installs) do
    if r.ok then
      table.insert(install_paths, results.plugins[plugin_name].install_path)
    end
  end

  for plugin_name, r in pairs(results.updates) do
    if r.ok then
      table.insert(install_paths, results.plugins[plugin_name].install_path)
    end
  end

  a.main()
  plugin_utils.update_helptags(install_paths)
  local delta = string.gsub(fn.reltimestr(reltime(start_time)), ' ', '')
  display_win:final_results(results, delta, opts)
end)

--- Sync operation:
-- Takes an optional list of plugin names as an argument. If no list is given, operates on all
-- managed plugins.
-- Runs (in sequence):
--  - Update plugin types
--  - Clean stale plugins
--  - Install missing plugins and update installed plugins
--  - Update helptags and rplugins
---@async
packer.sync = a.void(function(...)
  log.debug 'packer.sync: requiring modules'

  process_plugin_specs()

  local opts, sync_plugins = filter_opts_from_plugins(...)
  local start_time = reltime()
  local results = {}
  local fs_state = plugin_utils.get_fs_state(plugins)
  local missing_plugins, installed_plugins = util.partition(vim.tbl_keys(fs_state.missing), sync_plugins)

  a.main()
  update.fix_plugin_types(plugins, missing_plugins, results, fs_state)
  missing_plugins = ({util.partition(vim.tbl_keys(results.moves), missing_plugins)})[2]
  if config.auto_clean then
    require('packer.clean')(plugins, fs_state, results, config.autoremove)
    _, installed_plugins = util.partition(vim.tbl_keys(results.removals), installed_plugins)
  end

  a.main()
  log.debug 'Gathering install tasks'
  local tasks, display_win = install(plugins, missing_plugins, results)
  local update_tasks
  log.debug 'Gathering update tasks'
  a.main()
  update_tasks, display_win = update(plugins, installed_plugins, display_win, results, opts)
  vim.list_extend(tasks, update_tasks)
  if #tasks == 0 then
    return
  end

  local function check()
    return not display.status.running
  end

  local limit = config.max_jobs and config.max_jobs or #tasks

  log.debug 'Running tasks'
  display_win:update_headline_message('syncing ' .. #tasks .. ' / ' .. #tasks .. ' plugins')
  a.join(limit, check, unpack(tasks))
  local install_paths = {}
  for plugin_name, r in pairs(results.installs) do
    if r.ok then
      table.insert(install_paths, results.plugins[plugin_name].install_path)
    end
  end

  for plugin_name, r in pairs(results.updates) do
    if r.ok then
      table.insert(install_paths, results.plugins[plugin_name].install_path)
    end
  end

  a.main()
  plugin_utils.update_helptags(install_paths)
  local delta = string.gsub(fn.reltimestr(reltime(start_time)), ' ', '')
  display_win:final_results(results, delta, opts)
end)

---@async
packer.status = a.sync(function()
  process_plugin_specs()
  local display_win = display.open(config.display.open_fn or config.display.open_cmd)
  if _G.packer_plugins ~= nil then
    display_win:status(_G.packer_plugins)
  else
    log.warn 'packer_plugins table is nil! Cannot run packer.status()!'
  end
end)

local function loader_apply_config(plugin, name)
  if plugin.config and not plugin._done_config then
    plugin._done_config = true
    if type(plugin.config) == 'function' then
      plugin.config()
    else
      loadstring(plugin.config, name..'.config()')()
    end
  end
end

local function packer_load(names)
  local some_unloaded = false
  for i, name in ipairs(names) do
    local plugin = _G.packer_plugins[name]
    if not plugin then
      local err_message = fmt('Error: attempted to load %s which is not present in plugins table!', names[i])
      vim.notify(err_message, vim.log.levels.ERROR, { title = 'packer.nvim' })
      error(err_message)
    end

    if not plugin.loaded then
      -- Set the plugin as loaded before config is run in case something in the config tries to load
      -- this same plugin again
      plugin.loaded = true
      some_unloaded = true
      vim.cmd.packadd(names[i])
      if plugin.after_files then
        for _, file in ipairs(plugin.after_files) do
          vim.cmd.source{file, silent = true}
        end
      end
      loader_apply_config(plugin, names[i])
    end
  end

  if not some_unloaded then
    return
  end
end

-- Completion user plugins
-- Intended to provide completion for PackerUpdate/Sync/Install command
function packer.plugin_complete(lead, _, _)
  local completion_list = vim.tbl_filter(function(name)
    return vim.startswith(name, lead)
  end, vim.tbl_keys(_G.packer_plugins))
  table.sort(completion_list)
  return completion_list
end

---Snapshots installed plugins
---@async
---@param snapshot_name string absolute path or just a snapshot name
packer.snapshot = a.void(function(snapshot_name, ...)
  local args = { ... }
  snapshot_name = snapshot_name or require('os').date '%Y-%m-%d'
  local snapshot_path = fn.expand(snapshot_name)

  log.debug(fmt('Taking snapshots of currently installed plugins to %s...', snapshot_name))
  if fn.fnamemodify(snapshot_name, ':p') ~= snapshot_path then -- is not absolute path
    if config.snapshot_path == nil then
      log.warn 'config.snapshot_path is not set'
      return
    else
      snapshot_path = join_paths(config.snapshot_path, snapshot_path) -- set to default path
    end
  end

  process_plugin_specs()

  local target_plugins = plugins
  if next(args) ~= nil then -- provided extra args
    target_plugins = vim.tbl_filter( -- filter plugins
      function(plugin)
        for k, plugin_shortname in pairs(args) do
          if plugin_shortname == plugin.short_name then
            args[k] = nil
            return true
          end
        end
        return false
      end,
      plugins
    )
  end

  local write_snapshot = true

  if fn.filereadable(snapshot_path) == 1 then
    vim.ui.select(
      { 'Replace', 'Cancel' },
      { prompt = fmt("Do you want to replace '%s'?", snapshot_path) },
      function(_, idx)
        write_snapshot = idx == 1
      end
    )
  end

  if write_snapshot then
    local r = snapshot.create(snapshot_path, target_plugins)
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
---@param snapshot_name string @name of the snapshot or the absolute path to the snapshot
---@vararg string @ if provided, the only plugins to be rolled back,
---otherwise all the plugins will be rolled back
---@async
packer.rollback = a.void(function(snapshot_name, ...)
  local args = { ... }

  process_plugin_specs()

  local snapshot_path = vim.loop.fs_realpath(join_paths(config.snapshot_path, snapshot_name))
    or vim.loop.fs_realpath(snapshot_name)

  if snapshot_path == nil then
    local warn = fmt("Snapshot '%s' is wrong or doesn't exist", snapshot_name)
    log.warn(warn)
    return
  end

  local target_plugins = plugins

  if next(args) ~= nil then -- provided extra args
    target_plugins = vim.tbl_filter(function(plugin)
      for _, plugin_sname in pairs(args) do
        if plugin_sname == plugin.short_name then
          return true
        end
      end
      return false
    end, plugins)
  end

  local r = snapshot.rollback(snapshot_path, target_plugins)

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

packer.config = config

local setup_plugins = {}

function setup_plugins.cmd(cmd_plugins)
  local commands = {}
  for name, plugin in pairs(cmd_plugins) do
    -- TODO(lewis6991): normalize this higher up
    local cmds = plugin.cmd
    if type(cmds) == 'string' then
      cmds = { cmds }
    end
    plugin.commands = cmds

    for _, cmd in ipairs(cmds) do
      commands[cmd] = commands[cmd] or {}
      table.insert(commands[cmd], name)
    end
  end

  for cmd, names in pairs(commands) do
    api.nvim_create_user_command(cmd,
      function(args)
        api.nvim_del_user_command(cmd)

        packer_load(names)

        local lines = args.line1 == args.line2 and '' or (args.line1 .. ',' .. args.line2)
        vim.cmd(fmt(
          '%s %s%s%s %s',
          args.mods or '',
          lines,
          cmd,
          args.bang and '!' or '',
          args.args
        ))
      end,
      { complete = 'file', bang = true, nargs = '*' }
    )
  end
end

function setup_plugins.keys(key_plugins)
  local keymaps = {}
  for name, plugin in pairs(key_plugins) do
    for _, keymap in ipairs(plugin.keys) do
      if type(keymap) == 'string' then
        keymap = { '', keymap }
      end
      keymaps[keymap] = keymaps[keymap] or {}
      table.insert(keymaps[keymap], name)
    end
  end

  for keymap, names in pairs(keymaps) do
    vim.keymap.set(keymap[1], keymap[2], function()
      vim.keymap.del(keymap[1], keymap[2])
      packer_load(names)
      api.nvim_feedkeys(keymap[2], keymap[1], false)
    end, {
        desc = 'Packer lazy load: '..table.concat(names, ', '),
        silent = true
      })
  end
end

local function detect_ftdetect(plugin_path)
  local source_paths = {}
  for _, parts in ipairs{ { 'ftdetect' }, { 'after', 'ftdetect' } } do
    parts[#parts+1] = [[**/*.\(vim\|lua\)]]
    local path = plugin_path .. util.get_separator() .. table.concat(parts, util.get_separator())
    local ok, files = pcall(vim.fn.glob, path, false, true)
    if not ok then
      ---@diagnostic disable-next-line
      if string.find(files, 'E77') then
        source_paths[#source_paths + 1] = path
      else
        error(files)
      end
    elseif #files > 0 then
      ---@diagnostic disable-next-line
      vim.list_extend(source_paths, files)
    end
  end

  return source_paths
end

function setup_plugins.ft(ft_plugins)
  local fts = {}

  local ftdetect_paths = {}

  for name, plugin in pairs(ft_plugins) do
    for _, ft in ipairs(plugin.ft) do
      fts[ft] = fts[ft] or {}
      table.insert(fts[ft], name)
    end

    vim.list_extend(ftdetect_paths, detect_ftdetect(plugin.install_path))
  end

  for ft, names in pairs(fts) do
    api.nvim_create_autocmd('FileType', {
      pattern = ft,
      once = true,
      callback = function()
        packer_load(names)
        for _, group in ipairs{'filetypeplugin', 'filetypeindent', 'syntaxset'} do
          api.nvim_exec_autocmds('FileType', { group = group, pattern = ft, modeline = false })
        end
      end
    })
  end

  if #ftdetect_paths > 0 then
    vim.cmd'augroup filetypedetect'
    for _, path in ipairs(ftdetect_paths) do
      -- 'Sourcing ftdetect script at: ' path, result)
      vim.cmd.source(path)
    end
    vim.cmd'augroup END'
  end

end

function setup_plugins.event(event_plugins)

  local events = {}

  for name, plugin in pairs(event_plugins) do
    for _, event in ipairs(plugin.event) do
      events[event] = events[event] or {}
      table.insert(events[event], name)
    end
  end

  for event, names in pairs(events) do
    api.nvim_create_autocmd(event, {
      once = true,
      callback = function()
        packer_load(names)
        api.nvim_exec_autocmds(event, { modeline = false })
      end
    })
  end
end

local function load_plugin_configs()
  local cond_plugins = {
    cmd   = {},
    keys  = {},
    ft    = {},
    event = {},
  }

  local uncond_plugins = {}

  for name, plugin in pairs(plugins) do
    local has_cond = false
    for _, cond in ipairs{'cmd', 'keys', 'ft', 'event'} do
      if plugin[cond] then
        has_cond = true
        cond_plugins[cond][name] = plugin
        break
      end
    end
    if not has_cond then
      uncond_plugins[name] = plugin
    end
  end

  _G.packer_plugins = plugins

  for name, plugin in pairs(uncond_plugins) do
    loader_apply_config(plugin, name)
  end

  for _, cond in ipairs{'cmd', 'keys', 'ft', 'event'} do
    setup_plugins[cond](cond_plugins[cond])
  end
end

-- Convenience function for simple setup
-- spec can be a table with a table of plugin specifications as its first
-- element, config overrides as another element.
---@param spec table
function packer.startup(spec)
  assert(type(spec) == 'table')
  assert(type(spec[1]) == 'table')

  ---@type PluginSpec
  local user_plugins = spec[1]

  plugins = {}
  plugin_specifications = {}

  ---@type Config
  config = require('packer.config')(spec.config)

  init_modules()

  for _, dir in ipairs{config.opt_dir, config.start_dir} do
    if fn.isdirectory(dir) == 0 then
      fn.mkdir(dir, 'p')
    end
  end

  make_commands()

  if fn.mkdir(config.snapshot_path, 'p') ~= 1 then
    log.warn("Couldn't create " .. config.snapshot_path)
  end

  use(user_plugins)
  process_plugin_specs()
  load_plugin_configs()

  if config.snapshot then
    packer.rollback(config.snapshot)
  end
end

return packer
