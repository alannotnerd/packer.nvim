local util = {}

function util.map(func, seq)
  local result = {}
  for _, v in ipairs(seq) do
    result[#result+1] = func(v)
  end

  return result
end

function util.partition(sub, seq)
  local sub_vals = {}
  for _, val in ipairs(sub) do
    sub_vals[val] = true
  end

  local result = { {}, {} }
  for _, val in ipairs(seq) do
    if sub_vals[val] then
      table.insert(result[1], val)
    else
      table.insert(result[2], val)
    end
  end

  return unpack(result)
end

if jit then
  util.is_windows = jit.os == 'Windows'
else
  util.is_windows = package.config:sub(1, 1) == '\\'
end

util.use_shellslash = util.is_windows and vim.o.shellslash and true

util.get_separator = function()
  if util.is_windows and not util.use_shellslash then
    return '\\'
  end
  return '/'
end

function util.strip_trailing_sep(path)
  local res = string.gsub(path, util.get_separator() .. '$', '', 1)
  return res
end

function util.join_paths(...)
  return table.concat({ ... }, util.get_separator())
end

function util.get_plugin_short_name(text)
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

function util.get_plugin_full_name(plugin)
  local plugin_name = plugin.name
  if plugin.branch and plugin.branch ~= 'master' then
    -- NOTE: maybe have to change the seperator here too
    plugin_name = plugin_name .. '/' .. plugin.branch
  end

  if plugin.rev then
    plugin_name = plugin_name .. '@' .. plugin.rev
  end

  return plugin_name
end

function util.remove_ending_git_url(url)
  return vim.endswith(url, '.git') and url:sub(1, -5) or url
end

function util.deep_extend(policy, ...)
  local result = {}
  local function helper(policy0, k, v1, v2)
    if type(v1) ~= 'table' or type(v2) ~= 'table' then
      if policy0 == 'error' then
        error('Key ' .. vim.inspect(k) .. ' is already present with value ' .. vim.inspect(v1))
      elseif policy0 == 'force' then
        return v2
      else
        return v1
      end
    else
      return util.deep_extend(policy0, v1, v2)
    end
  end

  for _, t in ipairs { ... } do
    for k, v in pairs(t) do
      if result[k] ~= nil then
        result[k] = helper(policy, k, result[k], v)
      else
        result[k] = v
      end
    end
  end

  return result
end

-- Credit to @crs for the original function
function util.float(opts)
  local last_win = vim.api.nvim_get_current_win()
  local last_pos = vim.api.nvim_win_get_cursor(last_win)
  local columns = vim.o.columns
  local lines   = vim.o.lines
  local width   = math.ceil(columns * 0.8)
  local height  = math.ceil(lines * 0.8 - 4)
  local left    = math.ceil((columns - width) * 0.5)
  local top     = math.ceil((lines - height) * 0.5 - 1)

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, vim.tbl_deep_extend('force', {
    relative = 'editor',
    style    = 'minimal',
    border   = 'double',
    width    = width,
    height   = height,
    col      = left,
    row      = top,
  }, opts or {}))

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      vim.api.nvim_set_current_win(last_win)
      vim.api.nvim_win_set_cursor(last_win, last_pos)
    end
  })

  return true, win, buf
end

return util
