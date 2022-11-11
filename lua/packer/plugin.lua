local util   = require 'packer.util'
local log    = require 'packer.log'
local config = require('packer.config')
local plugin_types = require 'packer.plugin_types'

local fmt = string.format

---@class PluginSpec
---@field name         string
---@field full_name    string Include rev and branch
---@field path         string
---@field short_name   string
---@field branch       string
---@field rev          string
---@field tag          string
---@field commit       string
---@field install_path string
---@field keys         string|string[]
---@field event        string|string[]
---@field ft           string|string[]
---@field cmd          string|string[]
---@field type         string
---@field url          string
---@field lock         boolean
---@field from_requires boolean
---@field after_files  string[]
---@field breaking_commits string[]
---@field opt          boolean
---@field remote_url   function
---@field installer    function
---@field updater      fun(Display, table)
---@field revert_to    function

---@return string, string
local function guess_plugin_type(path)
  if vim.fn.isdirectory(path) ~= 0 then
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

---@param text string
---@return string, string
local function get_plugin_short_name(text)
  local path = vim.fn.expand(text)
  local name_segments = vim.split(path, util.get_separator())
  local segment_idx = #name_segments
  local name = name_segments[segment_idx]
  while name == '' and segment_idx > 0 do
    name = name_segments[segment_idx]
    segment_idx = segment_idx - 1
  end
  return name, path
end

local function get_plugin_full_name(plugin)
  local plugin_name = plugin.name or plugin.short_name
  if plugin.branch then
    -- NOTE: maybe have to change the seperator here too
    plugin_name = plugin_name .. '/' .. plugin.branch
  end

  if plugin.rev then
    plugin_name = plugin_name .. '@' .. plugin.rev
  end

  return plugin_name
end


---@param url string
local function remove_ending_git_url(url)
  return vim.endswith(url, '.git') and url:sub(1, -5) or url
end

local M = {}

--- The main logic for adding a plugin (and any dependencies) to the managed set
-- Can be invoked with (1) a single plugin spec as a string, (2) a single plugin spec table, or (3)
-- a list of plugin specs
-- TODO: This should be refactored into its own module and the various keys should be implemented
-- (as much as possible) as ordinary handlers
---@param plugin_data PluginData
local function process_spec(plugin_data, plugins)
  local spec = plugin_data.spec
  local spec_line = plugin_data.line

  if type(spec) == 'table' and #spec > 1 then
    for _, s in ipairs(spec) do
      process_spec({ spec = s, line = spec_line }, plugins)
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

  local short_name, path = get_plugin_short_name(spec[1])

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
  spec.path = path
  spec.full_name = get_plugin_full_name(spec)

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

  spec.install_path = util.join_paths(spec.opt and config.opt_dir or config.start_dir, short_name)

  spec.url, spec.type = guess_plugin_type(spec.path)

  -- Add the git URL for displaying in PackerStatus and PackerSync.
  spec.url = remove_ending_git_url(spec.url)

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

        process_spec({ spec = req, line = spec_line }, plugins)
      end
    end
  end
end

function M.process_spec(spec)
  local plugins = {}
  process_spec(spec, plugins)
  return plugins
end


return M
