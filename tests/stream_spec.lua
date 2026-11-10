local this = debug.getinfo(1, "S").source:sub(2)
local root = this:match("^(.*)/tests/") or "."
package.path = root .. "/lua/?.lua;" .. package.path

local stream = require("djinn.stream")

local cases = {}
local REQUIRED = {
  "append_at_end_basic",
  "user_inserts_line_above",
  "user_types_on_line_above",
  "user_deletes_line_above",
  "user_types_at_start_boundary",
  "user_edits_below_region",
  "region_deleted_midstream_continues",
  "mark_gone_aborts_gracefully",
  "multi_flush_single_undo",
  "user_edit_keeps_own_undo_block",
  "cursor_never_moves",
  "accumulate_partial_lines",
}
local function case(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
end

-- helpers
local function settle(job)
  local ok = vim.wait(1000, function() return stream.pending_count(job) == 0 end)
  assert(ok, "stream_spec: flush did not settle")
end
local function bufstr(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|")
end
local function marks(job)
  local s = vim.api.nvim_buf_get_extmark_by_id(job.buf, job.ns, job.start_id, {})
  local e = vim.api.nvim_buf_get_extmark_by_id(job.buf, job.ns, job.end_id, {})
  return { s = s, e = e }
end

local function assert_buf(buf, want, label)
  local got = bufstr(buf)
  assert(got == want, label .. ": buf want \"" .. want .. "\" got \"" .. got .. "\"")
end

local function assert_marks(job, srow, scol, erow, ecol, label)
  local m = marks(job)
  assert(m.s[1] == srow and m.s[2] == scol,
    label .. ": start mark want (" .. srow .. "," .. scol .. ") got ("
      .. tostring(m.s[1]) .. "," .. tostring(m.s[2]) .. ")")
  assert(m.e[1] == erow and m.e[2] == ecol,
    label .. ": end mark want (" .. erow .. "," .. ecol .. ") got ("
      .. tostring(m.e[1]) .. "," .. tostring(m.e[2]) .. ")")
end

-- Standard fixture: buffer a|b|c, region at row 1 (between a and b|c).
local function fixture()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
  vim.api.nvim_set_current_buf(buf)
  local job = stream.create(buf, 1)
  return buf, job
end

case("append_at_end_basic", function()
  local buf, job = fixture()
  stream.enqueue(job, { "x", "y" })
  settle(job)
  assert_marks(job, 1, 0, 3, 0, "append_at_end_basic first flush")
  assert_buf(buf, "a|x|y|b|c", "append_at_end_basic first flush")
  stream.enqueue(job, { "z" })
  settle(job)
  assert_marks(job, 1, 0, 4, 0, "append_at_end_basic second flush")
  assert_buf(buf, "a|x|y|z|b|c", "append_at_end_basic second flush")
end)

case("user_inserts_line_above", function()
  local buf, job = fixture()
  stream.enqueue(job, { "x", "y", "z" })
  settle(job)
  assert_marks(job, 1, 0, 4, 0, "user_inserts_line_above baseline")
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "NEW" })
  assert_marks(job, 2, 0, 5, 0, "user_inserts_line_above after insert")
  stream.enqueue(job, { "w" })
  settle(job)
  assert_buf(buf, "NEW|a|x|y|z|w|b|c", "user_inserts_line_above after append")
  assert_marks(job, 2, 0, 6, 0, "user_inserts_line_above after append")
end)

case("user_types_on_line_above", function()
  local buf, job = fixture()
  stream.enqueue(job, { "x", "y", "z" })
  settle(job)
  assert_marks(job, 1, 0, 4, 0, "user_types_on_line_above baseline")
  vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "T" })
  assert_marks(job, 1, 0, 4, 0, "user_types_on_line_above marks unchanged")
  assert_buf(buf, "Ta|x|y|z|b|c", "user_types_on_line_above region intact")
end)

case("user_deletes_line_above", function()
  local buf, job = fixture()
  stream.enqueue(job, { "x", "y", "z" })
  settle(job)
  assert_marks(job, 1, 0, 4, 0, "user_deletes_line_above pre-delete baseline")
  assert_buf(buf, "a|x|y|z|b|c", "user_deletes_line_above pre-delete baseline")
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
  assert_marks(job, 0, 0, 3, 0, "user_deletes_line_above after delete")
  assert_buf(buf, "x|y|z|b|c", "user_deletes_line_above after delete")
  stream.enqueue(job, { "w" })
  settle(job)
  assert_buf(buf, "x|y|z|w|b|c", "user_deletes_line_above after append")
  assert_marks(job, 0, 0, 4, 0, "user_deletes_line_above after append")
end)

case("user_types_at_start_boundary", function()
  local buf, job = fixture()
  stream.enqueue(job, { "x", "y", "z" })
  settle(job)
  local s = marks(job).s
  vim.api.nvim_buf_set_text(buf, s[1], s[2], s[1], s[2], { "TYPED" })
  -- start mark stays BEFORE the typed text (typed text entered the region)
  assert_marks(job, 1, 0, 4, 0, "user_types_at_start_boundary marks")
  local row1 = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
  assert(row1:sub(1, 5) == "TYPED",
    "user_types_at_start_boundary: typed text should sit after start mark, row 1 got \"" .. row1 .. "\"")
end)

case("user_edits_below_region", function()
  local buf, job = fixture()
  stream.enqueue(job, { "x", "y" })
  settle(job)
  assert_marks(job, 1, 0, 3, 0, "user_edits_below_region baseline")
  -- insert a new line below the region (at end row + 1)
  vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "NEWBELOW" })
  -- prepend text to a line below the region (strictly below the end-mark row)
  vim.api.nvim_buf_set_text(buf, 5, 0, 5, 0, { "P" })
  assert_marks(job, 1, 0, 3, 0, "user_edits_below_region marks unchanged")
  local region = table.concat(vim.api.nvim_buf_get_lines(buf, 1, 3, false), "|")
  assert(region == "x|y", "user_edits_below_region: region content changed, got \"" .. region .. "\"")
  assert_buf(buf, "a|x|y|b|NEWBELOW|Pc", "user_edits_below_region below content preserved")
end)

case("region_deleted_midstream_continues", function()
  local buf, job = fixture()
  stream.enqueue(job, { "x", "y" })
  settle(job)
  local m = marks(job)
  vim.api.nvim_buf_set_lines(buf, m.s[1], m.e[1], false, {})
  local after = marks(job)
  assert(after.s[1] == after.e[1] and after.s[2] == after.e[2],
    "region_deleted_midstream_continues: marks must collapse to one point, got start ("
      .. tostring(after.s[1]) .. "," .. tostring(after.s[2]) .. ") end ("
      .. tostring(after.e[1]) .. "," .. tostring(after.e[2]) .. ")")
  assert(job.aborted == false, "region_deleted_midstream_continues: job must not abort, got aborted="
    .. tostring(job.aborted))
  stream.enqueue(job, { "AFTER" })
  settle(job)
  assert_buf(buf, "a|AFTER|b|c", "region_deleted_midstream_continues lands at collapsed row")
  assert_marks(job, 1, 0, 2, 0, "region_deleted_midstream_continues marks")
end)

case("mark_gone_aborts_gracefully", function()
  -- part A: marks vanish mid-stream (region nuked)
  local buf, job = fixture()
  stream.enqueue(job, { "x" })
  settle(job)
  local before = bufstr(buf)
  vim.api.nvim_buf_clear_namespace(job.buf, job.ns, 0, -1)
  stream.enqueue(job, { "ghost" })
  settle(job)
  assert(job.aborted == true,
    "mark_gone_aborts_gracefully part A: job must latch aborted, got aborted=" .. tostring(job.aborted))
  assert_buf(buf, before, "mark_gone_aborts_gracefully part A no lines gained")
  -- part B: buffer deleted mid-stream (pcall'd anchor read must catch the raise)
  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "a", "b" })
  vim.api.nvim_set_current_buf(buf2)
  local job2 = stream.create(buf2, 1)
  vim.api.nvim_buf_delete(buf2, { force = true })
  stream.enqueue(job2, { "ghost" })
  settle(job2)
  assert(job2.aborted == true,
    "mark_gone_aborts_gracefully part B: job must latch aborted, got aborted=" .. tostring(job2.aborted))
end)

case("multi_flush_single_undo", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
  vim.api.nvim_set_current_buf(buf)
  vim.o.undolevels = vim.o.undolevels
  -- ^ closes the fixture-setup undo block. REQUIRED: consecutive API
  --   changes auto-merge into one undo block otherwise, and this test
  --   would pass even with a broken engine.
  local job = stream.create(buf, 1)
  stream.feed_text(job, "x\n"); settle(job)
  vim.o.undolevels = vim.o.undolevels   -- sync between flushes (as user keystrokes would)
  stream.feed_text(job, "y\n"); settle(job)
  vim.o.undolevels = vim.o.undolevels
  stream.feed_text(job, "partial")      -- tail only
  stream.finish(job); settle(job)
  assert_buf(buf, "a|x|y|partial|b|c", "multi_flush_single_undo after finish-with-tail")
  local e = vim.api.nvim_buf_get_extmark_by_id(buf, job.ns, job.end_id, {})
  assert(e[1] == 4 and e[2] == 0,
    "multi_flush_single_undo: end mark after finish-with-tail must be (4,0), got ("
      .. tostring(e[1]) .. "," .. tostring(e[2]) .. ")")
  vim.cmd("undo")
  assert(bufstr(buf) == "a|b|c",
    "multi_flush_single_undo: one u must remove the whole generation, got \"" .. bufstr(buf) .. "\"")
end)

case("user_edit_keeps_own_undo_block", function()
  -- WR-01: a USER mid-stream edit (GEN-03 blesses these) must survive the
  -- undo that removes the generation — undojoin must NOT swallow it.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "s", "t" })
  vim.api.nvim_set_current_buf(buf)
  vim.o.undolevels = vim.o.undolevels
  -- ^ closes the fixture-setup undo block. REQUIRED: consecutive API changes
  --   auto-merge into one undo block otherwise (see multi_flush_single_undo).
  local job = stream.create(buf, 1)
  stream.enqueue(job, { "a", "b", "c" })
  settle(job)
  assert_buf(buf, "s|a|b|c|t", "user_edit_keeps_own_undo_block after gen1")
  vim.o.undolevels = vim.o.undolevels   -- user keystroke boundary (as user keystrokes would)
  -- The "user" edits mid-stream: a direct set_lines that advances changedtick.
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "USER" })
  vim.o.undolevels = vim.o.undolevels   -- end of the user's edit = its own undo block
  stream.enqueue(job, { "d", "e" })
  settle(job)
  assert_buf(buf, "USER|s|a|b|c|d|e|t", "user_edit_keeps_own_undo_block after gen2")
  vim.cmd("undo")
  assert_buf(buf, "USER|s|a|b|c|t",
    "user_edit_keeps_own_undo_block: one u must remove only d,e (user edit survives), got \""
      .. bufstr(buf) .. "\"")
  vim.cmd("undo")
  assert_buf(buf, "s|a|b|c|t",
    "user_edit_keeps_own_undo_block: second u must remove the user edit, got \"" .. bufstr(buf) .. "\"")
  vim.cmd("undo")
  assert_buf(buf, "s|t",
    "user_edit_keeps_own_undo_block: third u must remove a,b,c, got \"" .. bufstr(buf) .. "\"")
end)

case("cursor_never_moves", function()
  local buf, job = fixture()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local want = vim.api.nvim_win_get_cursor(0)
  stream.enqueue(job, { "m1", "m2" })
  settle(job)
  stream.finish(job)
  settle(job)
  local got = vim.api.nvim_win_get_cursor(0)
  assert(got[1] == want[1] and got[2] == want[2],
    "cursor_never_moves: cursor want {" .. want[1] .. "," .. want[2] .. "} got {"
      .. got[1] .. "," .. got[2] .. "}")
end)

case("accumulate_partial_lines", function()
  local j = { pending = "" }
  local out = stream.accumulate(j, "ab")
  assert(#out == 0, "accumulate_partial_lines 1: want 0 lines, got " .. #out)
  assert(j.pending == "ab", "accumulate_partial_lines 1: pending want \"ab\", got \"" .. j.pending .. "\"")
  out = stream.accumulate(j, "cd\nef\n")
  assert(#out == 2 and out[1] == "abcd" and out[2] == "ef",
    "accumulate_partial_lines 2: want {\"abcd\",\"ef\"}, got {" .. table.concat(out, ",") .. "}")
  assert(j.pending == "", "accumulate_partial_lines 2: pending want \"\", got \"" .. j.pending .. "\"")
  out = stream.accumulate(j, "\n")
  assert(#out == 1 and out[1] == "",
    "accumulate_partial_lines 3: want {\"\"} (blank line is real output), got {"
      .. table.concat(out, ",") .. "}")
  assert(j.pending == "", "accumulate_partial_lines 3: pending want \"\", got \"" .. j.pending .. "\"")
  out = stream.accumulate(j, "g")
  assert(#out == 0, "accumulate_partial_lines 4: want 0 lines, got " .. #out)
  assert(j.pending == "g", "accumulate_partial_lines 4: pending want \"g\", got \"" .. j.pending .. "\"")
  out = stream.accumulate(j, "\n")
  assert(#out == 1 and out[1] == "g",
    "accumulate_partial_lines 5: want {\"g\"}, got {" .. table.concat(out, ",") .. "}")
  assert(j.pending == "", "accumulate_partial_lines 5: pending want \"\", got \"" .. j.pending .. "\"")
end)

local registered = {}
for _, c in ipairs(cases) do registered[c.name] = true end
for _, name in ipairs(REQUIRED) do
  if not registered[name] then
    error("stream_spec: required case missing: " .. name)
  end
end

local failures = {}
for _, c in ipairs(cases) do
  local ok, err = pcall(c.fn)
  if ok then
    print("PASS " .. c.name)
  else
    failures[#failures + 1] = c.name .. ": " .. tostring(err)
    print("FAIL " .. c.name .. ": " .. tostring(err))
  end
end
if #failures > 0 then
  error("stream_spec: " .. #failures .. " case(s) failed: " .. table.concat(failures, "; "))
end
print("stream_spec: all " .. #cases .. " cases passed")
