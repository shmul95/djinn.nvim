-- SECURITY: redacted-logging rule — never log request payloads, headers, or anything key-shaped; they may carry API keys. Logs and notifications carry status and sanitized error messages only.

local M = {}

local busy = false
local current_handle = nil

-- GEN-06 failure UX: re-set the end mark's virt_text to a failure badge.
-- stream.lua is FROZEN and M.finish() clears the status virt_text via its
-- own scheduled flush — painting before that flush settles gets wiped, so
-- this helper waits for pending_count(job) == 0 first (re-scheduling if
-- needed), then repaints the SAME end mark (id = job.end_id).
local function paint_failure_marker(job)
  local stream = require("vim_module.stream")
  if stream.pending_count(job) ~= 0 then
    vim.schedule(function() paint_failure_marker(job) end)
    return
  end
  local ok, e = pcall(vim.api.nvim_buf_get_extmark_by_id, job.buf, job.ns, job.end_id, {})
  if ok and e and #e > 0 then
    pcall(vim.api.nvim_buf_set_extmark, job.buf, job.ns, e[1], e[2], {
      id = job.end_id,
      right_gravity = true,
      strict = false,
      virt_text = { { " ✗ failed ", "ErrorMsg" } },
      virt_text_pos = "eol",
    })
  end
end

function M.start(config)
  -- GEN-01: capture the anchor FIRST, before the prompt — async input UIs may
  -- move the cursor before submit; reading it inside the callback would anchor
  -- output off the request line.
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1

  if busy then
    vim.notify("vim-module: already generating (cancel first)", vim.log.levels.WARN)
    return
  end

  -- Pre-flight: refuse a doomed request up front (key + curl).
  if not vim.env[config.api_key_env] or vim.env[config.api_key_env] == "" then
    vim.notify("vim-module: API key not found in " .. config.api_key_env .. " — set it and try again", vim.log.levels.ERROR)
    return
  end
  local curl_bin = config.curl_bin or vim.fn.exepath("curl")
  if not curl_bin or curl_bin == "" then
    vim.notify("vim-module: curl not found — install curl or set curl_bin", vim.log.levels.ERROR)
    return
  end

  vim.ui.input({ prompt = "Generate: ", default = "" }, function(input)
    -- Esc / empty input: abort with zero buffer change — no stream job, no
    -- generation.
    if input == nil or input == "" then
      return
    end

    -- Create the generation region at the CAPTURED buf/row (not re-read from
    -- the cursor here — it may have moved during the prompt).
    local stream = require("vim_module.stream")
    local job = stream.create(buf, row, { status_text = " Generating... " })
    busy = true

    local client = require("vim_module.client")
    -- client.generate can raise synchronously (temp-file write failure,
    -- vim.json.encode on invalid buffer bytes, vim.system spawn throw) —
    -- pcall so the raise can never strand busy == true with no handle.
    local ok, handle, err = pcall(client.generate, {
      config = config,
      prompt = input,
      buf = buf,
      row = row,
      on_lines = function(lines)
        stream.enqueue(job, lines)
      end,
      on_complete = function(complete_err)
        -- vim.system's on_exit runs in a FAST EVENT (CLAUDE.md: editor
        -- operations from curl callbacks MUST go through vim.schedule).
        -- stream.finish is safe here (it only schedules its flush);
        -- busy/handle are plain Lua locals. Everything editor-facing
        -- below runs inside vim.schedule.
        stream.finish(job)
        busy = false
        current_handle = nil
        if complete_err then
          vim.schedule(function()
            paint_failure_marker(job)  -- settle-aware: paints only after finish's flush has applied
            vim.notify("vim-module: " .. complete_err, vim.log.levels.ERROR)
          end)
        end
      end,
    })
    if not ok then
      -- Synchronous raise from client.generate: unwind the job and the busy
      -- flag, then surface the error (vim.schedule — same fast-event rule as
      -- on_complete).
      busy = false
      stream.finish(job)
      vim.schedule(function()
        vim.notify("vim-module: " .. tostring(handle), vim.log.levels.ERROR)
      end)
      return
    end
    if handle == nil then
      -- Pre-flight failure from client.generate. This branch runs in
      -- main-loop context (M.start called generate synchronously) — no
      -- vim.schedule needed here.
      vim.notify("vim-module: " .. (err or "failed to start"), vim.log.levels.ERROR)
      stream.finish(job)
      busy = false
      return
    end
    current_handle = handle
  end)
end

function M.cancel()
  if current_handle then
    current_handle:cancel()
    -- on_complete fires from the client (with nil), which calls stream.finish
    -- and clears busy. No additional handling needed here.
  else
    vim.notify("vim-module: no generation to cancel", vim.log.levels.INFO)
  end
end

return M
