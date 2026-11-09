-- SECURITY: never log request payloads or headers — they may carry API keys.

local M = {}

function M.setup(opts)
  if vim.fn.has("nvim-0.10") ~= 1 then
    vim.notify("vim-module: requires Neovim >= 0.10", vim.log.levels.ERROR)
    return
  end
  local config = require("vim_module.config").merge(opts or {})
  vim.keymap.set({ "n", "i" }, config.keymap, M.trigger, { desc = "vim-module: generate function" })
  vim.keymap.set({ "n", "i" }, config.fallback_keymap, M.trigger, { desc = "vim-module: generate function (fallback)" })
  M._config = config
end

function M.trigger()
  vim.notify("vim-module: generation not implemented yet (Phase 3)", vim.log.levels.INFO)
end

return M
