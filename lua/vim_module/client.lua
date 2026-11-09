-- SECURITY: redacted-logging rule — never log request payloads, headers, or anything key-shaped; they may carry API keys. Logs and notifications carry status and sanitized error messages only.
-- API key hygiene (CFG-02): the key is read from vim.env at request time, written ONLY to a 0600 temp header file passed via --header @file, never in curl argv (ps-visible), never logged, never on disk beyond the temp file which is unlinked promptly.

local M = {}

-- PROSE_PATTERNS: lines matching any of these are dropped by the fence stripper
-- in BOTH states (prologue and code) — prose never lands in the output.
local PROSE_PATTERNS = {
  "^Here[%s']",
  "^Sure",
  "^I'll",
  "^I've",
  "^I%s+can",
  "^Let%s+me",
  "^Below%s",
  "^Of%s+course",
  "^This%s+",
  "^The%s+following",
  "^Hope%s",
  "^Certainly",
}

function M.build_body(opts)
  return vim.json.encode({
    model = opts.model,
    max_tokens = opts.max_tokens,
    stream = true,
    system = opts.system_text,
    messages = { { role = "user", content = opts.user_content } },
  })
end

function M.build_headers(api_key)
  return "content-type: application/json\n"
    .. "x-api-key: " .. api_key .. "\n"
    .. "anthropic-version: 2023-06-01\n"
end

function M.build_curl_args(curl_bin, header_path, body_path, dump_path)
  return {
    curl_bin, "-N", "--no-buffer",
    "--dump-header", dump_path,
    "--header", "@" .. header_path,
    "--data-binary", "@" .. body_path,
    "https://api.anthropic.com/v1/messages",
  }
end

function M.write_temp_file(content)
  local path = vim.fn.tempname()
  local fd = vim.uv.fs_open(path, "w", 384)  -- 384 = 0600 octal
  vim.uv.fs_write(fd, content)
  vim.uv.fs_close(fd)
  return path
end

function M.cleanup_temp_files(paths)
  if type(paths) == "string" then
    paths = { paths }
  end
  for _, p in ipairs(paths) do
    pcall(vim.uv.fs_unlink, p)
  end
end

function M.build_system_prompt(buf)
  local ft = vim.bo[buf].filetype or "text"
  local sw = vim.bo[buf].shiftwidth or 8
  local indent = vim.bo[buf].expandtab and "spaces" or "tabs"
  return string.format(
    "You write complete, self-contained code units. Output ONLY the code — no prose, no markdown fences, no explanations.\nLanguage: %s\nIndent: %s, width %d",
    ft, indent, sw)
end

function M.get_buffer_slice(buf, row, max_chars)
  local total = vim.api.nvim_buf_line_count(buf)
  local start_idx = row + 1  -- convert 0-indexed row to 1-indexed
  local end_idx = row + 1
  local budget = 0
  local lines = {}
  lines[start_idx] = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  budget = budget + #lines[start_idx] + 1
  local up = row - 1
  local down = row + 1
  while budget < max_chars do
    local added = false
    if up >= 0 then
      local line = vim.api.nvim_buf_get_lines(buf, up, up + 1, false)[1] or ""
      if budget + #line + 1 <= max_chars then
        lines[up + 1] = line
        budget = budget + #line + 1
        start_idx = up + 1
        up = up - 1
        added = true
      else
        up = -1  -- stop expanding up
      end
    end
    if down < total and budget < max_chars then
      local line = vim.api.nvim_buf_get_lines(buf, down, down + 1, false)[1] or ""
      if budget + #line + 1 <= max_chars then
        lines[down + 1] = line
        budget = budget + #line + 1
        end_idx = down + 1
        down = down + 1
        added = true
      else
        down = total  -- stop expanding down
      end
    end
    if not added then
      break
    end
  end
  return table.concat(lines, "\n", start_idx, end_idx)
end

function M.build_user_content(prompt, buf, row, config)
  local max_chars = config.budgets.context_tokens * 4  -- ~4 chars per token heuristic
  local slice = M.get_buffer_slice(buf, row, max_chars)
  return slice .. "\n\nRequest: " .. prompt
end

function M.new_fence_stripper()
  local stripper = { seen_code = false }

  function stripper:filter(lines)
    local out = {}
    for _, line in ipairs(lines) do
      -- a. Drop fence lines (three backticks) EVERYWHERE
      if line:sub(1, 3) == string.rep("\96", 3) then
        goto continue
      end
      -- b. Drop prose patterns EVERYWHERE
      for _, pat in ipairs(PROSE_PATTERNS) do
        if line:match(pat) then
          goto continue
        end
      end
      -- c. Prologue state: drop empty/whitespace lines
      if not self.seen_code then
        if line:match("^%s*$") then
          goto continue
        end
        -- d. First surviving line: transition to code state
        self.seen_code = true
        out[#out + 1] = line
      else
        -- e. Code state: pass through (empty lines preserved)
        out[#out + 1] = line
      end
      ::continue::
    end
    return out
  end

  function stripper:flush()
    return {}
  end

  return stripper
end

return M
