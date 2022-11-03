local fn = vim.fn
-- TODO: Performance analysis/tuning
-- TODO: Merge start plugins?
local util = require 'packer.util'

local a = require 'packer.async'
local async = a.sync
local await = a.wait

local join_paths = util.join_paths
local stdpath = fn.stdpath

-- Config
local packer = {}
local config_defaults = {
  ensure_dependencies = true,
  snapshot = nil,
  snapshot_path = join_paths(stdpath 'cache', 'packer.nvim'),
  package_root = join_paths(stdpath 'data', 'site', 'pack'),
  plugin_package = 'packer',
  max_jobs = nil,
  auto_clean = true,
  disable_commands = false,
  preview_updates = false,
  git = {
    mark_breaking_changes = true,
    cmd = 'git',
    subcommands = {
      update = 'pull --ff-only --progress --rebase=false',
      update_head = 'merge FETCH_HEAD',
      install = 'clone --depth %i --no-single-branch --progress',
      fetch = 'fetch --depth 999999 --progress',
      checkout = 'checkout %s --',
      update_branch = 'merge --ff-only @{u}',
      current_branch = 'rev-parse --abbrev-ref HEAD',
      diff = 'log --color=never --pretty=format:FMT --no-show-signature %s...%s',
      diff_fmt = '%%h %%s (%%cr)',
      git_diff_fmt = 'show --no-color --pretty=medium %s',
      get_rev = 'rev-parse --short HEAD',
      get_header = 'log --color=never --pretty=format:FMT --no-show-signature HEAD -n 1',
      get_bodies = 'log --color=never --pretty=format:"===COMMIT_START===%h%n%s===BODY_START===%b" --no-show-signature HEAD@{1}...HEAD',
      get_fetch_bodies = 'log --color=never --pretty=format:"===COMMIT_START===%h%n%s===BODY_START===%b" --no-show-signature HEAD...FETCH_HEAD',
      revert = 'reset --hard HEAD@{1}',
      revert_to = 'reset --hard %s --',
      tags_expand_fmt = 'tag -l %s --sort -version:refname',
    },
    depth = 1,
    clone_timeout = 60,
    default_url_format = 'https://github.com/%s.git',
  },
  display = {
    non_interactive = false,
    compact = false,
    open_fn = nil,
    open_cmd = '65vnew',
    working_sym = '⟳',
    error_sym = '✗',
    done_sym = '✓',
    removed_sym = '-',
    moved_sym = '→',
    item_sym = '•',
    header_sym = '━',
    header_lines = 2,
    title = 'packer.nvim',
    show_all_info = true,
    prompt_border = 'double',
    keybindings = {
      quit = 'q',
      toggle_update = 'u',
      continue = 'c',
      toggle_info = '<CR>',
      diff = 'd',
      prompt_revert = 'r',
      retry = 'R',
    },
  },
  log = { level = 'warn' },
  autoremove = false,
}

--- Initialize global namespace for use for callbacks and other data generated whilst packer is
--- running
_G._packer = _G._packer or {}

local config = vim.tbl_extend('force', {}, config_defaults)
local plugins = nil
local plugin_specifications = nil

local configurable_modules = {
  clean = false,
  display = false,
  install = false,
  plugin_types = false,
  plugin_utils = false,
  update = false,
  log = false,
  snapshot = false,
}

local function require_and_configure(module_name)
  local fully_qualified_name = 'packer.' .. module_name
  local module = require(fully_qualified_name)
  if not configurable_modules[module_name] and module.cfg then
    configurable_modules[module_name] = true
    module.cfg(config)
    return module
  end

  return module
end

--- Initialize packer
-- Forwards user configuration to sub-modules, resets the set of managed plugins, and ensures that
-- the necessary package directories exist
function packer.init(user_config)
  user_config = user_config or {}
  config = util.deep_extend('force', config, user_config)
  packer.reset()
  config.package_root = fn.fnamemodify(config.package_root, ':p')
  config.package_root = string.gsub(config.package_root, util.get_separator() .. '$', '', 1)
  config.pack_dir = join_paths(config.package_root, config.plugin_package)
  config.opt_dir = join_paths(config.pack_dir, 'opt')
  config.start_dir = join_paths(config.pack_dir, 'start')
  if #vim.api.nvim_list_uis() == 0 then
    config.display.non_interactive = true
  end

  local plugin_utils = require_and_configure 'plugin_utils'
  plugin_utils.ensure_dirs()

  require_and_configure 'snapshot'

  if not config.disable_commands then
    packer.make_commands()
  end

  if fn.mkdir(config.snapshot_path, 'p') ~= 1 then
    require_and_configure('log').warn("Couldn't create " .. config.snapshot_path)
  end
end

function packer.make_commands()
  vim.cmd [[command! -nargs=+ -complete=customlist,v:lua.require'packer.snapshot'.completion.create PackerSnapshot  lua require('packer').snapshot(<f-args>)]]
  vim.cmd [[command! -nargs=+ -complete=customlist,v:lua.require'packer.snapshot'.completion.rollback PackerSnapshotRollback  lua require('packer').rollback(<f-args>)]]
  vim.cmd [[command! -nargs=+ -complete=customlist,v:lua.require'packer.snapshot'.completion.snapshot PackerSnapshotDelete lua require('packer.snapshot').delete(<f-args>)]]
  vim.cmd [[command! -nargs=* -complete=customlist,v:lua.require'packer'.plugin_complete PackerInstall lua require('packer').install(<f-args>)]]
  vim.cmd [[command! -nargs=* -complete=customlist,v:lua.require'packer'.plugin_complete PackerUpdate lua require('packer').update(<f-args>)]]
  vim.cmd [[command! -nargs=* -complete=customlist,v:lua.require'packer'.plugin_complete PackerSync lua require('packer').sync(<f-args>)]]
  vim.cmd [[command! PackerClean             lua require('packer').clean()]]
  vim.cmd [[command! PackerStatus            lua require('packer').status()]]
  vim.cmd [[command! -bang -nargs=+ -complete=customlist,v:lua.require'packer'.loader_complete PackerLoad lua require('packer').loader(<f-args>, '<bang>' == '!')]]
end

function packer.reset()
  plugins = {}
  plugin_specifications = {}
end

--- The main logic for adding a plugin (and any dependencies) to the managed set
-- Can be invoked with (1) a single plugin spec as a string, (2) a single plugin spec table, or (3)
-- a list of plugin specs
-- TODO: This should be refactored into its own module and the various keys should be implemented
-- (as much as possible) as ordinary handlers
local function manage(plugin_data)
  local plugin_spec = plugin_data.spec
  local spec_line = plugin_data.line
  local spec_type = type(plugin_spec)
  if spec_type == 'string' then
    plugin_spec = { plugin_spec }
  elseif spec_type == 'table' and #plugin_spec > 1 then
    for _, spec in ipairs(plugin_spec) do
      manage { spec = spec, line = spec_line }
    end
    return
  end

  local log = require_and_configure 'log'
  if plugin_spec[1] == vim.NIL or plugin_spec[1] == nil then
    log.warn('No plugin name provided at line ' .. spec_line .. '!')
    return
  end

  local name, path = util.get_plugin_short_name(plugin_spec)

  if name == '' then
    log.warn('"' .. plugin_spec[1] .. '" is an invalid plugin name!')
    return
  end

  if plugins[name] and not plugins[name].from_requires then
    log.warn('Plugin "' .. name .. '" is used twice! (line ' .. spec_line .. ')')
    return
  end

  -- Handle aliases
  plugin_spec.short_name = name
  plugin_spec.name = path
  plugin_spec.path = path

  if plugin_spec.keys or plugin_spec.ft or plugin_spec.cmd then
    plugin_spec.opt = true
  end

  -- Some config keys modify a plugin type
  if plugin_spec.opt then
    plugin_spec.manual_opt = true
  end

  plugin_spec.install_path = join_paths(plugin_spec.opt and config.opt_dir or config.start_dir, plugin_spec.short_name)

  local plugin_utils = require_and_configure 'plugin_utils'
  local plugin_types = require_and_configure 'plugin_types'
  if not plugin_spec.type then
    plugin_utils.guess_type(plugin_spec)
  end
  if plugin_spec.type ~= plugin_utils.custom_plugin_type then
    plugin_types[plugin_spec.type].setup(plugin_spec)
  end
  plugins[plugin_spec.short_name] = plugin_spec

  -- Add the git URL for displaying in PackerStatus and PackerSync.
  plugins[plugin_spec.short_name].url = util.remove_ending_git_url(plugin_spec.url)

  if plugin_spec.requires and config.ensure_dependencies then
    -- Handle single plugins given as strings or single plugin specs given as tables
    if
      type(plugin_spec.requires) == 'string'
      or (
        type(plugin_spec.requires) == 'table'
        and not vim.tbl_islist(plugin_spec.requires)
        and #plugin_spec.requires == 1
      )
    then
      plugin_spec.requires = { plugin_spec.requires }
    end
    for _, req in ipairs(plugin_spec.requires) do
      if type(req) == 'string' then
        req = { req }
      end
      local req_name_segments = vim.split(req[1], '/')
      local req_name = req_name_segments[#req_name_segments]
      -- this flag marks a plugin as being from a require which we use to allow
      -- multiple requires for a plugin without triggering a duplicate warning *IF*
      -- the plugin is from a `requires` field and the full specificaiton has not been called yet.
      -- @see: https://github.com/wbthomason/packer.nvim/issues/258#issuecomment-876568439
      req.from_requires = true
      if not plugins[req_name] then
        if plugin_spec.manual_opt then
          req.opt = true
          req.after = plugin_spec.short_name
        end

        if plugin_spec.disable then
          req.disable = true
        end

        manage { spec = req, line = spec_line }
      end
    end
  end
end

--- Add a plugin to the managed set
function packer.use(plugin_spec)
  plugin_specifications[#plugin_specifications + 1] = {
    spec = plugin_spec,
    line = debug.getinfo(2, 'l').currentline,
  }
end

local function manage_all_plugins()
  local log = require_and_configure 'log'
  log.debug 'Processing plugin specs'
  if plugins == nil or next(plugins) == nil then
    for _, spec in ipairs(plugin_specifications) do
      manage(spec)
    end
  end
end

-- Use by tests
packer.__manage_all = manage_all_plugins

--- Clean operation:
-- Finds plugins present in the `packer` package but not in the managed set
function packer.clean(results)
  local plugin_utils = require_and_configure 'plugin_utils'
  local clean = require_and_configure 'clean'
  require_and_configure 'display'

  manage_all_plugins()
  async(function()
    local fs_state = await(plugin_utils.get_fs_state(plugins))
    await(clean(plugins, fs_state, results))
  end)()
end

local function reltime(start)
  if start == nil then
    return fn.reltime()
  end
  return fn.reltime(start)
end

--- Install operation:
-- Takes an optional list of plugin names as an argument. If no list is given, operates on all
-- managed plugins.
-- Installs missing plugins, then updates helptags and rplugins
function packer.install(...)
  local log = require_and_configure 'log'
  log.debug 'packer.install: requiring modules'
  local plugin_utils = require_and_configure 'plugin_utils'
  local clean = require_and_configure 'clean'
  local install = require_and_configure 'install'
  local display = require_and_configure 'display'

  manage_all_plugins()
  local install_plugins
  if ... then
    install_plugins = { ... }
  end
  async(function()
    local fs_state = await(plugin_utils.get_fs_state(plugins))
    if not install_plugins then
      install_plugins = vim.tbl_keys(fs_state.missing)
    end
    if #install_plugins == 0 then
      log.info 'All configured plugins are installed'
      return
    end

    await(a.main)
    local start_time = reltime()
    local results = {}
    await(clean(plugins, fs_state, results))
    await(a.main)
    log.debug 'Gathering install tasks'
    local tasks, display_win = install(plugins, install_plugins, results)
    if next(tasks) then
      table.insert(tasks, 1, function()
        return not display.status.running
      end)
      table.insert(tasks, 1, config.max_jobs and config.max_jobs or (#tasks - 1))
      log.debug 'Running tasks'
      display_win:update_headline_message('installing ' .. #tasks - 2 .. ' / ' .. #tasks - 2 .. ' plugins')
      a.interruptible_wait_pool(unpack(tasks))
      local install_paths = {}
      for plugin_name, r in pairs(results.installs) do
        if r.ok then
          table.insert(install_paths, results.plugins[plugin_name].install_path)
        end
      end

      await(a.main)
      plugin_utils.update_helptags(install_paths)
      plugin_utils.update_rplugins()
      local delta = string.gsub(fn.reltimestr(reltime(start_time)), ' ', '')
      display_win:final_results(results, delta)
    else
      log.info 'Nothing to install!'
    end
  end)()
end

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
  if opts.preview_updates == nil and config.preview_updates then
    opts.preview_updates = true
  end
  return opts, util.nonempty_or(args, vim.tbl_keys(plugins))
end

--- Update operation:
-- Takes an optional list of plugin names as an argument. If no list is given, operates on all
-- managed plugins.
-- Fixes plugin types, installs missing plugins, then updates installed plugins and updates helptags
-- and rplugins
-- Options can be specified in the first argument as either a table or explicit `'--preview'`.
function packer.update(...)
  local log = require_and_configure 'log'
  log.debug 'packer.update: requiring modules'
  local plugin_utils = require_and_configure 'plugin_utils'
  local clean = require_and_configure 'clean'
  local install = require_and_configure 'install'
  local display = require_and_configure 'display'
  local update = require_and_configure 'update'

  manage_all_plugins()

  local opts, update_plugins = filter_opts_from_plugins(...)
  async(function()
    local start_time = reltime()
    local results = {}
    local fs_state = await(plugin_utils.get_fs_state(plugins))
    local missing_plugins, installed_plugins = util.partition(vim.tbl_keys(fs_state.missing), update_plugins)
    update.fix_plugin_types(plugins, missing_plugins, results, fs_state)
    await(clean(plugins, fs_state, results))
    local _
    _, missing_plugins = util.partition(vim.tbl_keys(results.moves), missing_plugins)
    log.debug 'Gathering install tasks'
    await(a.main)
    local tasks, display_win = install(plugins, missing_plugins, results)
    local update_tasks
    log.debug 'Gathering update tasks'
    await(a.main)
    update_tasks, display_win = update(plugins, installed_plugins, display_win, results, opts)
    vim.list_extend(tasks, update_tasks)

    if #tasks == 0 then
      return
    end

    table.insert(tasks, 1, function()
      return not display.status.running
    end)
    table.insert(tasks, 1, config.max_jobs and config.max_jobs or (#tasks - 1))
    display_win:update_headline_message('updating ' .. #tasks - 2 .. ' / ' .. #tasks - 2 .. ' plugins')
    log.debug 'Running tasks'
    a.interruptible_wait_pool(unpack(tasks))
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

    await(a.main)
    plugin_utils.update_helptags(install_paths)
    plugin_utils.update_rplugins()
    local delta = string.gsub(fn.reltimestr(reltime(start_time)), ' ', '')
    display_win:final_results(results, delta, opts)
  end)()
end

--- Sync operation:
-- Takes an optional list of plugin names as an argument. If no list is given, operates on all
-- managed plugins.
-- Runs (in sequence):
--  - Update plugin types
--  - Clean stale plugins
--  - Install missing plugins and update installed plugins
--  - Update helptags and rplugins
function packer.sync(...)
  local log = require_and_configure 'log'
  log.debug 'packer.sync: requiring modules'
  local plugin_utils = require_and_configure 'plugin_utils'
  local clean = require_and_configure 'clean'
  local install = require_and_configure 'install'
  local display = require_and_configure 'display'
  local update = require_and_configure 'update'

  manage_all_plugins()

  local opts, sync_plugins = filter_opts_from_plugins(...)
  async(function()
    local start_time = reltime()
    local results = {}
    local fs_state = await(plugin_utils.get_fs_state(plugins))
    local missing_plugins, installed_plugins = util.partition(vim.tbl_keys(fs_state.missing), sync_plugins)

    await(a.main)
    update.fix_plugin_types(plugins, missing_plugins, results, fs_state)
    local _
    _, missing_plugins = util.partition(vim.tbl_keys(results.moves), missing_plugins)
    if config.auto_clean then
      await(clean(plugins, fs_state, results))
      _, installed_plugins = util.partition(vim.tbl_keys(results.removals), installed_plugins)
    end

    await(a.main)
    log.debug 'Gathering install tasks'
    local tasks, display_win = install(plugins, missing_plugins, results)
    local update_tasks
    log.debug 'Gathering update tasks'
    await(a.main)
    update_tasks, display_win = update(plugins, installed_plugins, display_win, results, opts)
    vim.list_extend(tasks, update_tasks)
    if #tasks == 0 then
      return
    end

    table.insert(tasks, 1, function()
      return not display.status.running
    end)
    table.insert(tasks, 1, config.max_jobs and config.max_jobs or (#tasks - 1))
    log.debug 'Running tasks'
    display_win:update_headline_message('syncing ' .. #tasks - 2 .. ' / ' .. #tasks - 2 .. ' plugins')
    a.interruptible_wait_pool(unpack(tasks))
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

    await(a.main)
    plugin_utils.update_helptags(install_paths)
    plugin_utils.update_rplugins()
    local delta = string.gsub(fn.reltimestr(reltime(start_time)), ' ', '')
    display_win:final_results(results, delta, opts)
  end)()
end

function packer.status()
  local display = require_and_configure 'display'
  local log = require_and_configure 'log'
  manage_all_plugins()
  async(function()
    local display_win = display.open(config.display.open_fn or config.display.open_cmd)
    if _G.packer_plugins ~= nil then
      display_win:status(_G.packer_plugins)
    else
      log.warn 'packer_plugins table is nil! Cannot run packer.status()!'
    end
  end)()
end

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

local packer_load

packer_load = function(names)
  local some_unloaded = false
  local needs_bufread = false
  for i, name in ipairs(names) do
    local plugin = _G.packer_plugins[name]
    if not plugin then
      local err_message = 'Error: attempted to load ' .. names[i] .. ' which is not present in plugins table!'
      vim.notify(err_message, vim.log.levels.ERROR, { title = 'packer.nvim' })
      error(err_message)
    end

    if not plugin.loaded then
      -- Set the plugin as loaded before config is run in case something in the config tries to load
      -- this same plugin again
      plugin.loaded = true
      some_unloaded = true
      needs_bufread = needs_bufread or plugin.needs_bufread
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

  if needs_bufread then
    if _G._packer and _G._packer.inside_compile == true then
      -- delaying BufRead to end of packer_compiled
      _G._packer.needs_bufread = true
    else
      vim.cmd 'doautocmd BufRead'
    end
  end
end

-- Load plugins
-- @param plugins string String of space separated plugins names
--                      intended for PackerLoad command
--                or list of plugin names as independent strings
function packer.loader(...)
  local plugin_names = { ... }
  if type(plugin_names[#plugin_names]) == 'boolean' then
    plugin_names[#plugin_names] = nil
  end

  -- We make a new table here because it's more convenient than expanding a space-separated string
  -- into the existing plugin_names
  local plugin_list = {}
  for _, plugin_name in ipairs(plugin_names) do
    vim.list_extend(
      plugin_list,
      vim.tbl_filter(function(name)
        return #name > 0
      end, vim.split(plugin_name, ' '))
    )
  end

  packer_load(plugin_list)
end

-- Completion for not yet loaded plugins
-- Intended to provide completion for PackerLoad command
function packer.loader_complete(lead, _, _)
  local completion_list = {}
  for name, plugin in pairs(_G.packer_plugins) do
    if vim.startswith(name, lead) and not plugin.loaded then
      table.insert(completion_list, name)
    end
  end
  table.sort(completion_list)
  return completion_list
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
---@param snapshot_name string absolute path or just a snapshot name
function packer.snapshot(snapshot_name, ...)
  local snapshot = require 'packer.snapshot'
  local log = require_and_configure 'log'
  local args = { ... }
  snapshot_name = snapshot_name or require('os').date '%Y-%m-%d'
  local snapshot_path = fn.expand(snapshot_name)

  local fmt = string.format
  log.debug(fmt('Taking snapshots of currently installed plugins to %s...', snapshot_name))
  if fn.fnamemodify(snapshot_name, ':p') ~= snapshot_path then -- is not absolute path
    if config.snapshot_path == nil then
      log.warn 'config.snapshot_path is not set'
      return
    else
      snapshot_path = util.join_paths(config.snapshot_path, snapshot_path) -- set to default path
    end
  end

  manage_all_plugins()

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

  async(function()
    if write_snapshot then
      await(snapshot.create(snapshot_path, target_plugins))
        :map_ok(function(ok)
          log.info(ok.message)
          if next(ok.failed) then
            log.warn("Couldn't snapshot " .. vim.inspect(ok.failed))
          end
        end)
        :map_err(function(err)
          log.warn(err.message)
        end)
    end
  end)()
end

---Instantly rolls back plugins to a previous state specified by `snapshot_name`
---If `snapshot_name` doesn't exist an error will be displayed
---@param snapshot_name string @name of the snapshot or the absolute path to the snapshot
---@vararg string @ if provided, the only plugins to be rolled back,
---otherwise all the plugins will be rolled back
function packer.rollback(snapshot_name, ...)
  local args = { ... }
  local snapshot = require 'packer.snapshot'
  local log = require_and_configure 'log'
  local fmt = string.format

  async(function()
    manage_all_plugins()

    local snapshot_path = vim.loop.fs_realpath(util.join_paths(config.snapshot_path, snapshot_name))
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

    await(snapshot.rollback(snapshot_path, target_plugins))
      :map_ok(function(ok)
        await(a.main)
        log.info('Rollback to "' .. snapshot_path .. '" completed')
        if next(ok.failed) then
          log.warn("Couldn't rollback " .. vim.inspect(ok.failed))
        end
      end)
      :map_err(function(err)
        await(a.main)
        log.error(err)
      end)
  end)()
end

packer.config = config

local function setup_cmd_plugins(cmd_plugins)
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
    vim.api.nvim_create_user_command(cmd,
      function(args)
        vim.api.nvim_del_user_command(cmd)

        packer_load(names)

        local lines = args.line1 == args.line2 and '' or (args.line1 .. ',' .. args.line2)
        vim.cmd(string.format(
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

local function setup_key_plugins(key_plugins)
  local keymaps = {}
  for name, plugin in pairs(key_plugins) do
    if type(plugin.keys) == 'string' then
      plugin.keys = { plugin.keys }
    end

    for _, keymap in ipairs(plugin.keys) do
      if type(keymap) == 'string' then
        keymap = { '', keymap }
      end
      keymaps[keymap] = keymaps[keymap] or {}
      table.insert(keymaps[keymap], name)
    end
  end

  for keymap, names in pairs(keymaps) do
    local prefix = nil
    if keymap[1] ~= 'i' then
      prefix = ''
    end

    vim.keymap.set(keymap[1], keymap[2], function()
      vim.keymap.del(keymap[1], keymap[2])
      packer_load(names)
    end, {
        desc = 'Packer lazy load: '..table.concat(names, ', '),
        silent = true
      })
  end
end

local ftdetect_patterns = {
  table.concat({ 'ftdetect', [[**/*.\(vim\|lua\)]] }, util.get_separator()),
  table.concat({ 'after', 'ftdetect', [[**/*.\(vim\|lua\)]] }, util.get_separator()),
}

local function detect_ftdetect(name, plugin_path)
  local paths = {
    plugin_path .. util.get_separator() .. ftdetect_patterns[1],
    plugin_path .. util.get_separator() .. ftdetect_patterns[2],
  }
  local source_paths = {}
  for i = 1, 2 do
    local path = paths[i]
    local glob_ok, files = pcall(vim.fn.glob, path, false, true)
    if not glob_ok then
      if string.find(files, 'E77') then
        source_paths[#source_paths + 1] = path
      else
        log.error('Error compiling ' .. name .. ': ' .. vim.inspect(files))
        error(files)
      end
    elseif #files > 0 then
      vim.list_extend(source_paths, files)
    end
  end

  return source_paths
end


local function setup_ft_plugins(ft_plugins)
  local fts = {}

  local ftdetect_paths = {}

  for name, plugin in pairs(ft_plugins) do
    if type(plugin.ft) == 'string' then
      plugin.ft = { plugin.ft }
    end
    for _, ft in ipairs(plugin.ft) do
      fts[ft] = fts[ft] or {}
      table.insert(fts[ft], name)
    end

    vim.list_extend(ftdetect_paths, detect_ftdetect(name, plugin.install_path))
  end

  for ft, names in pairs(fts) do
    vim.api.nvim_create_autocmd('FileType', {
      pattern = ft,
      once = true,
      callback = function()
        packer_load(names)
        for _, group in ipairs{'filetypeplugin', 'filetypeindent', 'syntaxset'} do
          vim.api.nvim_exec_autocmds('FileType', { group = group, pattern = ft, modeline = false })
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

local function setup_event_plugins(event_plugins)

  local events = {}

  for name, plugin in pairs(event_plugins) do
    -- TODO(lewis6991): support patterns
    if type(plugin.event) == 'string' then
      plugin.event = { plugin.event }
    end

    for _, event in ipairs(plugin.event) do
      events[event] = events[event] or {}
      table.insert(events[event], name)
    end
  end

  for event, names in pairs(events) do
    vim.api.nvim_create_autocmd(event, {
      once = true,
      callback = function()
        packer_load(names)
        vim.api.nvim_exec_autocmds(event, { modeline = false })
      end
    })
  end
end

local function setup_uncond_plugin(uncond_plugins)
  for name, plugin in pairs(uncond_plugins) do
    if plugin.config and not plugin._done_config then
      plugin._done_config = true
      if type(plugin.config) == 'function' then
        plugin.config()
      else
        loadstring(plugin.config, name..'.config()')()
      end
    end
  end
end

local function load_plugin_configs()
  local cond_plugins = {
    cmd  = {},
    keys = {},
    ft   = {},
  }

  local uncond_plugins = {}

  for name, plugin in pairs(plugins) do
    if not plugin.disable then
      local has_cond = false
      for _, cond in ipairs{'cmd', 'keys', 'ft'} do
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
  end

  _G.packer_plugins = plugins

  setup_uncond_plugin(uncond_plugins)
  setup_cmd_plugins(cond_plugins.cmd)
  setup_key_plugins(cond_plugins.keys)
  setup_ft_plugins(cond_plugins.ft)
end

-- Convenience function for simple setup
-- spec can be a table with a table of plugin specifications as its first
-- element, config overrides as another element.
function packer.startup(spec)
  assert(type(spec) == 'table')
  assert(type(spec[1]) == 'table')
  local user_plugins = spec[1]

  packer.init(spec.config)
  packer.reset()
  require_and_configure 'log'
  packer.use(user_plugins)
  manage_all_plugins()
  load_plugin_configs()

  if config.snapshot then
    packer.rollback(config.snapshot)
  end
end

return packer
