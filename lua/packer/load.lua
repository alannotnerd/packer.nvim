local packer_load = nil
local cmd = vim.api.nvim_command
local fmt = string.format

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

local function loader_apply_after(plugin, plugins, name)
  if plugin.after then
    for _, after_name in ipairs(plugin.after) do
      local after_plugin = plugins[after_name]
      after_plugin.load_after[name] = nil
      if next(after_plugin.load_after) == nil then
        packer_load({ after_name }, {}, plugins)
      end
    end
  end
end

packer_load = function(names, cause, plugins)
  local some_unloaded = false
  local needs_bufread = false
  for i, name in ipairs(names) do
    local plugin = plugins[name]
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
      cmd('packadd ' .. names[i])
      if plugin.after_files then
        for _, file in ipairs(plugin.after_files) do
          cmd('silent source ' .. file)
        end
      end
      loader_apply_config(plugin, names[i])
      loader_apply_after(plugin, plugins, names[i])
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
      cmd 'doautocmd BufRead'
    end
  end
end

-- local function load_wrapper(names, cause, plugins)
--   local success, err_msg = pcall(packer_load, names, cause, plugins)
--   if not success then
--     vim.cmd 'echohl ErrorMsg'
--     vim.cmd('echomsg "Error in packer_compiled: ' .. vim.fn.escape(err_msg, '"') .. '"')
--     vim.cmd 'echomsg "Please check your config for correctness"'
--     vim.cmd 'echohl None'
--   end
-- end

return packer_load
