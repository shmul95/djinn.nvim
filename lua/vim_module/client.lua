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
  local fd, open_err = vim.uv.fs_open(path, "w", 384)  -- 384 = 0600 octal
  if not fd then
    error("vim-module: cannot create temp file: " .. tostring(open_err))
  end
  -- pcall: fs_write can raise on a bad fd, and its nil,err return must also
  -- count as failure. On ANY failure the just-created file is unlinked before
  -- raising — it may be the key-bearing header file (CFG-02).
  local ok, ret, write_err = pcall(vim.uv.fs_write, fd, content)
  pcall(vim.uv.fs_close, fd)
  if not ok or not ret then
    pcall(vim.uv.fs_unlink, path)
    error("vim-module: cannot write temp file: " .. tostring(write_err or ret))
  end
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

function M.parse_status(dump_path)
  local f = io.open(dump_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if not content then return nil end
  -- LAST status line wins: proxy CONNECT blocks ("HTTP/1.1 200 Connection
  -- established") and interim 1xx responses precede the real response in
  -- --dump-header; reading line 1 made every proxied error look like success.
  local status
  for line in content:gmatch("[^\n]+") do
    local s = line:match("HTTP/%d[%d%.]* (%d+)")
    if s then status = tonumber(s) end
  end
  return status
end

function M.parse_retry_after(dump_path)
  local f = io.open(dump_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if not content then return nil end
  return content:match("[Rr]etry%-[Aa]fter:%s*(%d+)")
end

function M.parse_error_body(raw_stdout)
  local ok, decoded = pcall(vim.json.decode, raw_stdout)
  if ok and type(decoded) == "table" and decoded.error and decoded.error.message then
    return decoded.error.message
  end
  return nil
end

function M.generate(opts)
  -- Pre-flight: key from env at request time
  local api_key = vim.env[opts.config.api_key_env]
  if not api_key or api_key == "" then
    return nil, "API key not found in " .. opts.config.api_key_env
  end
  -- Pre-flight: resolve curl
  local curl_bin = opts.config.curl_bin or vim.fn.exepath("curl")
  if not curl_bin or curl_bin == "" then
    return nil, "curl binary not found"
  end

  -- Build request
  local system_text = M.build_system_prompt(opts.buf)
  local user_content = M.build_user_content(opts.prompt, opts.buf, opts.row, opts.config)
  local body = M.build_body({
    model = opts.config.model,
    max_tokens = opts.config.budgets.max_output_tokens,
    system_text = system_text,
    user_content = user_content,
  })

  -- State (hoisted above the protected spawn segment so the cancel handle
  -- below can reach it)
  local state = {
    raw_stdout = "",
    stop_reason = nil,
    stop_details = nil,
    error_msg = nil,
    cancelled = false,
  }
  local RAW_CAP = 10240
  local acc = { pending = "" }
  local stripper = M.new_fence_stripper()

  -- Write temp files and spawn inside a protected segment. Every written
  -- path is tracked: a synchronous failure between the first write and the
  -- spawn unlinks them all — the header file carries the API key (CFG-02:
  -- never on disk beyond the temp file, unlinked promptly).
  local written = {}
  local ok_spawn, system_obj = pcall(function()
    local header_path = M.write_temp_file(M.build_headers(api_key))
    written[#written + 1] = header_path
    local body_path = M.write_temp_file(body)
    written[#written + 1] = body_path
    local dump_path = vim.fn.tempname()
    written[#written + 1] = dump_path

    -- Build argv
    local argv = M.build_curl_args(curl_bin, header_path, body_path, dump_path)

    -- SSE parser (require at call time)
    local sse = require("vim_module.sse")
    local parser = sse.new(function(event_name, data_str)
      if event_name == "ping" then return end
      local ok, data = pcall(vim.json.decode, data_str)
      if not ok or type(data) ~= "table" then return end
      if data.type == "error" or event_name == "error" then
        state.error_msg = (data.error and data.error.message) or "Unknown API error"
        return
      end
      if data.type == "content_block_delta" and data.delta and data.delta.type == "text_delta" then
        local text = data.delta.text
        if text and #text > 0 then
          local complete = require("vim_module.stream").accumulate(acc, text)
          local clean = stripper:filter(complete)
          if #clean > 0 then opts.on_lines(clean) end
        end
      elseif data.type == "message_delta" then
        if data.delta then
          state.stop_reason = data.delta.stop_reason
          state.stop_details = data.delta.stop_details
        end
        -- data.usage.output_tokens captured for Phase 5 telemetry (no-op for now)
      end
      -- message_start, content_block_start, content_block_stop, message_stop: lifecycle no-ops
    end)

    -- Spawn curl (call vim.system as the global — never cache it in a module-local — so tests can replace it)
    local function stdout_handler(err, data)
      if data then
        state.raw_stdout = (state.raw_stdout .. data)
        if #state.raw_stdout > RAW_CAP then
          state.raw_stdout = state.raw_stdout:sub(-RAW_CAP)
        end
        sse.feed(parser, data)
      end
    end
    -- on_exit is the THIRD positional arg (fun(out: vim.SystemCompleted)) —
    -- opts.on_exit / opts.on_stdout are not vim.system fields and are
    -- silently ignored by vim.system.
    return vim.system(argv, {
      stdout = stdout_handler,
    }, function(out)
      sse.finish(parser)
      local cleanup = function()
        M.cleanup_temp_files({ header_path, body_path, dump_path })
      end
      if state.cancelled then
        -- User cancel: flush tail, no error
        if acc.pending ~= "" then
          local tail = stripper:filter({ acc.pending })
          acc.pending = ""
          if #tail > 0 then opts.on_lines(tail) end
        end
        opts.on_complete(nil)
        cleanup()
        return
      end
      if state.error_msg then
        opts.on_complete(state.error_msg)
        cleanup()
        return
      end
      local status = M.parse_status(dump_path)
      if status and status >= 200 and status < 300 then
        -- 2xx success: flush tail through fence stripper
        if acc.pending ~= "" then
          local tail = stripper:filter({ acc.pending })
          acc.pending = ""
          if #tail > 0 then opts.on_lines(tail) end
        end
        if state.stop_reason == "max_tokens" then
          opts.on_complete("Generation truncated (max_tokens reached)")
        elseif state.stop_reason == "refusal" then
          -- RESEARCH.md: refusal — surface stop_details if present
          local expl = state.stop_details and state.stop_details.explanation
          if expl and expl ~= "" then
            opts.on_complete("Model refused the request: " .. expl)
          else
            opts.on_complete("Model refused the request")
          end
        else
          opts.on_complete(nil)
        end
      else
        -- Non-2xx: error body is plain JSON (NOT SSE)
        local err_msg = M.parse_error_body(state.raw_stdout)
          or ("HTTP " .. tostring(status or out.code))
        if status == 429 then
          local retry = M.parse_retry_after(dump_path)
          if retry then err_msg = err_msg .. " (retry after " .. retry .. "s)" end
        end
        opts.on_complete(err_msg)
      end
      cleanup()
    end)
  end)
  if not ok_spawn then
    -- Synchronous failure (temp write, spawn throw): unlink everything
    -- written so far, then re-raise for the caller (ui.lua wraps us in pcall).
    M.cleanup_temp_files(written)
    error(system_obj, 0)
  end

  return {
    cancel = function()
      state.cancelled = true
      system_obj:kill()
    end,
  }
end

return M
