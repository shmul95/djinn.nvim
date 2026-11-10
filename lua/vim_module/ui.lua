-- SECURITY: redacted-logging rule — never log request payloads, headers, or anything key-shaped; they may carry API keys. Logs and notifications carry status and sanitized error messages only.

local M = {}

-- CONT-01: continuation trigger words (request-text fallback)
local CONT_REQUEST_WORDS = { "the rest", "finish", "complete", "continue" }

local function is_header_shape(line)
  local t = vim.trim(line)
  if t == "" then return false end
  if t:sub(-1) == ":" then return true end            -- python/ruby def/class:
  if t:match("^fn%s+.*{%s*$") then return true end     -- rust fn ... {
  if t:match("^.*%)%s*{%s*$") then return true end     -- js/c ... ) {
  return false
end

local function is_continuation_request(request)
  local lower = request:lower()
  for _, w in ipairs(CONT_REQUEST_WORDS) do
    if lower:find(w, 1, true) then return true end
  end
  return false
end

-- CONT-01 continuation post-filter: body-only lines under the header with
-- indent normalization (header indent + one shiftwidth, expandtab respected).
-- Defensive signature-strip: lines trimmed-identical to the header are dropped.
-- Returns a filter(lines) -> lines function; identity for generate mode.
local function make_continuation_filter(buf, header_line)
  local trimmed_header = vim.trim(header_line)
  local header_indent = header_line:match("^[ \t]*") or ""
  local ts = vim.bo[buf].tabstop > 0 and vim.bo[buf].tabstop or 8
  local sw = vim.bo[buf].shiftwidth
  if sw == 0 then sw = ts end
  -- CR-01: capture expandtab ONCE at creation (main loop). The filter body
  -- runs in the client's SSE fast event; re-reading vim.bo there raises
  -- E5560 and the continuation output never lands.
  local expandtab = vim.bo[buf].expandtab
  local level = expandtab and string.rep(" ", sw) or "\t"
  local target = header_indent .. level
  local base_width = nil  -- indent WIDTH (visual columns: tab = ts) of first non-blank body line
  local function width_of(line)
    local ind = line:match("^[ \t]*") or ""
    local w = 0
    for i = 1, #ind do
      if ind:sub(i, i) == "\t" then w = w + ts - (w % ts) else w = w + 1 end
    end
    return w
  end
  -- WR-02: a blank/empty anchor makes every whitespace-only body line
  -- trimmed-identical to the header — skip the strip entirely in that case
  -- (blank lines are real output per stream.accumulate's contract).
  local do_strip = trimmed_header ~= ""
  return function(lines)
    local out = {}
    for _, line in ipairs(lines) do
      if do_strip and vim.trim(line) == trimmed_header then
        goto continue  -- defensive signature-strip (trimmed-identical to header)
      end
      if line:match("^%s*$") then
        out[#out + 1] = line
        goto continue
      end
      local w = width_of(line)
      if base_width == nil then base_width = w end
      local rel = math.max(0, w - base_width)
      local body = line:match("^[ \t]*(.*)$") or line
      local rel_indent
      if expandtab then
        rel_indent = string.rep(" ", rel)
      else
        rel_indent = string.rep("\t", math.floor(rel / sw)) .. string.rep(" ", rel % sw)
      end
      out[#out + 1] = target .. rel_indent .. body
      ::continue::
    end
    return out
  end
end

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
      digest = record.digest,
      mode = record.mode,
      on_lines = function(lines)
        require("vim_module.stream").enqueue(record.stream_job, record.filter and record.filter(lines) or lines)
      end,
      on_complete = function(complete_err, usage)
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
        elseif not record.cancel_requested and type(usage) == "table"
          and type(usage.output_tokens) == "number" then
          -- Phase 5 telemetry (CTX-02 budget visibility). Exact text per
          -- 05-RESEARCH.md — NO "vim-module: " prefix (the format string is
          -- binding). %d + the type guard mean only a number can appear;
          -- prompt/digest/headers never enter a notify (T-05-01).
          vim.schedule(function()
            vim.notify(string.format("✓ done (%d tok)", usage.output_tokens), vim.log.levels.INFO)
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
    elseif new == "done" or new == "failed" or new == "cancelled" then
      -- WR-09: terminal transition releases the heavy payload fields — the
      -- record holds prompt + digest (up to ~230KB) and records[id] /
      -- q.jobs[id] retain it otherwise, forever.
      if type(job.payload) == "table" then
        job.payload.prompt = nil
        job.payload.digest = nil
      end
      if running_record == job.payload then
        running_record = nil
      end
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

    -- CONT-01 mode detection: header-shaped anchor OR request-word trigger.
    local anchor_line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local mode = (is_header_shape(anchor_line) or is_continuation_request(input)) and "continuation" or nil

    -- CONT-01: header NEVER rewritten — body inserted BELOW it (row + 1).
    local insert_row = mode == "continuation" and (row + 1) or row

    -- CTX-01: lazy digest — first request fetches/builds, nil on cold cache.
    local digest = require("vim_module.context").get_digest(vim.fn.getcwd())

    -- Create the generation region at the CAPTURED buf/row (not re-read from
    -- the cursor here — it may have moved during the prompt). The "Queued"
    -- pending indicator is painted at creation for EVERY submit — if the
    -- queue was idle the job starts immediately and on_transition repaints
    -- "Generating..." (settle-aware via paint_status).
    local stream = require("vim_module.stream")
    local job = stream.create(buf, insert_row, { status_text = " Queued " })
    local filter = mode == "continuation" and make_continuation_filter(buf, anchor_line) or nil
    local record = {
      stream_job = job, buf = buf, row = row, config = config, prompt = input,
      mode = mode, digest = digest, filter = filter,
    }
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
