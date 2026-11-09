-- SECURITY: redacted-logging rule — never log request payloads, headers, or anything key-shaped; they may carry API keys. Logs and notifications carry status and sanitized error messages only.
-- Invariant: the end-mark row is NEVER cached — it is re-read from the extmark immediately before every append (a stale row demonstrably misplaces output).

local M = {}

-- PURE (no vim.* — testable with a bare table { pending = "" }).
-- Splits text on "\n"; returns complete lines (each WITHOUT trailing newline);
-- retains the trailing partial line in job.pending. Blank lines are returned
-- as "" entries — they are real output.
function M.accumulate(job, text)
  local out = {}
  local chunk = job.pending .. text
  for line in chunk:gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  job.pending = chunk:match("([^\n]*)$") or ""
  return out
end

-- Create the generation region at 0-indexed `row`, col 0 in `buf`.
-- Region = TWO point marks: start (right_gravity = false, stays fixed) and
-- end (right_gravity = true, rides down as lines land), both strict = false
-- so anchoring works at end-of-buffer. Status rides the end mark's virt_text;
-- blank lines are never pre-reserved.
function M.create(buf, row, opts)
  opts = opts or {}
  local status_text = opts.status_text or " Generating... "
  local ns = vim.api.nvim_create_namespace("vim_module")
  local job = {
    buf = buf,
    ns = ns,
    start_id = nil,
    end_id = nil,
    pending = "",
    aborted = false,
    appended = false,
    _queue = {},
    _flush_scheduled = false,
    _finishing = false,
  }
  job.start_id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    right_gravity = false,
    strict = false,
  })
  job.end_id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    right_gravity = true,
    strict = false,
    virt_text = { { status_text, "Comment" } },
    virt_text_pos = "eol",
  })
  -- Changedtick of OUR last write (none yet). The undojoin guard compares
  -- against this: a differing tick means the USER edited in between (GEN-03
  -- blesses mid-stream user edits) and the append must start its own undo
  -- block instead of swallowing their change.
  job._tick = vim.api.nvim_buf_get_changedtick(buf)
  return job
end

-- The ONE mutation path: every buffer write funnels through this scheduled
-- flush (E5560 — stream callbacks run in fast-event context).
local function flush(job)
  job._flush_scheduled = false
  if job.aborted then
    job._queue = {}
    return
  end
  -- Coalesced batch: several enqueues before this flush ran become ONE
  -- set_lines call = one undo step joined into the generation.
  local lines = job._queue
  job._queue = {}
  -- Fresh end-mark read immediately before the append — NEVER cache the row.
  -- pcall: a deleted buffer RAISES; a dead mark returns an empty list (truthy
  -- trap — an `if not e` guard alone is insufficient).
  local ok, e = pcall(vim.api.nvim_buf_get_extmark_by_id, job.buf, job.ns, job.end_id, {})
  if not ok or not e or #e == 0 then
    -- Anchor gone (region nuked / buffer deleted): latch aborted, drop the
    -- queue — graceful, zero errors.
    job.aborted = true
    return
  end
  if #lines > 0 then
    -- undojoin ONLY here, ONLY before a real append, ONLY after the first,
    -- and ONLY when we were the buffer's last writer (changedtick unchanged
    -- since OUR previous set_lines). The first append must start its own undo
    -- block; an unconditional undojoin before it merges the generation into
    -- the preceding change; an undojoin before an empty flush would merge the
    -- USER's next edit into the generation's undo block; and an undojoin when
    -- the tick moved (a USER mid-stream edit) merges THEIR edit into the
    -- generation's undo block — one `u` then deletes their typing. A differing
    -- tick starts a new undo block (generation may span two blocks — graceful
    -- degradation, versus silently eating the user's edit).
    if job.appended and vim.api.nvim_buf_get_changedtick(job.buf) == job._tick then
      pcall(vim.cmd, "undojoin")
    end
    job.appended = true
    vim.api.nvim_buf_set_lines(job.buf, e[1], e[1], false, lines)
    job._tick = vim.api.nvim_buf_get_changedtick(job.buf)
  end
  if job._finishing then
    -- Clear the status by re-setting the end mark WITHOUT virt_text at its
    -- POST-append position — never the stale pre-append e values.
    if #lines > 0 then
      -- The right-gravity end mark rode down with the appended lines.
      vim.api.nvim_buf_set_extmark(job.buf, job.ns, e[1] + #lines, 0, {
        id = job.end_id,
        right_gravity = true,
        strict = false,
      })
    else
      -- Status-clear-only flush: the anchor read above is still fresh.
      vim.api.nvim_buf_set_extmark(job.buf, job.ns, e[1], e[2], {
        id = job.end_id,
        right_gravity = true,
        strict = false,
      })
    end
    job._finishing = false
  end
end

-- E5560 discipline: nothing touches the buffer outside this scheduled flush.
local function schedule_flush(job)
  if not job._flush_scheduled then
    job._flush_scheduled = true
    vim.schedule(function() flush(job) end)
  end
end

-- lines: array of complete lines (no embedded newlines). Coalesces into ONE
-- set_lines call per scheduled flush. No-op once job.aborted.
function M.enqueue(job, lines)
  if job.aborted or #lines == 0 then
    return
  end
  for i = 1, #lines do
    job._queue[#job._queue + 1] = lines[i]
  end
  schedule_flush(job)
end

-- Convenience: M.enqueue(job, M.accumulate(job, text)). Raw text-delta entry
-- point; complete lines cross the buffer boundary, the partial tail stays in
-- job.pending.
function M.feed_text(job, text)
  M.enqueue(job, M.accumulate(job, text))
end

-- Flush the tail as a final line, then clear the status virt_text (re-set the
-- end mark WITHOUT virt_text, same id). Settling is observable: after finish,
-- M.pending_count(job) reaches 0 only once the status clear has been applied.
function M.finish(job)
  if job.pending ~= "" then
    M.enqueue(job, { job.pending })
    job.pending = ""
  end
  job._finishing = true
  schedule_flush(job)
end

-- 0 means every scheduled flush (line batches AND the status clear) has been
-- applied.
function M.pending_count(job)
  return job._flush_scheduled and 1 or 0
end

return M
