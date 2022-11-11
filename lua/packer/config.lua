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
  log = { level = 'info' },
  autoremove = false,
}

local config = vim.tbl_extend('force', {}, default_config)

return function(user_config)
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
