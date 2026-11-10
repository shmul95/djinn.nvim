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
    vim.notify("djinn.nvim: requires Neovim >= 0.10", vim.log.levels.ERROR)
    return
  end
  local config = require("djinn.config").merge(strip_nil(opts or {}))
  vim.keymap.set({ "n", "i" }, config.keymap, M.trigger, { desc = "djinn.nvim: generate function" })
  vim.keymap.set({ "n", "i" }, config.fallback_keymap, M.trigger, { desc = "djinn.nvim: generate function (fallback)" })
  vim.api.nvim_create_user_command("DjinnCancel", function()
    require("djinn.ui").cancel()
  end, { desc = "djinn.nvim: cancel in-flight generation" })
  vim.api.nvim_create_user_command("DjinnCancelAll", function()
    require("djinn.ui").cancel_all()
  end, { desc = "djinn.nvim: cancel running generation and drain the queue" })
  M._config = config
end

function M.trigger()
  require("djinn.ui").start(M._config)
end

return M
