local a      = require 'packer.async'
local config = require 'packer.config'
local jobs   = require 'packer.jobs'
local log    = require 'packer.log'
local result = require 'packer.result'
local util   = require 'packer.util'

local void = a.void
local async = a.sync

local fmt = string.format

---@type PluginHandler
local M = {}

local function ensure_git_env()
  if M.job_env then
    return
  end

  local blocked_env_vars = {
    GIT_DIR = true,
    GIT_INDEX_FILE = true,
    GIT_OBJECT_DIRECTORY = true,
    GIT_TERMINAL_PROMPT = true,
    GIT_WORK_TREE = true,
    GIT_COMMON_DIR = true,
  }

  local job_env = {}
  for k, v in pairs(vim.fn.environ()) do
    if not blocked_env_vars[k] then
      job_env[#job_env+1] = k .. '=' .. v
    end
  end

  job_env[#job_env+1] = 'GIT_TERMINAL_PROMPT=0'

  M.job_env = job_env
end

---@param tag string
---@return boolean
local function has_wildcard(tag)
  return tag and tag:match('*') ~= nil
end

local BREAK_TAG_PAT          = '[[bB][rR][eE][aA][kK]!?:]'
local BREAKING_CHANGE_PAT    = '[[bB][rR][eE][aA][kK][iI][nN][gG][ _][cC][hH][aA][nN][gG][eE]]'
local TYPE_EXCLAIM_PAT       = '[[a-zA-Z]+!:]'
local TYPE_SCOPE_EXPLAIN_PAT = '[[a-zA-Z]+%([^)]+%)!:]'

---@param commit_bodies string[]
local function get_breaking_commits(commit_bodies)
  local ret = {}
  local commits = vim.gsplit(table.concat(commit_bodies, '\n'), '===COMMIT_START===', true)
  for commit in commits do
    local commit_parts = vim.split(commit, '===BODY_START===')
    local body = commit_parts[2]
    local lines = vim.split(commit_parts[1], '\n')
    local is_breaking = (
      body ~= nil
      and (
        (body:match(BREAKING_CHANGE_PAT) ~= nil)
        or (body:match(BREAK_TAG_PAT) ~= nil)
        or (body:match(TYPE_EXCLAIM_PAT) ~= nil)
        or (body:match(TYPE_SCOPE_EXPLAIN_PAT) ~= nil)
      )
    )
      or (
        lines[2] ~= nil
        and (
          (lines[2]:match(BREAKING_CHANGE_PAT) ~= nil)
          or (lines[2]:match(BREAK_TAG_PAT) ~= nil)
          or (lines[2]:match(TYPE_EXCLAIM_PAT) ~= nil)
          or (lines[2]:match(TYPE_SCOPE_EXPLAIN_PAT) ~= nil)
        )
      )
    if is_breaking then
      ret[#ret+1] = lines[1]
    end
  end
  return ret
end

ensure_git_env()

local function git_run(args, opts)
  opts.env = opts.env or M.job_env
  return jobs.run({ config.git.cmd, unpack(args) }, opts)
end

local function checkout(ref, opts, disp)
  if disp then
    disp:task_update(fmt('checking out %s...', ref))
  end
  return git_run({'checkout',  ref, '--' }, opts)
end

--- @async
--- @param plugin PluginSpec
--- @return Result
local handle_checkouts = void(function(plugin, disp, opts)
  local function update_disp(msg)
    if disp then
      disp:task_update(plugin.full_name, msg)
    end
  end

  update_disp('fetching reference...')

  local output = jobs.output_table()

  local job_opts = {
    capture_output = {
      stdout = jobs.logging_callback(output.err.stdout, output.data.stdout, disp, plugin.full_name),
      stderr = jobs.logging_callback(output.err.stderr, output.data.stderr),
    },
    cwd = plugin.install_path
  }

  local r = result.ok()

  if plugin.tag and has_wildcard(plugin.tag) then
    update_disp(fmt('getting tag for wildcard %s...', plugin.tag))
    r = git_run({
      'tag', '-l', plugin.tag,
      '--sort', '-version:refname'
    }, job_opts)
    local data = output.data.stdout[1]
    if data then
      plugin.tag = vim.split(data, '\n')[1]
    else
      log.warn(fmt(
        'Wildcard expansion did not found any tag for plugin %s: defaulting to latest commit...',
        plugin.name
      ))
      plugin.tag = nil -- Wildcard is not found, then we bypass the tag
    end
  end

  if r.ok and (plugin.branch or (plugin.tag and not opts.preview_updates)) then
    local branch_or_tag = plugin.branch or plugin.tag
    r = checkout(branch_or_tag, job_opts, disp)
    if r.err then
      r.err = {
        msg = fmt(
          'Error checking out %s %s for %s',
          plugin.branch and 'branch' or 'tag',
          branch_or_tag,
          plugin.full_name
        ),
        data = r.err,
        output = output,
      }
    end
  end

  if r.ok and plugin.commit then
    r = checkout(plugin.commit, job_opts, disp)
    if r.err then
      r.err = {
        msg = fmt('Error checking out commit %s for %s', plugin.commit, plugin.full_name),
        data = r.err,
        output = output,
      }
    end
  end

  if r.ok then
    r.ok = { status = r.ok, output = output }
  elseif r.err.msg then
    r.err.output = output
  else
    r.err = {
      msg = fmt('Error updating %s: %s', plugin.full_name, table.concat(r.err, '\n')),
      data = r.err,
      output = output,
    }
  end

  return r
end)

local split_messages = function(messages)
  local lines = {}
  for _, message in ipairs(messages) do
    vim.list_extend(lines, vim.split(message, '\n'))
    table.insert(lines, '')
  end
  return lines
end

---@param plugin PluginSpec
---@param disp Display
---@param preview_updates boolean
---@return Result
local function mark_breaking_changes(plugin, disp, exit_ok, preview_updates)
  local commit_bodies = { err = {}, output = {} }
  local commit_bodies_onread = jobs.logging_callback(commit_bodies.err, commit_bodies.output)

  disp:task_update(plugin.name, 'checking for breaking changes...')
  local r = git_run({
    'log',
    '--color=never',
    '--no-show-signature',
    '--pretty=format:===COMMIT_START===%h%n%s===BODY_START===%b',
    preview_updates and 'HEAD...FETCH_HEAD' or 'HEAD@{1}...HEAD'
  }, {
    success_test = exit_ok,
    capture_output = {
      stdout = commit_bodies_onread,
      stderr = commit_bodies_onread
    },
    cwd = plugin.install_path
  })
  if r.ok then
    plugin.breaking_commits = get_breaking_commits(commit_bodies.output)
  end
  return r
end

---@param plugin PluginSpec
---@return PluginFuns
function M.setup(plugin)

  ---@type PluginFuns
  local fn = {}

  local needs_checkout = plugin.tag ~= nil or plugin.commit ~= nil or plugin.branch ~= nil

  ---@async
  ---@param disp Display
  ---@return Result
  fn.installer = async(function(disp)
    local install_cmd = {
      'clone',
      '--depth', plugin.commit and 999999 or config.git.depth,
      '--no-single-branch',
      '--progress'
    }

    if plugin.branch or (plugin.tag and not has_wildcard(plugin.tag)) then
      vim.list_extend(install_cmd, { '--branch', plugin.branch or plugin.tag })
    end

    vim.list_extend(install_cmd, { plugin.url, plugin.install_path })

    local output = jobs.output_table()

    local installer_opts = {
      capture_output = {
        stdout = jobs.logging_callback(output.err.stdout, output.data.stdout),
        stderr = jobs.logging_callback(output.err.stderr, output.data.stderr, disp, plugin.full_name),
      },
      timeout = config.git.clone_timeout
    }

    disp:task_update(plugin.full_name, 'cloning...')
    local r = git_run(install_cmd, installer_opts)
    if r.err then
      r.err = {
        msg = fmt('Error cloning plugin %s to %s', plugin.full_name, plugin.install_path),
        data = { r.err, output },
      }
      return r
    end

    installer_opts.cwd = plugin.install_path

    if r.ok and plugin.commit then
      r = checkout(plugin.commit, installer_opts, disp)
      if r.err then
        r.err = {
          msg = fmt('Error checking out commit %s for %s', plugin.commit, plugin.full_name),
          data = { r.err, output },
        }
      end
    end

    if r.ok then
      -- Get current commit
      r = git_run({
        'log',
        '--color=never',
        '--pretty=format:%h %s (%cr)',
        '--no-show-signature',
        'HEAD',
        '-n', '1'
      }, installer_opts)
    end

    if r.ok then
      plugin.messages = output.data.stdout
    else
      plugin.output = { err = output.data.stderr }
      if not r.err.msg then
        r.err = {
          msg = fmt('Error installing %s: %s', plugin.full_name, table.concat(output.data.stderr, '\n')),
          data = { r.err, output },
        }
      end
    end

    return r
  end, 1)

  ---@async
  ---@return Result
  fn.remote_url = async(function()
    local r = git_run({ 'remote', 'get-url', 'origin' }, {
      capture_output = true,
      cwd = plugin.install_path
    })

    if r.ok then
      r.ok = { remote = r.ok.output.data.stdout[1] }
    end

    return r
  end)

  ---@async
  ---@param disp Display
  ---@param opts { pull_head: boolean, preview_updates: boolean}
  ---@return Result
  fn.updater = async(function(disp, opts)
    local update_info = {
      err      = {},
      revs     = {},
      output   = {},
      messages = {}
    }

    local function exit_ok(r)
      if #update_info.err > 0 or r.exit_code ~= 0 then
        return result.err(r)
      end
      return result.ok(r)
    end

    local rev_onread = jobs.logging_callback(update_info.err, update_info.revs)
    local rev_callbacks = {
      stdout = rev_onread,
      stderr = rev_onread
    }

    disp:task_update(plugin.full_name, 'checking current commit...')
    local r = git_run({ 'rev-parse', '--short', 'HEAD' }, {
      success_test = exit_ok,
      capture_output = rev_callbacks,
      cwd = plugin.install_path
    })

    if r.err then
      plugin.output = { err = vim.list_extend(update_info.err, update_info.revs), data = {} }
      r.err = {
        msg = fmt('Error getting current commit for %s: %s', plugin.full_name, table.concat(update_info.revs, '\n')),
        data = r.err,
      }
    end

    local current_branch
    disp:task_update(plugin.full_name, 'checking current branch...')
    if r.ok then
      -- local branch_cmd = {config.git.cmd, 'rev-parse', '--abbrev-ref', 'HEAD'}
      r = git_run({ 'branch', '--show-current' }, {
        success_test = exit_ok,
        capture_output = true,
        cwd = plugin.install_path
      })
      if r.ok then
        current_branch = r.ok.output.data.stdout[1]
      else
        r.err = {
          msg = fmt('Error checking current branch for %s: %s', plugin.full_name, table.concat(update_info.revs, '\n')),
          data = r.err,
        }
      end
    end

    if not needs_checkout then
      local origin_branch = ''
      disp:task_update(plugin.full_name, 'checking origin branch...')
      local origin_refs_path = util.join_paths(plugin.install_path, '.git', 'refs', 'remotes', 'origin', 'HEAD')
      local origin_refs_file = vim.loop.fs_open(origin_refs_path, 'r', 438)
      if origin_refs_file ~= nil then
        local origin_refs_stat = vim.loop.fs_fstat(origin_refs_file)
        -- NOTE: This should check for errors
        local origin_refs = vim.split(vim.loop.fs_read(origin_refs_file, origin_refs_stat.size, 0), '\n')
        vim.loop.fs_close(origin_refs_file)
        if #origin_refs > 0 then
          origin_branch = string.match(origin_refs[1], [[^ref: refs/remotes/origin/(.*)]])
        end
      end

      if current_branch ~= origin_branch then
        needs_checkout = true
        plugin.branch = origin_branch
      end
    end

    local update_opts = {
      success_test = exit_ok,
      capture_output = {
        stdout = jobs.logging_callback(update_info.err, update_info.output, disp, plugin.full_name),
        stderr = jobs.logging_callback(update_info.err, update_info.output, disp, plugin.full_name),
      },
      cwd = plugin.install_path
    }

    if needs_checkout then
      if r.ok then
        r = git_run({ 'fetch', '--depth', '999999', '--progress' }, update_opts)
        if r.ok then
          r = handle_checkouts(plugin, disp, opts)
        end
      end

      local function merge_output(res)
        if res.output ~= nil then
          vim.list_extend(update_info.err, res.output.err.stderr)
          vim.list_extend(update_info.err, res.output.err.stdout)
          vim.list_extend(update_info.output, res.output.data.stdout)
          vim.list_extend(update_info.output, res.output.data.stderr)
        end
      end

      merge_output(r.ok or r.err)

      if r.err then
        plugin.output = { err = vim.list_extend(update_info.err, update_info.output), data = {} }
        local errmsg = '<unknown error>'
        if r.err.msg ~= nil then
          errmsg = r.err.msg
        end
        r.err = {
          msg = errmsg .. ' ' .. table.concat(update_info.output, '\n'),
          data = r.err.data
        }
      end
    end

    if r.ok then
      local fetch_cmd = { 'fetch', '--depth', '999999', '--progress' }

      local cmd, msg
      if opts.preview_updates then
        cmd = fetch_cmd
        msg = 'fetching updates...'
      elseif opts.pull_head then
        cmd = { 'merge', 'FETCH_HEAD' }
        msg = 'pulling updates from head...'
      elseif plugin.commit or plugin.tag then
        cmd = fetch_cmd
        msg = 'pulling updates...'
      else
        cmd = { 'pull', '--ff-only', '--progress', '--rebase=false' }
        msg = 'pulling updates...'
      end

      disp:task_update(plugin.full_name, msg)
      r = git_run(cmd, update_opts)
    else
      plugin.output = { err = vim.list_extend(update_info.err, update_info.output), data = {} }
      r.err = {
        msg = fmt('Error getting updates for %s: %s', plugin.full_name, table.concat(update_info.output, '\n')),
        data = r.err,
      }
    end

    if r.ok then
      -- NOTE that any tag wildcard should already been expanded to a specific commit at this point
      local ref = plugin.tag ~= nil and fmt('%s^{}', plugin.tag)
        or opts.preview_updates and 'FETCH_HEAD'
        or 'HEAD'

      disp:task_update(plugin.full_name, 'checking updated commit...')
      r = git_run({ 'rev-parse', '--short', ref }, {
        success_test = exit_ok,
        capture_output = rev_callbacks,
        cwd = plugin.install_path
      })
      if r.err then
        plugin.output = { err = vim.list_extend(update_info.err, update_info.revs), data = {} }
        r.err = {
          msg = fmt('Error checking updated commit for %s: %s', plugin.full_name, table.concat(update_info.revs, '\n')),
          data = r.err,
        }
      end
    end

    if not r.ok then
      plugin.output.err = vim.list_extend(plugin.output.err, update_info.messages)
    elseif update_info.revs[1] == update_info.revs[2] then
      plugin.revs = update_info.revs
      plugin.messages = update_info.messages
    else
      local commit_headers_onread = jobs.logging_callback(update_info.err, update_info.messages)

      disp:task_update(plugin.full_name, 'getting commit messages...')
      r = git_run({
        'log',
        '--color=never',
        '--pretty=format:%h %s (%cr)',
        '--no-show-signature',
        fmt('%s...%s',  update_info.revs[1], update_info.revs[2])
      }, {
        success_test = exit_ok,
        capture_output = {
          stdout = commit_headers_onread,
          stderr = commit_headers_onread
        },
        cwd = plugin.install_path,
      })

      plugin.output = { err = update_info.err, data = update_info.output }

      if r.ok then
        plugin.messages = update_info.messages
        plugin.revs = update_info.revs
        if config.git.mark_breaking_changes then
          r = mark_breaking_changes(plugin, disp, exit_ok, opts.preview_updates)
        end
      end
    end

    r.info = update_info
    return r
  end, 2)

  ---@async
  ---@return Result
  fn.diff = async(function(commit, callback)
    local diff_info = { err = {}, output = {}, messages = {} }
    local diff_onread = jobs.logging_callback(diff_info.err, diff_info.messages)
    local r = git_run({
      'show', '--no-color',
      '--pretty=medium',
      commit
    }, {
      capture_output = {
        stdout = diff_onread,
        stderr = diff_onread
      },
      cwd = plugin.install_path
    })

    if r.ok then
      r = callback(split_messages(diff_info.messages))
    else
      r = callback(nil, r.err)
    end

    return r
  end, 2)

  ---@async
  ---@return Result
  fn.revert_last = async(function()
    local r = git_run({ 'reset', '--hard', 'HEAD@{1}' }, {
      capture_output = true,
      cwd = plugin.install_path
    })
    if needs_checkout and r.ok then
      r = handle_checkouts(plugin, nil, {})
      if r.ok then
        log.info('Reverted update for ' .. plugin.full_name)
      else
        log.error(fmt('Reverting update for %s failed!', plugin.full_name))
      end
    end
    return r
  end)

  ---Reset the plugin to `commit`
  ---@async
  ---@param commit string
  ---@return Result
  fn.revert_to = async(function(commit)
    assert(type(commit) == 'string', fmt("commit: string expected but '%s' provided", type(commit)))
    require('packer.log').debug(fmt("Reverting '%s' to commit '%s'", plugin.name, commit))
    return git_run({ 'reset', '--hard', commit, '--' }, {
      capture_output = true,
      cwd = plugin.install_path
    })
  end, 1)

  ---Returns HEAD's short hash
  ---@async
  ---@return Result
  fn.get_rev = async(function()
    local r = git_run({ 'rev-parse', '--short', 'HEAD' }, {
      cwd = plugin.install_path,
      capture_output = true
    })

    if r.ok then
      r.ok.data = next(r.ok.output.data.stdout)
    else
      r.err.msg = fmt('%s: %s', plugin.full_name, next(r.err.output.data.stderr))
    end

    return r
  end, 1)

  return fn
end

return M
