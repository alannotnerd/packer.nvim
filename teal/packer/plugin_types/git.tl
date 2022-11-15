local a      = require 'packer.async'
local config = require 'packer.config'
local jobs   = require 'packer.jobs'
local log    = require 'packer.log'
local result = require 'packer.result'
local util   = require 'packer.util'

local void = a.void
local async = a.sync

local fmt = string.format

local record UpdateOpts
  preview_updates: boolean
  pull_head: boolean
end

local record M
  installer   : function(plugin: Plugin, disp: Display): Result<PluginResult>
  updater     : function(plugin: Plugin, disp: Display, opts: table): Result<PluginResult>
  revert_last : function(plugin: Plugin): Result<PluginResult>
  revert_to   : function(plugin: Plugin, commit: string): Result<PluginResult>
  remote_url  : function(plugin: Plugin): string
  diff        : function(plugin: Plugin, commit: string, callback: function): Result<PluginResult>
  get_rev     : function(plugin: Plugin): string, string
  job_env     : {string}
end

local function ensure_git_env()
  if M.job_env then
    return
  end

  local blocked_env_vars: {string:boolean} = {
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

local function has_wildcard(tag: string): boolean
  return tag and tag:match('*') ~= nil
end

local BREAK_TAG_PAT          = '[[bB][rR][eE][aA][kK]!?:]'
local BREAKING_CHANGE_PAT    = '[[bB][rR][eE][aA][kK][iI][nN][gG][ _][cC][hH][aA][nN][gG][eE]]'
local TYPE_EXCLAIM_PAT       = '[[a-zA-Z]+!:]'
local TYPE_SCOPE_EXPLAIN_PAT = '[[a-zA-Z]+%([^)]+%)!:]'

---@param commit_bodies string[]
local function get_breaking_commits(commit_bodies: {string}): {string}
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

local function git_run(args: {string}, opts: jobs.Opts): Result<jobs.JobResult>
  opts.env = opts.env or M.job_env
  return jobs.run({ config.git.cmd, unpack(args) }, opts)
end

local function checkout(ref: string, opts: jobs.Opts, disp: Display): Result<jobs.JobResult>
  if disp then
    disp:task_update(fmt('checking out %s...', ref))
  end
  return git_run({'checkout', ref, '--' }, opts)
end

local function err(t: PluginResult): Result<PluginResult>
  return result.err(t)
end

--- @async
--- @return Result
local handle_checkouts = void(function(plugin: Plugin, disp: Display, opts: UpdateOpts): Result<PluginResult>
  local function update_disp(msg: string)
    if disp then
      disp:task_update(plugin.full_name, msg)
    end
  end

  update_disp('fetching reference...')

  local output = jobs.output_table()

  local job_opts: jobs.Opts = {
    capture_output = {
      stdout = jobs.logging_callback(output.err.stdout, output.data.stdout, disp, plugin.full_name),
      stderr = jobs.logging_callback(output.err.stderr, output.data.stderr),
    },
    cwd = plugin.install_path
  }

  local r: Result<PluginResult> = result.ok{}

  if plugin.tag and has_wildcard(plugin.tag) then
    update_disp(fmt('getting tag for wildcard %s...', plugin.tag))
    local jr = git_run({
      'tag', '-l', plugin.tag,
      '--sort', '-version:refname'
    }, job_opts)
    if jr.ok then
      local data = output.data.stdout[1]
      plugin.tag = vim.split(data, '\n')[1]
    else
      r = err({ output = jr.err.output })
      log.warn(fmt(
        'Wildcard expansion did not found any tag for plugin %s: defaulting to latest commit...',
        plugin.name
      ))
      plugin.tag = nil -- Wildcard is not found, then we bypass the tag
    end
  end

  if r.ok and (plugin.branch or (plugin.tag and not opts.preview_updates)) then
    local branch_or_tag = plugin.branch or plugin.tag
    local jr = checkout(branch_or_tag, job_opts, disp)
    if jr.err then
      r = err{
        msg = fmt(
          'Error checking out %s %s for %s',
          plugin.branch and 'branch' or 'tag',
          branch_or_tag,
          plugin.full_name
        ),
        data = jr.err,
        output = output,
      }
    end
  end

  if r.ok and plugin.commit then
    local jr = checkout(plugin.commit, job_opts, disp)
    if jr.err then
      r = err{
        msg = fmt('Error checking out commit %s for %s', plugin.commit, plugin.full_name),
        data = jr.err,
        output = output,
      }
    end
  end

  if r.ok then
    r.ok = {
      output = output
    }
  elseif r.err.msg then
    r.err.output = output
  else
    r.err = {
      msg = fmt('Error updating %s: %s', plugin.full_name, vim.inspect(r.err)),
      data = r.err,
      output = output,
    }
  end

  return r
end)

local function split_messages(messages: {string}): {string}
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
local function mark_breaking_changes(
  plugin: Plugin,
  disp: Display,
  preview_updates: boolean
): Result<jobs.JobResult>
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

---@async
---@param plugin PluginSpec
---@param disp Display
---@return Result
M.installer = async(function(plugin: Plugin, disp: Display): Result<PluginResult>
  local install_cmd = {
    'clone',
    '--depth', tostring(plugin.commit and 999999 or config.git.depth),
    '--no-single-branch',
    '--progress'
  }

  if plugin.branch or (plugin.tag and not has_wildcard(plugin.tag)) then
    vim.list_extend(install_cmd, { '--branch', plugin.branch or plugin.tag })
  end

  vim.list_extend(install_cmd, { plugin.url, plugin.install_path })

  local output = jobs.output_table()

  local installer_opts: jobs.Opts = {
    capture_output = {
      stdout = jobs.logging_callback(output.err.stdout, output.data.stdout),
      stderr = jobs.logging_callback(output.err.stderr, output.data.stderr, disp, plugin.full_name),
    },
    timeout = config.git.clone_timeout
  }

  local r: Result<PluginResult> = result.ok{}

  disp:task_update(plugin.full_name, 'cloning...')
  do
    local jr = git_run(install_cmd, installer_opts)
    if jr.err then
      r = err{
        msg = fmt('Error cloning plugin %s to %s', plugin.full_name, plugin.install_path),
        data = { r.err, output },
      }
      return r
    end
  end

  installer_opts.cwd = plugin.install_path

  if r.ok and plugin.commit then
    local jr = checkout(plugin.commit, installer_opts, disp)
    if jr.err then
      r = err {
        msg = fmt('Error checking out commit %s for %s', plugin.commit, plugin.full_name),
        data = { r.err, output },
      }
    end
  end

  if r.ok then
    -- Get current commit
    local jr = git_run({
      'log',
      '--color=never',
      '--pretty=format:%h %s (%cr)',
      '--no-show-signature',
      'HEAD',
      '-n', '1'
    }, installer_opts)
    if jr.err then
      r = err {
        msg = 'Error running log',
        data = { r.err, output },
      }
    end
  end

  if r.ok then
    plugin.messages = output.data.stdout
  else
    plugin.err = output.data.stderr
    if not r.err.msg then
      r.err = {
        msg = fmt('Error installing %s: %s', plugin.full_name, table.concat(output.data.stderr, '\n')),
        data = { r.err, output },
      }
    end
  end

  return r
end, 2)

local function get_current_branch(plugin: Plugin): string, string
  -- local branch_cmd = {config.git.cmd, 'rev-parse', '--abbrev-ref', 'HEAD'}
  local jr = git_run({ 'branch', '--show-current' }, {
    capture_output = true,
    cwd = plugin.install_path
  })
  local current_branch, er: string, string
  if jr.ok then
    current_branch = jr.ok.output.data.stdout[1]
  else
    er = table.concat(jr.err.output.data.stderr, '\n')
  end
  return current_branch, er
end

local function get_ref(plugin: Plugin, ref: string): string, string
  local jr = git_run({ 'rev-parse', '--short', ref }, {
    capture_output = true,
    cwd = plugin.install_path
  })

  local ref1, er: string, string
  if jr.ok then
    ref1 = jr.ok.output.data.stdout[1]
  else
    er = table.concat(jr.err.output.data.stderr, '\n')
  end

  return ref1, er
end

local function file_lines(file: string): {string}
  local text: {string} = {}
  for line in io.lines(file) do
    text[#text+1] = line
  end
  return text
end

M.updater = async(function(plugin: Plugin, disp: Display, opts: table): Result<PluginResult>
  local r: Result<PluginResult> = result.ok{}

  plugin.revs = {}

  disp:task_update(plugin.full_name, 'checking current commit...')
  local current_commit, ccerr = get_ref(plugin, 'HEAD')
  if not current_commit or ccerr ~= nil then
    plugin.err = {ccerr}
    return err{
      msg = fmt('Error checking current commit for %s: %s', plugin.full_name, ccerr)
    }
  end

  plugin.revs[1] = current_commit

  disp:task_update(plugin.full_name, 'checking current branch...')
  local current_branch, cberr = get_current_branch(plugin)
  if not current_branch or cberr ~= nil then
    return err {
      msg = fmt('Error checking current branch for %s: %s', plugin.full_name, cberr)
    }
  end

  local needs_checkout = (plugin.tag or plugin.commit or plugin.branch) ~= nil

  if not needs_checkout then
    local origin_branch = ''
    disp:task_update(plugin.full_name, 'checking origin branch...')
    -- TODO(lewis6991): Don't assume 'origin' is the upstream name
    local origin_refs_path = util.join_paths(plugin.install_path, '.git', 'refs', 'remotes', 'origin', 'HEAD')
    if vim.loop.fs_stat(origin_refs_path) then
      local origin_refs = file_lines(origin_refs_path)
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
    capture_output = true,
    cwd = plugin.install_path
  }

  if needs_checkout then
    local jr = git_run({ 'fetch', '--depth', '999999', '--progress' }, update_opts)
    if jr.ok then
      r = handle_checkouts(plugin, disp, opts as UpdateOpts)
    end

    if r.err then
      plugin.err = jr.err.output.data.stderr
      local errmsg = '<unknown error>'
      if r.err.msg ~= nil then
        errmsg = r.err.msg
      end
      return err {
        msg = errmsg .. ' ' .. table.concat(r.err.output.data.stderr, '\n'),
        data = r.err.data
      }
    end
  end

  do
    local fetch_cmd = { 'fetch', '--depth', '999999', '--progress' }

    local cmd, msg: {string}, string
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
    local jr = git_run(cmd, update_opts)
    if jr.err then
      return err {
        msg = fmt('Failed to get updates for %s', plugin.name),
        data = jr.err
      }
    end
  end

  -- NOTE that any tag wildcard should already been expanded to a specific commit at this point
  local ref = plugin.tag ~= nil and fmt('%s^{}', plugin.tag) or 'FETCH_HEAD'

  disp:task_update(plugin.full_name, 'checking updated commit...')
  local new_rev, crerr = get_ref(plugin, ref)
  if crerr then
    plugin.err = {crerr}
    return err {
      msg = fmt('Error checking updated commit for %s: %s', plugin.full_name, crerr),
      data = crerr,
    }
  else
    plugin.revs[2] = new_rev
  end

  if plugin.revs[1] ~= plugin.revs[2] then
    disp:task_update(plugin.full_name, 'getting commit messages...')
    local jr = git_run({
      'log',
      '--color=never',
      '--pretty=format:%h %s (%cr)',
      '--no-show-signature',
      fmt('%s...%s',  plugin.revs[1], plugin.revs[2])
    }, {
      capture_output = true,
      cwd = plugin.install_path,
    })

    if jr.ok then
      plugin.messages = jr.ok.output.data.stdout
      if config.git.mark_breaking_changes then
        jr = mark_breaking_changes(plugin, disp, opts.preview_updates as boolean)
      end
    else
      plugin.err = jr.err.output.data.stderr
    end
  end

  return r
end, 4)

M.remote_url = async(function(plugin: Plugin): string
  local r = git_run({ 'remote', 'get-url', 'origin' }, {
    capture_output = true,
    cwd = plugin.install_path
  })

  if r.ok then
    return r.ok.output.data.stdout[1]
  end
end, 1)

M.diff = async(function(plugin: Plugin, commit: string, callback: function({string}, {string}): Result<PluginResult>): Result<PluginResult>
  local jr = git_run({
    'show', '--no-color',
    '--pretty=medium',
    commit
  }, {
    capture_output = true,
    cwd = plugin.install_path
  })

  if jr.ok then
    return callback(split_messages(jr.ok.output.data.stdout))
  else
    return callback(nil, jr.err.output.data.stderr)
  end
end, 3)

local function topluginres(r: Result<jobs.JobResult>): Result<PluginResult>
  if r.ok then
    return result.ok({
      output = r.ok.output
    } as PluginResult)
  end
  return result.err({
    output = r.ok.output
  } as PluginResult)
end

M.revert_last = async(function(plugin: Plugin): Result<PluginResult>
  local jr = git_run({ 'reset', '--hard', 'HEAD@{1}' }, {
    capture_output = true,
    cwd = plugin.install_path
  })
  local r = topluginres(jr)

  local needs_checkout = (plugin.tag or plugin.commit or plugin.branch) ~= nil
  if needs_checkout and r.ok then
    r = handle_checkouts(plugin, nil, {})
    if r.ok then
      log.info('Reverted update for ' .. plugin.full_name)
    else
      log.error(fmt('Reverting update for %s failed!', plugin.full_name))
    end
  end
  return r
end, 1)

--- Reset the plugin to `commit`
M.revert_to = async(function(plugin: Plugin, commit: string): Result<PluginResult>
  assert(type(commit) == 'string', fmt("commit: string expected but '%s' provided", type(commit)))
  require('packer.log').debug(fmt("Reverting '%s' to commit '%s'", plugin.name, commit))
  return topluginres(git_run({ 'reset', '--hard', commit, '--' }, {
    capture_output = true,
    cwd = plugin.install_path
  }))
end, 2)

--- Returns HEAD's short hash
M.get_rev = async(function(plugin: Plugin): string, string
  return get_ref(plugin, 'HEAD')
end, 1)

return M
