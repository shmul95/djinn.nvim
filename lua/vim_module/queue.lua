-- FIFO, one-running-at-a-time job state machine.
-- Pure Lua on purpose: zero editor or host globals (require-safe for the
-- nix neovimRequireCheckHook, and trivially testable headless).
--
-- Job lifecycle: queued -> running -> done|failed|cancelled.
-- Statuses are the only truth -- there is no separate busy flag.

local M = {}

local q = {}
q.__index = q

-- opts.start(payload, done) -> handle|nil
--   Called exactly once per job when the job begins running (never while
--   another job runs). MUST eventually call done(status) EXACTLY ONCE with
--   status in {"done","failed","cancelled"}. May return
--   handle = { cancel = function() end } (optional; used by cancel_running).
-- opts.on_transition(job, old_status, new_status) -- optional, fires on every
--   state change with job = { id, payload, status }.
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    jobs = {}, -- all job records in submit order (jobs[i].id == i)
    head = 1, -- index of the next queued job to consider for running
    running_id = nil,
    next_id = 0,
    _opts = opts,
  }, q)
  return self
end

-- Public projection of a job record: { id, payload, status }.
local function record(job)
  return { id = job.id, payload = job.payload, status = job.status }
end

function q:_transition(job, old_status, new_status)
  job.status = new_status
  local cb = self._opts.on_transition
  if cb then
    cb(record(job), old_status, new_status)
  end
end

function q:_pump()
  if self.running_id ~= nil then
    return
  end
  while true do
    local job = self.jobs[self.head]
    if not job then
      return
    end
    self.head = self.head + 1
    if job.status == "queued" then
      self.running_id = job.id
      self:_transition(job, "queued", "running")
      -- done() closure for this job: second call is a no-op.
      local settled = false
      local function done(status)
        if settled then
          return
        end
        settled = true
        job.settled = true
        self.running_id = nil
        self:_transition(job, "running", status)
        self:_pump()
      end
      job.done = done
      local ok, handle = pcall(self._opts.start, job.payload, done)
      if not ok then
        if not settled then
          settled = true
          job.settled = true
          self.running_id = nil
          self:_transition(job, "running", "failed")
          self:_pump()
        end
      else
        job.handle = handle
      end
      return
    end
  end
end

-- Enqueue payload; returns integer id (1,2,3,...). If nothing is running,
-- the job goes queued->running and opts.start fires synchronously.
function q:submit(payload)
  self.next_id = self.next_id + 1
  local id = self.next_id
  local job = { id = id, payload = payload, status = "queued" }
  self.jobs[id] = job
  self:_pump()
  return id
end

-- Cancel the running job (if any): invokes its handle.cancel(). The job's
-- terminal status is whatever its done() reports (ui maps its own cancel to
-- done("cancelled")). Returns true iff a running job existed.
function q:cancel_running()
  local id = self.running_id
  if id == nil then
    return false
  end
  local job = self.jobs[id]
  local handle = job.handle
  if handle and type(handle.cancel) == "function" then
    handle.cancel()
  end
  return true
end

-- cancel_running() + drain: every queued job transitions queued->cancelled
-- directly (opts.start never called for them). Returns the list of drained ids
-- (queued jobs only).
function q:cancel_all()
  self:cancel_running()
  local drained = {}
  for i = self.head, #self.jobs do
    local job = self.jobs[i]
    if job.status == "queued" then
      job.settled = true
      self:_transition(job, "queued", "cancelled")
      drained[#drained + 1] = job.id
    end
  end
  return drained
end

function q:get(id)
  local job = self.jobs[id]
  if not job then
    return nil
  end
  return record(job)
end

-- Number of queued (not running) jobs.
function q:pending_count()
  local n = 0
  for i = self.head, #self.jobs do
    if self.jobs[i].status == "queued" then
      n = n + 1
    end
  end
  return n
end

function q:is_running()
  return self.running_id ~= nil
end

return M
