local util = require 'packer.util'

local join_paths = util.join_paths

local default_config = {
  ensure_dependencies = true,
  snapshot = nil,
  snapshot_path = join_paths(vim.fn.stdpath 'cache', 'packer.nvim'),
  package_root = join_paths(vim.fn.stdpath 'data', 'site', 'pack'),
  plugin_package = 'packer',
  max_jobs = nil,
  auto_clean = true,
  disable_commands = false,
  preview_updates = false,
  git = {
    mark_breaking_changes = true,
    cmd = 'git',
    subcommands = {
      install = 'clone --depth %i --no-single-branch --progress',
      checkout = 'checkout %s --',
      update_branch = 'merge --ff-only @{u}',
      diff_fmt = '%%h %%s (%%cr)',
      git_diff_fmt = 'show --no-color --pretty=medium %s',
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

local config = vim.tbl_extend('force', {}, default_config)

---@param user_config Config
---@return Config
local function set(_, user_config)
  config = util.deep_extend('force', config, user_config or {})
  config.package_root = vim.fn.fnamemodify(config.package_root, ':p')
  config.package_root = config.package_root:gsub(util.get_separator() .. '$', '', 1)
  config.pack_dir = join_paths(config.package_root, config.plugin_package)
  config.opt_dir = join_paths(config.pack_dir, 'opt')
  config.start_dir = join_paths(config.pack_dir, 'start')

  if #vim.api.nvim_list_uis() == 0 then
    config.display.non_interactive = true
  end

  return config
end

---@class DisplayConfig
---@field open_fn string
---@field open_cmd string
---@field preview_updates boolean
---@field non_interactive boolean
---@field prompt_border string
---@field compact boolean
---@field working_sym string
---@field error_sym   string
---@field done_sym    string
---@field removed_sym string
---@field moved_sym   string
---@field item_sym    string
---@field header_sym  string
---@field header_lines integer
---@field title       string
---@field show_all_info boolean
---@field keybindings {[string]: string}

---@class GitSubCommandsConfig
---@field install          string
---@field fetch            string
---@field checkout         string
---@field update_branch    string
---@field diff_fmt         string
---@field git_diff_fmt     string
---@field get_bodies       string
---@field get_fetch_bodies string
---@field revert           string
---@field revert_to        string
---@field tags_expand_fmt  string

---@class GitConfig
---@field mark_breaking_changes boolean
---@field cmd                   string
---@field depth                 integer
---@field clone_timeout         integer
---@field default_url_format    string
---@field subcommands GitSubCommandsConfig

---@class Config
---@field package_root    string
---@field pack_dir        string
---@field max_jobs        integer
---@field start_dir       string
---@field opt_dir         string
---@field snapshot_path   string
---@field preview_updates boolean
---@field auto_clean      boolean
---@field autoremove      boolean
---@field display         DisplayConfig
---@field snapshot        string
---@field git             GitConfig
---@field log             { level: string }
---@operator call:Config
local M = {}

setmetatable(M, {
  __index = function(_, k)
    return config[k]
  end,
  __call = set
})

return M
