local util = require 'packer.util'

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

return function(ft_plugins, loader)
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
    vim.api.nvim_create_autocmd('FileType', {
      pattern = ft,
      once = true,
      callback = function()
        loader(names)
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
