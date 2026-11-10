-- SECURITY: redacted-logging rule — never log request payloads, headers, or anything key-shaped; they may carry API keys. Logs and notifications carry status and sanitized error messages only.
-- SSE payload data is INERT: it is passed through as strings only — never decoded, evaluated, or executed here (injection surface is Phase 3's interpretation layer).

local M = {}

function M.new(on_event)
  assert(type(on_event) == "function", "sse.new: on_event must be a function")
  return { _buf = "", _on_event = on_event }
end

local function dispatch(parser, frame)
  local data_lines = {}
  local event
  for line in frame:gmatch("([^\n]*)\n") do
    if line:sub(1, 1) ~= ":" then
      local field, value = line:match("^([^:]+):?(.*)$")
      if field then
        if field == "data" or field == "event" then
          if value:sub(1, 1) == " " then
            value = value:sub(2)
          end
          if field == "data" then
            data_lines[#data_lines + 1] = value
          else
            event = value
          end
        end
      end
    end
  end
  if #data_lines == 0 then
    return
  end
  parser._on_event(event or "message", table.concat(data_lines, "\n"))
end

function M.feed(parser, chunk)
  if type(chunk) ~= "string" then
    error("sse.feed: chunk must be a string")
  end
  -- Normalize AFTER concatenation, on the accumulated buffer: a "\r" | "\n"
  -- pair split across two feed() calls is only adjacent once joined, so a
  -- per-chunk gsub would leave a stray \r and corrupt, drop, or merge frames.
  parser._buf = ((parser._buf .. chunk):gsub("\r\n", "\n"))
  while true do
    local pos = parser._buf:find("\n\n", 1, true)
    if not pos then
      break
    end
    local frame = parser._buf:sub(1, pos)
    parser._buf = parser._buf:sub(pos + 2)
    dispatch(parser, frame)
  end
end

function M.finish(parser)
  parser._buf = ""
end

return M
