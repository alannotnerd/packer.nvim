return function(cmd_plugins, loader)
  local commands = {}
  for name, plugin in pairs(cmd_plugins) do
    -- TODO(lewis6991): normalize this higher up
    local cmds = plugin.cmd
    if type(cmds) == 'string' then
      cmds = { cmds }
    end
    plugin.commands = cmds

    for _, cmd in ipairs(cmds) do
      commands[cmd] = commands[cmd] or {}
      table.insert(commands[cmd], name)
    end
  end

  for cmd, names in pairs(commands) do
    vim.api.nvim_create_user_command(cmd,
      function(args)
        vim.api.nvim_del_user_command(cmd)

        loader(names)

        local lines = args.line1 == args.line2 and '' or (args.line1 .. ',' .. args.line2)
        vim.cmd(string.format(
          '%s %s%s%s %s',
          args.mods or '',
          lines,
          cmd,
          args.bang and '!' or '',
          args.args
        ))
      end,
      { complete = 'file', bang = true, nargs = '*' }
    )
  end
end
