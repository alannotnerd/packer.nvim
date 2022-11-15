
return function(key_plugins, loader)
  local keymaps = {}
  for name, plugin in pairs(key_plugins) do
    for _, keymap in ipairs(plugin.keys) do
      if type(keymap) == 'string' then
        keymap = { '', keymap }
      end
      keymaps[keymap] = keymaps[keymap] or {}
      table.insert(keymaps[keymap], name)
    end
  end

  for keymap, names in pairs(keymaps) do
    vim.keymap.set(keymap[1], keymap[2], function()
      vim.keymap.del(keymap[1], keymap[2])
      loader(names)
      vim.api.nvim_feedkeys(keymap[2], keymap[1], false)
    end, {
        desc = 'Packer lazy load: '..table.concat(names, ', '),
        silent = true
      })
  end
end
