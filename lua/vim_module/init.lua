-- SECURITY: never log request payloads or headers — they may carry API keys.

local M = {}

-- Transport-boundary normalization: vim.json.decode maps JSON `null` to
-- vim.NIL (userdata), which passes `value ~= nil` checks and would silently
-- overwrite defaults in merge(). Strip it recursively so `null` means
-- "absent" and defaults survive. Lives here (not config.lua) because
-- config.lua is purity-gated against vim.*.
local function strip_nil(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    if v ~= vim.NIL then
      out[k] = strip_nil(v)
    end
  end
  return out
end

function M.setup(opts)
  if vim.fn.has("nvim-0.10") ~= 1 then
    vim.notify("vim-module: requires Neovim >= 0.10", vim.log.levels.ERROR)
    return
  end
  local config = require("vim_module.config").merge(strip_nil(opts or {}))
  vim.keymap.set({ "n", "i" }, config.keymap, M.trigger, { desc = "vim-module: generate function" })
  vim.keymap.set({ "n", "i" }, config.fallback_keymap, M.trigger, { desc = "vim-module: generate function (fallback)" })
  vim.api.nvim_create_user_command("VimModuleCancel", function()
    require("vim_module.ui").cancel()
  end, { desc = "vim-module: cancel in-flight generation" })
  vim.api.nvim_create_user_command("VimModuleCancelAll", function()
    require("vim_module.ui").cancel_all()
  end, { desc = "vim-module: cancel running generation and drain the queue" })
  M._config = config
end

function M.trigger()
  require("vim_module.ui").start(M._config)
end

return M
