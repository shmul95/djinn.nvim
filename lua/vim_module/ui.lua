-- SECURITY: redacted-logging rule — never log request payloads, headers, or anything key-shaped; they may carry API keys. Logs and notifications carry status and sanitized error messages only.

local M = {}

-- Queue-backed runner (replaces the Phase 3 busy flag): firing while busy
-- QUEUES the request (no refusal). Records map queue ids to their stream
-- bookkeeping; running_record tracks the job currently in flight (via
-- on_transition) so cancel can flag it before delegating.
local records = {}       -- id -> { stream_job, handle, cancel_requested }
local running_record = nil

-- Settle-aware status painter (generalizes the Phase 3 paint_failure_marker):
-- stream.lua is FROZEN and M.finish() clears the status virt_text via its own
-- scheduled flush — painting before that flush settles gets wiped, so this
-- helper waits for pending_count(job) == 0 first (re-scheduling if needed),
-- then repaints the SAME end mark (id = job.end_id).
local function paint_status(job, text, hl)
  local stream = require("vim_module.stream")
  if stream.pending_count(job) ~= 0 then
    vim.schedule(function() paint_status(job, text, hl) end)
    return
  end
  local ok, e = pcall(vim.api.nvim_buf_get_extmark_by_id, job.buf, job.ns, job.end_id, {})
  if ok and e and #e > 0 then
    pcall(vim.api.nvim_buf_set_extmark, job.buf, job.ns, e[1], e[2], {
      id = job.end_id,
      right_gravity = true,
      strict = false,
      virt_text = { { text, hl } },
      virt_text_pos = "eol",
    })
  end
end

-- Fresh per module load (the spec harness reloads ui for clean state).
local q = require("vim_module.queue").new({
  start = function(record, done)
    -- record = { stream_job, buf, row, config, prompt }
    -- QUEUE-02: close the undo block before this job's first append so ONE
    -- generation == ONE undo block. undo.txt (undo-break): setting 'undolevels'
    -- closes the block even when the value is unchanged. Applied to the job's
    -- own buffer (it may not be current). Safe here: with done() deferred out
    -- of fast events (see on_complete), start always runs on the main loop.
    vim.bo[record.buf].undolevels = vim.bo[record.buf].undolevels
    paint_status(record.stream_job, " Generating... ", "Comment")
    local ok, handle, err = pcall(require("vim_module.client").generate, {
      config = record.config,
      prompt = record.prompt,
      buf = record.buf,
      row = record.row,
      on_lines = function(lines)
        require("vim_module.stream").enqueue(record.stream_job, lines)
      end,
      on_complete = function(complete_err)
        -- FAST EVENT: stream.finish is safe (self-scheduling); editor work in
        -- vim.schedule.
        require("vim_module.stream").finish(record.stream_job)
        record.done_status = complete_err and "failed"
          or (record.cancel_requested and "cancelled" or "done")
        if complete_err then
          vim.schedule(function()
            paint_status(record.stream_job, " ✗ failed ", "ErrorMsg")  -- settle-aware (pending_count gate)
            vim.notify("vim-module: " .. complete_err, vim.log.levels.ERROR)
          end)
        end
        -- Deferred: on_complete runs in a FAST EVENT (vim.system on_exit) and
        -- done() pumps the NEXT job's start (client.generate's vim.fn calls,
        -- extmarks, undolevels) — all E5560 in fast events. The queue contract
        -- allows done "eventually"; one-at-a-time ordering still holds.
        vim.schedule(function() done(record.done_status) end)
      end,
    })
    if not ok then
      -- sync raise: fail this job, release the queue (see spec sync_raise case)
      require("vim_module.stream").finish(record.stream_job)
      vim.schedule(function() vim.notify("vim-module: " .. tostring(handle), vim.log.levels.ERROR) end)
      done("failed")
      return nil
    end
    if handle == nil then
      -- pre-flight failure
      vim.notify("vim-module: " .. (err or "failed to start"), vim.log.levels.ERROR)
      require("vim_module.stream").finish(record.stream_job)
      done("failed")
      return nil
    end
    record.handle = handle
    return handle  -- queue uses it for cancel_running
  end,
  on_transition = function(job, old, new)
    if new == "running" then
      running_record = job.payload  -- module-local tracking (used by cancel)
      paint_status(job.payload.stream_job, " Generating... ", "Comment")
    end
    -- done: stream.finish already cleared the status. failed: painted in on_complete.
    -- cancelled: stream.finish already ran (running) or nothing painted (drained).
  end,
})

function M.start(config)
  -- GEN-01: capture the anchor FIRST, before the prompt — async input UIs may
  -- move the cursor before submit; reading it inside the callback would anchor
  -- output off the request line.
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1

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
    -- the cursor here — it may have moved during the prompt). The "Queued"
    -- pending indicator is painted at creation for EVERY submit — if the
    -- queue was idle the job starts immediately and on_transition repaints
    -- "Generating..." (settle-aware via paint_status).
    local stream = require("vim_module.stream")
    local job = stream.create(buf, row, { status_text = " Queued " })
    local record = { stream_job = job, buf = buf, row = row, config = config, prompt = input }
    local id = q:submit(record)
    records[id] = record
  end)
end

function M.cancel()      -- :VimModuleCancel = cancel the RUNNING job; partial kept
  if not q:is_running() then
    vim.notify("vim-module: no generation to cancel", vim.log.levels.INFO)
    return
  end
  running_record.cancel_requested = true  -- BEFORE delegating so on_complete
                                          -- maps to "cancelled"
  q:cancel_running()  -- invokes the tracked record handle.cancel(); the client
  -- on_complete(nil) -> stream.finish (partial kept) -> done("cancelled")
end

function M.cancel_all()  -- :VimModuleCancelAll = cancel running + drain queue
  if running_record then running_record.cancel_requested = true end
  local drained = q:cancel_all()
  -- NO separate cancel_running call: cancel_all already delegates the running
  -- handle (04-02 contract) AND drains the queued jobs (queued -> cancelled,
  -- opts.start never called for them).
  for _, id in ipairs(drained) do
    local rec = records[id]
    vim.schedule(function()
      require("vim_module.stream").finish(rec.stream_job)
    end)  -- zero lines enqueued -> zero buffer change; finish clears the
          -- "Queued" status virt_text (settle-aware, same pattern as elsewhere)
  end
  vim.notify("vim-module: queue drained", vim.log.levels.INFO)
end

return M
