-- SECURITY: redacted-logging rule — never log request payloads, headers, or anything key-shaped; they may carry API keys. Logs and notifications carry status and sanitized error messages only.
-- No option or field ever holds a secret VALUE: api_key_env holds the NAME of an environment variable.

local M = {}

M.defaults = {
  model           = "claude-haiku-4-5",
  keymap          = "<super+f>",
  fallback_keymap = "<leader>af",
  api_key_env     = "ANTHROPIC_API_KEY",
  curl_bin        = nil,  -- nil => resolve at request time via vim.fn.exepath("curl") (Phase 3); Nix always supplies an absolute pkgs.curl path
  budgets         = {
    context_tokens    = 4000,
    max_output_tokens = 1024,
  },
}

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for k, v in pairs(value) do
    copy[k] = deep_copy(v)
  end
  return copy
end

-- The known top-level keys are the frozen contract in the plan <interfaces>
-- block (model, keymap, fallback_keymap, api_key_env, curl_bin, budgets).
-- Unknown top-level keys are copied through unchanged (forward compatibility
-- for Phases 2-4).
function M.merge(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("vim_module: setup opts must be a table")
  end
  local merged = deep_copy(M.defaults)
  if opts == nil then
    return merged
  end
  for key, value in pairs(opts) do
    if key ~= "budgets" then
      if value ~= nil then
        merged[key] = deep_copy(value)
      end
    end
  end
  if opts.budgets ~= nil then
    if type(opts.budgets) ~= "table" then
      error("vim_module: budgets.context_tokens and budgets.max_output_tokens must be positive integers")
    end
    for _, field in ipairs({ "context_tokens", "max_output_tokens" }) do
      local x = opts.budgets[field]
      if x ~= nil then
        if type(x) ~= "number" or x <= 0 or math.floor(x) ~= x then
          error("vim_module: budgets.context_tokens and budgets.max_output_tokens must be positive integers")
        end
        merged.budgets[field] = x
      end
    end
    for key, value in pairs(opts.budgets) do
      if key ~= "context_tokens" and key ~= "max_output_tokens" and value ~= nil then
        merged.budgets[key] = deep_copy(value)
      end
    end
  end
  return merged
end

return M
