local this = debug.getinfo(1, "S").source:sub(2)
local root = this:match("^(.*)/tests/") or "."
package.path = root .. "/lua/?.lua;" .. package.path

local queue = require("vim_module.queue")

local cases = {}
local REQUIRED = {
  "fifo_order",
  "sequential_no_overlap",
  "state_transitions",
  "cancel_running_leaves_queued",
  "cancel_all_drains_without_start",
  "cancel_all_sync_settle_never_starts_drained",
  "start_throw_fails_and_pumps",
  "double_done_ignored",
}
local function case(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
end

-- Fake runner harness: records start order (payloads), stores each job's
-- done(status) for controlled completion, and records handle.cancel calls.
-- handle.cancel() only RECORDS -- terminal status arrives via the job's own
-- done("cancelled") call, mirroring the real ui contract (cancel kills the
-- process; the stream layer reports the terminal status asynchronously).
local function make_harness(opts)
  opts = opts or {}
  local h = {
    start_calls = {}, -- payloads in the order opts.start fired
    done_fns = {}, -- [payload] = done(status) captured per job
    cancel_calls = {}, -- payloads whose handle.cancel() was invoked
  }
  h.start = function(payload, done)
    h.start_calls[#h.start_calls + 1] = payload
    h.done_fns[payload] = done
    if opts.throw_on and opts.throw_on[payload] then
      error("fake runner: start threw for " .. tostring(payload))
    end
    return {
      cancel = function()
        h.cancel_calls[#h.cancel_calls + 1] = payload
      end,
    }
  end
  return h
end

local function order_of(list)
  local parts = {}
  for i, v in ipairs(list) do
    parts[i] = tostring(v)
  end
  return table.concat(parts, ",")
end

local function id_list(list)
  local parts = {}
  for i, v in ipairs(list) do
    parts[i] = tostring(v)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Collects on_transition events keyed by job id: chains[i] = {"old->new", ...}
local function transition_recorder()
  local events = {}
  local chains = {}
  local rec = {}
  rec.on_transition = function(job, old_status, new_status)
    events[#events + 1] = {
      id = job.id,
      payload = job.payload,
      status = job.status,
      old = old_status,
      new = new_status,
    }
    chains[job.id] = chains[job.id] or {}
    local c = chains[job.id]
    c[#c + 1] = old_status .. "->" .. new_status
  end
  rec.events = events
  rec.chain = function(id)
    return table.concat(chains[id] or {}, " ")
  end
  return rec
end

case("fifo_order", function()
  local h = make_harness()
  local submitted = { 1, 2, 3 }
  local q = queue.new({ start = h.start })
  for _, payload in ipairs(submitted) do
    q:submit(payload)
  end
  assert(order_of(h.start_calls) == "1",
    "fifo_order: want start order 1 after 3 submits, got " .. order_of(h.start_calls))
  -- while A runs: A running, B queued, both B and C pending
  assert(q:get(1).status == "running" and q:get(2).status == "queued",
    "fifo_order: want job1 running / job2 queued, got "
      .. q:get(1).status .. "/" .. q:get(2).status)
  assert(q:pending_count() == 2,
    "fifo_order: want pending_count 2 (B and C queued), got " .. q:pending_count())
  h.done_fns[1]("done")
  assert(order_of(h.start_calls) == "1,2",
    "fifo_order: want start order 1,2 after done(1), got " .. order_of(h.start_calls))
  h.done_fns[2]("done")
  assert(order_of(h.start_calls) == "1,2,3",
    "fifo_order: want start order 1,2,3 after done(2), got " .. order_of(h.start_calls))
  h.done_fns[3]("done")
  -- recorded order must match the submitted order exactly (fixture truthfulness)
  assert(order_of(h.start_calls) == order_of(submitted),
    "fifo_order: start order must equal submitted order, got " .. order_of(h.start_calls))
  for _, payload in ipairs(submitted) do
    assert(q:get(payload).status == "done",
      "fifo_order: job " .. payload .. " want status done, got " .. q:get(payload).status)
  end
end)

case("sequential_no_overlap", function()
  local h = make_harness()
  local q = queue.new({ start = h.start })
  q:submit(1)
  q:submit(2)
  assert(#h.start_calls == 1,
    "sequential_no_overlap: want exactly 1 start after 2 submits, got " .. #h.start_calls)
  assert(q:get(1).status == "running",
    "sequential_no_overlap: job 1 want running, got " .. q:get(1).status)
  assert(q:get(2).status == "queued",
    "sequential_no_overlap: job 2 want queued, got " .. q:get(2).status)
  assert(q:pending_count() == 1,
    "sequential_no_overlap: want pending_count 1 (queued, not running), got " .. q:pending_count())
  h.done_fns[1]("done")
  assert(#h.start_calls == 2,
    "sequential_no_overlap: want 2 starts after done(1), got " .. #h.start_calls)
  assert(q:get(2).status == "running",
    "sequential_no_overlap: job 2 want running after done(1), got " .. q:get(2).status)
  h.done_fns[2]("done")
  assert(q:is_running() == false,
    "sequential_no_overlap: want is_running false after all done")
end)

case("state_transitions", function()
  local h = make_harness()
  local rec = transition_recorder()
  local q = queue.new({ start = h.start, on_transition = rec.on_transition })
  q:submit(1)
  q:submit(2)
  q:submit(3)
  h.done_fns[1]("done")
  h.done_fns[2]("failed")
  h.done_fns[3]("cancelled")
  -- exact chains queued->running-><terminal> for each path
  assert(rec.chain(1) == "queued->running running->done",
    "state_transitions: job 1 want chain 'queued->running running->done', got '" .. rec.chain(1) .. "'")
  assert(rec.chain(2) == "queued->running running->failed",
    "state_transitions: job 2 want chain 'queued->running running->failed', got '" .. rec.chain(2) .. "'")
  assert(rec.chain(3) == "queued->running running->cancelled",
    "state_transitions: job 3 want chain 'queued->running running->cancelled', got '" .. rec.chain(3) .. "'")
  -- job record carried on every transition: { id, payload, status }
  for _, e in ipairs(rec.events) do
    assert(type(e.id) == "number", "state_transitions: transition job.id must be number")
    assert(e.status == e.new,
      "state_transitions: transition job.status must carry the new status, got "
        .. tostring(e.status) .. " want " .. tostring(e.new))
  end
  assert(#rec.events == 6,
    "state_transitions: want exactly 6 transition events (3 jobs x 2), got " .. #rec.events)
end)

case("cancel_running_leaves_queued", function()
  local h = make_harness()
  local rec = transition_recorder()
  local q = queue.new({ start = h.start, on_transition = rec.on_transition })
  local submitted = { 1, 2, 3 }
  for _, payload in ipairs(submitted) do
    q:submit(payload)
  end
  local ret = q:cancel_running()
  assert(ret == true, "cancel_running_leaves_queued: want true when a job runs, got " .. tostring(ret))
  assert(order_of(h.cancel_calls) == "1",
    "cancel_running_leaves_queued: want cancel_calls 1, got " .. order_of(h.cancel_calls))
  -- terminal status arrives via the cancelled job's own done("cancelled") path
  h.done_fns[1]("cancelled")
  assert(q:get(1).status == "cancelled",
    "cancel_running_leaves_queued: job 1 want cancelled, got " .. q:get(1).status)
  -- queued jobs survive and still run, in order
  assert(order_of(h.start_calls) == "1,2",
    "cancel_running_leaves_queued: want starts 1,2 after cancel+done, got " .. order_of(h.start_calls))
  h.done_fns[2]("done")
  h.done_fns[3]("done")
  assert(order_of(h.start_calls) == order_of(submitted),
    "cancel_running_leaves_queued: start order must equal submitted order, got " .. order_of(h.start_calls))
  assert(q:get(2).status == "done" and q:get(3).status == "done",
    "cancel_running_leaves_queued: jobs 2 and 3 want done, got "
      .. q:get(2).status .. "/" .. q:get(3).status)
  assert(rec.chain(1) == "queued->running running->cancelled",
    "cancel_running_leaves_queued: job 1 want cancelled chain, got '" .. rec.chain(1) .. "'")
end)

case("cancel_all_drains_without_start", function()
  local h = make_harness()
  local rec = transition_recorder()
  local q = queue.new({ start = h.start, on_transition = rec.on_transition })
  q:submit(1)
  q:submit(2)
  q:submit(3)
  local drained = q:cancel_all()
  -- drained ids = queued jobs only (2, 3)
  assert(order_of(drained) == "2,3",
    "cancel_all_drains_without_start: want drained ids {2,3}, got " .. id_list(drained))
  -- only job 1 ever reached opts.start
  assert(order_of(h.start_calls) == "1",
    "cancel_all_drains_without_start: want start_calls 1, got " .. order_of(h.start_calls))
  assert(#h.cancel_calls == 1 and h.cancel_calls[1] == 1,
    "cancel_all_drains_without_start: running handle must be delegated, got cancel_calls "
      .. order_of(h.cancel_calls))
  assert(q:get(2).status == "cancelled",
    "cancel_all_drains_without_start: job 2 want cancelled, got " .. q:get(2).status)
  assert(q:get(3).status == "cancelled",
    "cancel_all_drains_without_start: job 3 want cancelled, got " .. q:get(3).status)
  assert(q:pending_count() == 0,
    "cancel_all_drains_without_start: want pending_count 0, got " .. q:pending_count())
  -- drained jobs never started: their done_fns were never captured
  assert(h.done_fns[2] == nil and h.done_fns[3] == nil,
    "cancel_all_drains_without_start: drained jobs must never reach opts.start")
  -- running job settles via its own done("cancelled") path; nothing else starts
  h.done_fns[1]("cancelled")
  assert(q:get(1).status == "cancelled",
    "cancel_all_drains_without_start: job 1 want cancelled, got " .. q:get(1).status)
  assert(order_of(h.start_calls) == "1",
    "cancel_all_drains_without_start: no job may start after cancel_all, got start_calls "
      .. order_of(h.start_calls))
  assert(rec.chain(2) == "queued->cancelled",
    "cancel_all_drains_without_start: job 2 want chain 'queued->cancelled', got '" .. rec.chain(2) .. "'")
  assert(rec.chain(3) == "queued->cancelled",
    "cancel_all_drains_without_start: job 3 want chain 'queued->cancelled', got '" .. rec.chain(3) .. "'")
end)

case("cancel_all_sync_settle_never_starts_drained", function()
  -- WR-01: handle.cancel() MAY settle done() synchronously (the contract says
  -- done must "eventually" fire — sync is allowed). cancel_all must drain the
  -- queued jobs BEFORE delegating the running handle, so the sync settle's
  -- _pump can never start a drained job.
  local starts = {}
  local q = queue.new({
    start = function(payload, done)
      starts[#starts + 1] = payload
      return {
        cancel = function()
          done("cancelled")  -- synchronous settle
        end,
      }
    end,
  })
  q:submit("A")
  q:submit("B")
  q:submit("C")
  local drained = q:cancel_all()
  assert(order_of(drained) == "2,3",
    "cancel_all_sync_settle_never_starts_drained: want drained ids {2,3}, got " .. id_list(drained))
  assert(order_of(starts) == "A",
    "cancel_all_sync_settle_never_starts_drained: drained jobs must never start (sync settle pumped one), got starts "
      .. order_of(starts))
  assert(q:get(1).status == "cancelled" and q:get(2).status == "cancelled" and q:get(3).status == "cancelled",
    "cancel_all_sync_settle_never_starts_drained: all jobs must be cancelled, got "
      .. q:get(1).status .. "/" .. q:get(2).status .. "/" .. q:get(3).status)
  assert(q:is_running() == false,
    "cancel_all_sync_settle_never_starts_drained: queue must be idle after cancel_all")
  assert(q:pending_count() == 0,
    "cancel_all_sync_settle_never_starts_drained: nothing may remain queued")
end)

case("start_throw_fails_and_pumps", function()
  local h = make_harness({ throw_on = { [1] = true } })
  local rec = transition_recorder()
  local q = queue.new({ start = h.start, on_transition = rec.on_transition })
  q:submit(1)
  q:submit(2)
  assert(q:get(1).status == "failed",
    "start_throw_fails_and_pumps: job 1 want failed after start throw, got " .. q:get(1).status)
  assert(order_of(h.start_calls) == "1,2",
    "start_throw_fails_and_pumps: want starts 1,2 (no strand), got " .. order_of(h.start_calls))
  assert(q:get(2).status == "running",
    "start_throw_fails_and_pumps: job 2 want running, got " .. q:get(2).status)
  assert(rec.chain(1) == "queued->running running->failed",
    "start_throw_fails_and_pumps: job 1 want failed chain, got '" .. rec.chain(1) .. "'")
  h.done_fns[2]("done")
  assert(q:get(2).status == "done",
    "start_throw_fails_and_pumps: job 2 want done, got " .. q:get(2).status)
end)

case("double_done_ignored", function()
  local h = make_harness()
  local rec = transition_recorder()
  local q = queue.new({ start = h.start, on_transition = rec.on_transition })
  q:submit(1)
  q:submit(2)
  q:submit(3)
  h.done_fns[1]("done")
  h.done_fns[1]("done") -- second settle must be a silent no-op
  assert(rec.chain(1) == "queued->running running->done",
    "double_done_ignored: job 1 want exactly its chain once, got '" .. rec.chain(1) .. "'")
  assert(#rec.events == 3,
    "double_done_ignored: want 3 transitions so far (job1 x2 + job2 x1), got " .. #rec.events)
  -- job 2 started exactly once; no double pump advanced to job 3
  assert(order_of(h.start_calls) == "1,2",
    "double_done_ignored: want starts 1,2 exactly, got " .. order_of(h.start_calls))
  assert(q:get(3).status == "queued",
    "double_done_ignored: job 3 want still queued, got " .. q:get(3).status)
  assert(q:pending_count() == 1,
    "double_done_ignored: want pending_count 1, got " .. q:pending_count())
  h.done_fns[2]("done")
  h.done_fns[3]("done")
  assert(order_of(h.start_calls) == "1,2,3",
    "double_done_ignored: want final start order 1,2,3, got " .. order_of(h.start_calls))
end)

-- REQUIRED case enforcement
local registered = {}
for _, c in ipairs(cases) do registered[c.name] = true end
for _, name in ipairs(REQUIRED) do
  if not registered[name] then
    error("queue_spec: required case missing: " .. name)
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
  error("queue_spec: " .. #failures .. " case(s) failed: " .. table.concat(failures, "; "))
end
print("queue_spec: all " .. #cases .. " cases passed")
