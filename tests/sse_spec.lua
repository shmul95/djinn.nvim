local this = debug.getinfo(1, "S").source:sub(2)
local root = this:match("^(.*)/tests/") or "."
package.path = root .. "/lua/?.lua;" .. package.path

local sse = require("vim_module.sse")

local cases = {}
local REQUIRED = {
  "single_event",
  "default_event_name",
  "split_event_across_chunks",
  "crlf_frames",
  "multi_line_data",
  "malformed_frames_skipped",
  "comment_frames_ignored",
  "ping_event",
  "error_event",
  "multiple_events_one_chunk",
  "data_without_space",
  "inert_payload_not_executed",
  "finish_discards_incomplete_frame",
}
local function case(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
end

local function run(chunks)
  local events = {}
  local p = sse.new(function(ev, data) events[#events + 1] = { ev, data } end)
  for _, c in ipairs(chunks) do sse.feed(p, c) end
  return events
end

local function expect(events, want, label)
  assert(#events == #want, label .. ": expected " .. #want .. " event(s), got " .. #events)
  for i, w in ipairs(want) do
    assert(events[i][1] == w[1], label .. ": event " .. i .. " name, got " .. tostring(events[i][1]))
    assert(events[i][2] == w[2], label .. ": event " .. i .. " data, got " .. tostring(events[i][2]))
  end
end

case("single_event", function()
  local events = run({ "event: foo\ndata: bar\n\n" })
  expect(events, { { "foo", "bar" } }, "single_event")
end)

case("default_event_name", function()
  local events = run({ "data: bar\n\n" })
  expect(events, { { "message", "bar" } }, "default_event_name")
end)

case("split_event_across_chunks", function()
  local events = run({ "event: foo\nda", "ta: bar\n\n" })
  expect(events, { { "foo", "bar" } }, "split_event_across_chunks mid-field")
  events = run({ "event: foo\ndata: bar\n", "\n" })
  expect(events, { { "foo", "bar" } }, "split_event_across_chunks mid-terminator")
end)

case("crlf_frames", function()
  local events = run({ "event: foo\r\ndata: bar\r\n\r\n" })
  expect(events, { { "foo", "bar" } }, "crlf_frames")
end)

case("multi_line_data", function()
  local events = run({ "event: foo\ndata: line1\ndata: line2\n\n" })
  expect(events, { { "foo", "line1\nline2" } }, "multi_line_data")
end)

case("malformed_frames_skipped", function()
  local events = run({ "event: orphan\n\n%%%garbage\n\nevent: ok\ndata: yes\n\n" })
  expect(events, { { "ok", "yes" } }, "malformed_frames_skipped")
end)

case("comment_frames_ignored", function()
  local events = run({ ": keepalive\n\nevent: ok\ndata: yes\n\n" })
  expect(events, { { "ok", "yes" } }, "comment_frames_ignored")
end)

case("ping_event", function()
  local events = run({ "event: ping\ndata: {\"type\":\"ping\"}\n\n" })
  expect(events, { { "ping", "{\"type\":\"ping\"}" } }, "ping_event")
end)

case("error_event", function()
  local events = run({ "event: error\ndata: {\"type\":\"error\",\"error\":{\"message\":\"Overloaded\"}}\n\n" })
  expect(events, { { "error", "{\"type\":\"error\",\"error\":{\"message\":\"Overloaded\"}}" } }, "error_event")
end)

case("multiple_events_one_chunk", function()
  local events = run({ "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n" })
  expect(events, { { "a", "1" }, { "b", "2" } }, "multiple_events_one_chunk")
end)

case("data_without_space", function()
  local events = run({ "data:x\n\n" })
  expect(events, { { "message", "x" } }, "data_without_space no-space")
  events = run({ "data: x\n\n" })
  expect(events, { { "message", "x" } }, "data_without_space one-space")
end)

case("inert_payload_not_executed", function()
  local events = run({ "data: load(\"os.exit()\")\n\n" })
  expect(events, { { "message", "load(\"os.exit()\")" } }, "inert_payload_not_executed")
end)

case("finish_discards_incomplete_frame", function()
  local events = {}
  local p = sse.new(function(ev, data) events[#events + 1] = { ev, data } end)
  sse.feed(p, "event: e\ndata: partial")
  sse.finish(p)
  assert(#events == 0, "finish_discards_incomplete_frame: expected 0 events before finish, got " .. #events)
  sse.feed(p, "data: after\n\n")
  expect(events, { { "message", "after" } }, "finish_discards_incomplete_frame reuse")
end)

local registered = {}
for _, c in ipairs(cases) do registered[c.name] = true end
for _, name in ipairs(REQUIRED) do
  if not registered[name] then
    error("sse_spec: required case missing: " .. name)
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
  error("sse_spec: " .. #failures .. " case(s) failed: " .. table.concat(failures, "; "))
end
print("sse_spec: all " .. #cases .. " cases passed")
