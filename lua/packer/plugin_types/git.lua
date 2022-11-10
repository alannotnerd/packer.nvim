local util = require 'packer.util'
local jobs = require 'packer.jobs'
local a = require 'packer.async'
local void = require 'packer.async'.void
local result = require 'packer.result'
local log = require 'packer.log'
local async = a.sync
local fmt = string.format

local vim = vim

local git = {}

local BLOCKED_ENV_VARS = {
  GIT_DIR = true,
  GIT_INDEX_FILE = true,
  GIT_OBJECT_DIRECTORY = true,
  GIT_TERMINAL_PROMPT = true,
  GIT_WORK_TREE = true,
  GIT_COMMON_DIR = true,
}

local function ensure_git_env()
  if git.job_env == nil then
    local job_env = {}
    for k, v in pairs(vim.fn.environ()) do
      if not BLOCKED_ENV_VARS[k] then
        table.insert(job_env, k .. '=' .. v)
      end
    end

    table.insert(job_env, 'GIT_TERMINAL_PROMPT=0')
    git.job_env = job_env
  end
end

---@param tag string
---@return boolean
local function has_wildcard(tag)
  if not tag then
    return false
  end
  return string.match(tag, '*') ~= nil
end

local BREAK_TAG_PAT          = '[[bB][rR][eE][aA][kK]!?:]'
local BREAKING_CHANGE_PAT    = '[[bB][rR][eE][aA][kK][iI][nN][gG][ _][cC][hH][aA][nN][gG][eE]]'
local TYPE_EXCLAIM_PAT       = '[[a-zA-Z]+!:]'
local TYPE_SCOPE_EXPLAIN_PAT = '[[a-zA-Z]+%([^)]+%)!:]'

---@param plugin PluginSpec
---@param commit_bodies string[]
local function mark_breaking_commits(plugin, commit_bodies)
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
      plugin.breaking_commits[#plugin.breaking_commits + 1] = lines[1]
    end
  end
end

local config = nil
git.cfg = function(_config)
  config = _config.git
  config.base_dir = _config.package_root
  config.default_base_dir = util.join_paths(config.base_dir, _config.plugin_package)
  config.exec_cmd = config.cmd .. ' '
  ensure_git_env()
end

---Resets a git repo `dest` to `commit`
---@param dest string @ path to the local git repo
---@param commit string @ commit hash
local reset = async(function(dest, commit)
  local reset_cmd = fmt(config.exec_cmd .. config.subcommands.revert_to, commit)
  return jobs.run(reset_cmd, {
    capture_output = true,
    cwd = dest,
    options = { env = git.job_env }
  })
end, 2)

local handle_checkouts = void(function(plugin, dest, disp, opts)
  local plugin_name = util.get_plugin_full_name(plugin)
  local function update_disp(msg)
    if disp then
      disp:task_update(plugin_name, msg)
    end
  end

  update_disp('fetching reference...')

  local output = jobs.output_table()

  local job_opts = {
    capture_output = {
      stdout = jobs.logging_callback(output.err.stdout, output.data.stdout, nil, disp, plugin_name),
      stderr = jobs.logging_callback(output.err.stderr, output.data.stderr),
    },
    cwd = dest,
    options = { env = git.job_env }
  }

  local r = result.ok()

  if plugin.tag and has_wildcard(plugin.tag) then
    update_disp(fmt('getting tag for wildcard %s...', plugin.tag))
    local fetch_tags = config.exec_cmd .. fmt(config.subcommands.tags_expand_fmt, plugin.tag)
    r = jobs.run(fetch_tags, job_opts)
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
    local branch_or_tag = plugin.branch and plugin.branch or plugin.tag
    update_disp(fmt('checking out %s %s...', plugin.branch and 'branch' or 'tag', branch_or_tag))
    r = jobs.run(config.exec_cmd .. fmt(config.subcommands.checkout, branch_or_tag), job_opts)
    if r.err then
      r.err = {
        msg = fmt(
          'Error checking out %s %s for %s',
          plugin.branch and 'branch' or 'tag',
          branch_or_tag,
          plugin_name
        ),
        data = r.err,
        output = output,
      }
    end
  end

  if r.ok and plugin.commit then
    update_disp(fmt('checking out %s...', plugin.commit))
    r = jobs.run(config.exec_cmd .. fmt(config.subcommands.checkout, plugin.commit), job_opts)
    if r.err then
      r.err = {
        msg = fmt('Error checking out commit %s for %s', plugin.commit, plugin_name),
        data = r.err,
        output = output,
      }
    end
  end

  if r.ok then
    r.ok = { status = r.ok, output = output }
  else
    if not r.err.msg then
      r.err = {
        msg = fmt('Error updating %s: %s', plugin_name, table.concat(r.err, '\n')),
        data = r.err,
        output = output,
      }
    else
      r.err.output = output
    end
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

git.setup = function(plugin)
  local plugin_name = util.get_plugin_full_name(plugin)
  local install_to = plugin.install_path
  local install_cmd =
    vim.split(config.exec_cmd .. fmt(config.subcommands.install, plugin.commit and 999999 or config.depth), '%s+')

  local rev_cmd         = config.exec_cmd .. config.subcommands.get_rev
  local update_cmd      = config.exec_cmd .. config.subcommands.update
  local update_head_cmd = config.exec_cmd .. config.subcommands.update_head
  local fetch_cmd       = config.exec_cmd .. config.subcommands.fetch
  local branch_cmd      = config.exec_cmd .. config.subcommands.current_branch

  if plugin.commit or plugin.tag then
    update_cmd = fetch_cmd
  end

  local current_commit_cmd = vim.split(config.exec_cmd .. config.subcommands.get_header, '%s+')
  for i, arg in ipairs(current_commit_cmd) do
    current_commit_cmd[i] = string.gsub(arg, 'FMT', config.subcommands.diff_fmt)
  end

  if plugin.branch or (plugin.tag and not has_wildcard(plugin.tag)) then
    install_cmd[#install_cmd + 1] = '--branch'
    install_cmd[#install_cmd + 1] = plugin.branch and plugin.branch or plugin.tag
  end

  install_cmd[#install_cmd + 1] = plugin.url
  install_cmd[#install_cmd + 1] = install_to

  local needs_checkout = plugin.tag ~= nil or plugin.commit ~= nil or plugin.branch ~= nil

  ---@async
  ---@return Result
  plugin.installer = async(function(disp)
    local output = jobs.output_table()

    local installer_opts = {
      capture_output = {
        stdout = jobs.logging_callback(output.err.stdout, output.data.stdout),
        stderr = jobs.logging_callback(output.err.stderr, output.data.stderr, nil, disp, plugin_name),
      },
      timeout = config.clone_timeout,
      options = { env = git.job_env },
    }

    disp:task_update(plugin_name, 'cloning...')
    local r = jobs.run(install_cmd, installer_opts)

    installer_opts.cwd = install_to

    if plugin.commit then
      disp:task_update(plugin_name, fmt('checking out %s...', plugin.commit))
      r:and_then(jobs.run, config.exec_cmd .. fmt(config.subcommands.checkout, plugin.commit), installer_opts)
        :map_err(function(err)
          return {
            msg = fmt('Error checking out commit %s for %s', plugin.commit, plugin_name),
            data = { err, output },
          }
        end)
    end

    r:and_then(jobs.run, current_commit_cmd, installer_opts)
      :map_ok(function(_)
        plugin.messages = output.data.stdout
      end)
      :map_err(function(err)
        plugin.output = { err = output.data.stderr }
        if not err.msg then
          return {
            msg = fmt('Error installing %s: %s', plugin_name, table.concat(output.data.stderr, '\n')),
            data = { err, output },
          }
        end
      end)

    return r
  end, 1)

  ---@async
  ---@return Result
  plugin.remote_url = async(function()
    local r = jobs.run(fmt('%s remote get-url origin', config.exec_cmd), {
      capture_output = true,
      cwd = plugin.install_path,
      options = { env = git.job_env }
    })

    if r.ok then
      r.ok = { remote = r.ok.output.data.stdout[1] }
    end

    return r
  end)

  ---@async
  ---@return Result
  plugin.updater = async(function(disp, opts)
    local update_info = { err = {}, revs = {}, output = {}, messages = {} }
    local function exit_ok(r)
      if #update_info.err > 0 or r.exit_code ~= 0 then
        return result.err(r)
      end
      return result.ok(r)
    end

    local rev_onread = jobs.logging_callback(update_info.err, update_info.revs)
    local rev_callbacks = { stdout = rev_onread, stderr = rev_onread }
    disp:task_update(plugin_name, 'checking current commit...')
    local r = jobs.run(rev_cmd, {
      success_test = exit_ok,
      capture_output = rev_callbacks,
      cwd = install_to,
      options = { env = git.job_env }
    }):map_err(function(err)
      plugin.output = { err = vim.list_extend(update_info.err, update_info.revs), data = {} }

      return {
        msg = fmt('Error getting current commit for %s: %s', plugin_name, table.concat(update_info.revs, '\n')),
        data = err,
      }
    end)

    local current_branch
    disp:task_update(plugin_name, 'checking current branch...')
    r:and_then(jobs.run, branch_cmd, {
      success_test = exit_ok,
      capture_output = true,
      cwd = install_to,
      options = { env = git.job_env }
    }):map_ok(function(ok)
        current_branch = ok.output.data.stdout[1]
      end)
      :map_err(function(err)
        plugin.output = { err = vim.list_extend(update_info.err, update_info.revs), data = {} }

        return {
          msg = fmt('Error checking current branch for %s: %s', plugin_name, table.concat(update_info.revs, '\n')),
          data = err,
        }
      end)

    if not needs_checkout then
      local origin_branch = ''
      disp:task_update(plugin_name, 'checking origin branch...')
      local origin_refs_path = util.join_paths(install_to, '.git', 'refs', 'remotes', 'origin', 'HEAD')
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
        stdout = jobs.logging_callback(update_info.err, update_info.output),
        stderr = jobs.logging_callback(update_info.err, update_info.output, nil, disp, plugin_name),
      },
      cwd = install_to,
      options = { env = git.job_env },
    }

    if needs_checkout then
      r:and_then(jobs.run, config.exec_cmd .. config.subcommands.fetch, update_opts)
      r:and_then(handle_checkouts, plugin, install_to, disp, opts)
      local function merge_output(res)
        if res.output ~= nil then
          vim.list_extend(update_info.err, res.output.err.stderr)
          vim.list_extend(update_info.err, res.output.err.stdout)
          vim.list_extend(update_info.output, res.output.data.stdout)
          vim.list_extend(update_info.output, res.output.data.stderr)
        end
      end

      r:map_ok(merge_output)
      r:map_err(function(err)
        merge_output(err)
        plugin.output = { err = vim.list_extend(update_info.err, update_info.output), data = {} }
        local errmsg = '<unknown error>'
        if err ~= nil and err.msg ~= nil then
          errmsg = err.msg
        end
        return { msg = errmsg .. ' ' .. table.concat(update_info.output, '\n'), data = err.data }
      end)
    end

    if opts.preview_updates then
      disp:task_update(plugin_name, 'fetching updates...')
      r:and_then(jobs.run, fetch_cmd, update_opts)
    elseif opts.pull_head then
      disp:task_update(plugin_name, 'pulling updates from head...')
      r:and_then(jobs.run, update_head_cmd, update_opts)
    else
      disp:task_update(plugin_name, 'pulling updates...')
      r:and_then(jobs.run, update_cmd, update_opts)
    end
    r:map_err(function(err)
      plugin.output = { err = vim.list_extend(update_info.err, update_info.output), data = {} }

      return {
        msg = fmt('Error getting updates for %s: %s', plugin_name, table.concat(update_info.output, '\n')),
        data = err,
      }
    end)

    local post_rev_cmd
    if plugin.tag ~= nil then
      -- NOTE that any tag wildcard should already been expanded to a specific commit at this point
      post_rev_cmd = string.gsub(rev_cmd, 'HEAD', fmt('%s^{}', plugin.tag))
    elseif opts.preview_updates then
      post_rev_cmd = string.gsub(rev_cmd, 'HEAD', 'FETCH_HEAD')
    else
      post_rev_cmd = rev_cmd
    end
    disp:task_update(plugin_name, 'checking updated commit...')
    r:and_then(
      jobs.run, post_rev_cmd, {
        success_test = exit_ok,
        capture_output = rev_callbacks,
        cwd = install_to,
        options = { env = git.job_env },
      }
    ):map_err(function(err)
      plugin.output = { err = vim.list_extend(update_info.err, update_info.revs), data = {} }
      return {
        msg = fmt('Error checking updated commit for %s: %s', plugin_name, table.concat(update_info.revs, '\n')),
        data = err,
      }
    end)

    if r.ok then
      if update_info.revs[1] ~= update_info.revs[2] then
        local commit_headers_onread = jobs.logging_callback(update_info.err, update_info.messages)
        local commit_headers_callbacks = { stdout = commit_headers_onread, stderr = commit_headers_onread }

        local diff_cmd = config.subcommands.diff:format(update_info.revs[1], update_info.revs[2])
        local commit_headers_cmd = vim.split(config.exec_cmd .. diff_cmd, '%s+')
        for i, arg in ipairs(commit_headers_cmd) do
          commit_headers_cmd[i] = string.gsub(arg, 'FMT', config.subcommands.diff_fmt)
        end

        disp:task_update(plugin_name, 'getting commit messages...')
        r:and_then(
          jobs.run, commit_headers_cmd, {
            success_test = exit_ok,
            capture_output = commit_headers_callbacks,
            cwd = install_to,
            options = { env = git.job_env },
          }
        )

        plugin.output = { err = update_info.err, data = update_info.output }
        if r.ok then
          plugin.messages = update_info.messages
          plugin.revs = update_info.revs
        end

        if config.mark_breaking_changes then
          local commit_bodies = { err = {}, output = {} }
          local commit_bodies_onread = jobs.logging_callback(commit_bodies.err, commit_bodies.output)
          local commit_bodies_callbacks = { stdout = commit_bodies_onread, stderr = commit_bodies_onread }
          local commit_bodies_cmd = config.exec_cmd .. config.subcommands.get_bodies
          if opts.preview_updates then
            commit_bodies_cmd = config.exec_cmd .. config.subcommands.get_fetch_bodies
          end
          disp:task_update(plugin_name, 'checking for breaking changes...')
          r:and_then(
            jobs.run, commit_bodies_cmd, {
              success_test = exit_ok,
              capture_output = commit_bodies_callbacks,
              cwd = install_to,
              options = { env = git.job_env },
            }
          ):map_ok(function(ok)
            plugin.breaking_commits = {}
            mark_breaking_commits(plugin, commit_bodies.output)
            return ok
          end)
        end
      else
        plugin.revs = update_info.revs
        plugin.messages = update_info.messages
      end
    else
      plugin.output.err = vim.list_extend(plugin.output.err, update_info.messages)
    end

    r.info = update_info
    return r
  end, 2)

  ---@async
  ---@return Result
  plugin.diff = async(function(commit, callback)
    local diff_cmd = config.exec_cmd .. fmt(config.subcommands.git_diff_fmt, commit)
    local diff_info = { err = {}, output = {}, messages = {} }
    local diff_onread = jobs.logging_callback(diff_info.err, diff_info.messages)
    local r = jobs.run(diff_cmd, {
      capture_output = {
        stdout = diff_onread,
        stderr = diff_onread
      },
      cwd = install_to,
      options = { env = git.job_env }
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
  plugin.revert_last = async(function()
    local revert_cmd = config.exec_cmd .. config.subcommands.revert
    local r = jobs.run(revert_cmd, {
      capture_output = true,
      cwd = install_to,
      options = { env = git.job_env }
    })
    if needs_checkout and r.ok then
      r = handle_checkouts(plugin, install_to, nil, {})
      if r.ok then
        log.info('Reverted update for ' .. plugin_name)
      else
        log.error(fmt('Reverting update for %s failed!', plugin_name))
      end
    end
    return r
  end)

  ---Reset the plugin to `commit`
  ---@async
  ---@param commit string
  ---@return Result
  plugin.revert_to = async(function(commit)
    assert(type(commit) == 'string', fmt("commit: string expected but '%s' provided", type(commit)))
    require('packer.log').debug(fmt("Reverting '%s' to commit '%s'", plugin.name, commit))
    return reset(install_to, commit)
  end, 1)

  ---Returns HEAD's short hash
  ---@async
  ---@return Result
  plugin.get_rev = async(function()
    local r = jobs.run(rev_cmd, {
      cwd = plugin.install_path,
      options = { env = git.job_env },
      capture_output = true
    })

    if r.ok then
      local _, r0 = next(r.ok.output.data.stdout)
      r.ok = r0
    else
      local _, msg = fmt('%s: %s', plugin_name, next(r.err.output.data.stderr))
      r.err = msg
    end

    return r
  end, 1)

end

return git
