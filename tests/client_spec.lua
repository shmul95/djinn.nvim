local this = debug.getinfo(1, "S").source:sub(2)
local root = this:match("^(.*)/tests/") or "."
package.path = root .. "/lua/?.lua;" .. package.path

local client = require("vim_module.client")

local cases = {}
local REQUIRED = {
  "body_contract",
  "key_not_in_argv",
  "header_file_content",
  "happy_stream",
  "split_text_delta",
  "ping_ignored",
  "error_frame",
  "non_2xx_json_body",
  "retry_after_surfaced",
  "cancel_keeps_partial",
  "fence_stripping",
}
local function case(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
end

-- Known key for hygiene assertions
vim.env.TEST_SPEC_KEY = "sk-spec-SECRET42"

-- Fake vim.system harness
local function with_fake(script, fn)
  script = script or {}
  local captured
  local killed = false
  local orig = vim.system
  vim.system = function(cmd, opts)
    captured = { cmd = cmd, opts = opts }
    return {
      pid = 1,
      kill = function() killed = true end,
      wait = function() return 0 end,
    }
  end
  local fake_ctx = {
    captured_argv = function() return captured and captured.cmd end,
    captured_opts = function() return captured and captured.opts end,
    killed = function() return killed end,
    fire_stdout = function(chunk)
      if captured and captured.opts and captured.opts.stdout then
        captured.opts.stdout(nil, chunk)
      end
    end,
    fire_exit = function(code, signal)
      -- Write dump headers before exit so parse_status can read them
      if captured and captured.cmd then
        local dp
        for i, v in ipairs(captured.cmd) do
          if v == "--dump-header" then dp = captured.cmd[i + 1] end
        end
        if dp and script.dump_headers then
          local df = io.open(dp, "w")
          if df then df:write(script.dump_headers) df:close() end
        end
      end
      if captured and captured.opts and captured.opts.on_exit then
        captured.opts.on_exit(code or script.exit_code or 0, signal or 0)
      end
    end,
  }
  local ok, err = pcall(fn, fake_ctx)
  vim.system = orig
  if not ok then error(err) end
end

local function make_config()
  return {
    model = "spec-model",
    api_key_env = "TEST_SPEC_KEY",
    curl_bin = "/bin/curl",
    budgets = { max_output_tokens = 256, context_tokens = 1000 },
  }
end

local function make_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 1" })
  return buf
end

local function extract_path(argv, flag)
  for i, v in ipairs(argv) do
    if v == flag then
      local p = argv[i + 1]
      if p then return (p:gsub("^@", "")) end
    end
  end
  return nil
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- 1. body_contract
case("body_contract", function()
  with_fake({ dump_headers = "HTTP/2 200\n\n", exit_code = 0 }, function(fake)
    local buf = make_buf()
    local done_err = "pending"
    client.generate({
      config = make_config(),
      prompt = "write a function",
      buf = buf,
      row = 0,
      on_lines = function() end,
      on_complete = function(e) done_err = e end,
    })
    local argv = fake.captured_argv()
    assert(argv, "body_contract: generate did not spawn")
    local body_path = extract_path(argv, "--data-binary")
    assert(body_path, "body_contract: no --data-binary in argv")
    local body_raw = read_file(body_path)
    assert(body_raw, "body_contract: cannot read body file")
    local d = vim.json.decode(body_raw)
    assert(d.model == "spec-model", "body_contract: model want spec-model got " .. tostring(d.model))
    assert(d.max_tokens == 256, "body_contract: max_tokens want 256 got " .. tostring(d.max_tokens))
    assert(d.stream == true, "body_contract: stream want true got " .. tostring(d.stream))
    assert(type(d.system) == "string" and #d.system > 0, "body_contract: system must be non-empty string")
    assert(d.messages[1].role == "user", "body_contract: messages[1].role want user")
    assert(d.messages[1].content:find("write a function", 1, true), "body_contract: content must contain prompt")
  end)
end)

-- 2. key_not_in_argv
case("key_not_in_argv", function()
  with_fake({ dump_headers = "HTTP/2 200\n\n", exit_code = 0 }, function(fake)
    local buf = make_buf()
    client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function() end,
      on_complete = function() end,
    })
    local argv = fake.captured_argv()
    assert(argv, "key_not_in_argv: generate did not spawn")
    for _, v in ipairs(argv) do
      assert(not v:find("sk-spec-SECRET42", 1, true), "key_not_in_argv: KEY IN ARGV: " .. v)
    end
    local has_header = false
    for _, v in ipairs(argv) do
      if v == "--header" then has_header = true end
    end
    assert(has_header, "key_not_in_argv: --header missing from argv")
  end)
end)

-- 3. header_file_content
case("header_file_content", function()
  with_fake({ dump_headers = "HTTP/2 200\n\n", exit_code = 0 }, function(fake)
    local buf = make_buf()
    client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function() end,
      on_complete = function() end,
    })
    local argv = fake.captured_argv()
    local hdr_path = extract_path(argv, "--header")
    assert(hdr_path, "header_file_content: no --header in argv")
    local content = read_file(hdr_path)
    assert(content, "header_file_content: cannot read header file")
    assert(content:find("content-type: application/json", 1, true), "header_file_content: missing content-type")
    assert(content:find("x-api-key: sk-spec-SECRET42", 1, true), "header_file_content: missing x-api-key")
    assert(content:find("anthropic-version: 2023-06-01", 1, true), "header_file_content: missing anthropic-version")
  end)
end)

-- 4. happy_stream
case("happy_stream", function()
  with_fake({ dump_headers = "HTTP/2 200\n\n", exit_code = 0 }, function(fake)
    local buf = make_buf()
    local lines = {}
    local done_err = "pending"
    client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function(l) for _, v in ipairs(l) do lines[#lines + 1] = v end end,
      on_complete = function(e) done_err = e end,
    })
    fake.fire_stdout('event: message_start\ndata: {"type":"message_start","message":{}}\n\n')
    fake.fire_stdout('event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n')
    fake.fire_stdout('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"line1\\nline2\\n"}}\n\n')
    fake.fire_stdout('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n')
    fake.fire_stdout('event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}\n\n')
    fake.fire_stdout('event: message_stop\ndata: {"type":"message_stop"}\n\n')
    fake.fire_exit(0, 0)
    assert(#lines == 2 and lines[1] == "line1" and lines[2] == "line2",
      "happy_stream: lines want {line1,line2} got {" .. table.concat(lines, ",") .. "}")
    assert(done_err == nil, "happy_stream: on_complete err want nil got " .. tostring(done_err))
  end)
end)

-- 5. split_text_delta
case("split_text_delta", function()
  with_fake({ dump_headers = "HTTP/2 200\n\n", exit_code = 0 }, function(fake)
    local buf = make_buf()
    local lines = {}
    local done_err = "pending"
    client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function(l) for _, v in ipairs(l) do lines[#lines + 1] = v end end,
      on_complete = function(e) done_err = e end,
    })
    fake.fire_stdout('event: message_start\ndata: {"type":"message_start","message":{}}\n\n')
    fake.fire_stdout('event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n')
    fake.fire_stdout('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hel')
    fake.fire_stdout('lo\\nwor')
    fake.fire_stdout('ld\\n"}}\n\n')
    fake.fire_stdout('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n')
    fake.fire_stdout('event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}\n\n')
    fake.fire_stdout('event: message_stop\ndata: {"type":"message_stop"}\n\n')
    fake.fire_exit(0, 0)
    assert(#lines == 2 and lines[1] == "hello" and lines[2] == "world",
      "split_text_delta: lines want {hello,world} got {" .. table.concat(lines, ",") .. "}")
    assert(done_err == nil, "split_text_delta: on_complete err want nil got " .. tostring(done_err))
  end)
end)

-- 6. ping_ignored
case("ping_ignored", function()
  with_fake({ dump_headers = "HTTP/2 200\n\n", exit_code = 0 }, function(fake)
    local buf = make_buf()
    local lines = {}
    local done_err = "pending"
    client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function(l) for _, v in ipairs(l) do lines[#lines + 1] = v end end,
      on_complete = function(e) done_err = e end,
    })
    fake.fire_stdout('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a\\n"}}\n\n')
    fake.fire_stdout('event: ping\ndata: {}\n\n')
    fake.fire_stdout('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"b\\n"}}\n\n')
    fake.fire_exit(0, 0)
    assert(#lines == 2 and lines[1] == "a" and lines[2] == "b",
      "ping_ignored: lines want {a,b} got {" .. table.concat(lines, ",") .. "}")
    assert(done_err == nil, "ping_ignored: on_complete err want nil got " .. tostring(done_err))
  end)
end)

-- 7. error_frame
case("error_frame", function()
  with_fake({ dump_headers = "HTTP/2 200\n\n", exit_code = 0 }, function(fake)
    local buf = make_buf()
    local done_err = "pending"
    client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function() end,
      on_complete = function(e) done_err = e end,
    })
    fake.fire_stdout('event: error\ndata: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}\n\n')
    fake.fire_exit(0, 0)
    assert(done_err == "Overloaded", "error_frame: on_complete want Overloaded got " .. tostring(done_err))
  end)
end)

-- 8. non_2xx_json_body
case("non_2xx_json_body", function()
  with_fake({ dump_headers = "HTTP/2 400\n\n", exit_code = 22 }, function(fake)
    local buf = make_buf()
    local done_err = "pending"
    client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function() end,
      on_complete = function(e) done_err = e end,
    })
    fake.fire_stdout('{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens is required"}}')
    fake.fire_exit(22, 0)
    assert(done_err == "max_tokens is required",
      "non_2xx_json_body: on_complete want 'max_tokens is required' got " .. tostring(done_err))
  end)
end)

-- 9. retry_after_surfaced
case("retry_after_surfaced", function()
  with_fake({ dump_headers = "HTTP/2 429\nretry-after: 30\n\n", exit_code = 22 }, function(fake)
    local buf = make_buf()
    local done_err = "pending"
    client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function() end,
      on_complete = function(e) done_err = e end,
    })
    fake.fire_stdout('{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}')
    fake.fire_exit(22, 0)
    assert(type(done_err) == "string", "retry_after_surfaced: on_complete must be a string")
    assert(done_err:find("Rate limited", 1, true), "retry_after_surfaced: must contain 'Rate limited', got " .. done_err)
    assert(done_err:find("30", 1, true), "retry_after_surfaced: must contain retry-after value '30', got " .. done_err)
  end)
end)

-- 10. cancel_keeps_partial
case("cancel_keeps_partial", function()
  with_fake({ dump_headers = "HTTP/2 200\n\n", exit_code = 0 }, function(fake)
    local buf = make_buf()
    local lines = {}
    local done_err = "pending"
    local h = client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function(l) for _, v in ipairs(l) do lines[#lines + 1] = v end end,
      on_complete = function(e) done_err = e end,
    })
    assert(h, "cancel_keeps_partial: generate must return handle")
    fake.fire_stdout('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial line\\n"}}\n\n')
    assert(#lines == 1 and lines[1] == "partial line",
      "cancel_keeps_partial: partial must arrive, got {" .. table.concat(lines, ",") .. "}")
    h:cancel()
    assert(fake.killed(), "cancel_keeps_partial: kill must have been called")
    fake.fire_exit(0, 0)
    assert(done_err == nil, "cancel_keeps_partial: cancel is not an error, got " .. tostring(done_err))
  end)
end)

-- 11. fence_stripping
case("fence_stripping", function()
  with_fake({ dump_headers = "HTTP/2 200\n\n", exit_code = 0 }, function(fake)
    local buf = make_buf()
    local lines = {}
    local done_err = "pending"
    client.generate({
      config = make_config(),
      prompt = "test",
      buf = buf,
      row = 0,
      on_lines = function(l) for _, v in ipairs(l) do lines[#lines + 1] = v end end,
      on_complete = function(e) done_err = e end,
    })
    local f = string.rep(string.char(96), 3)
    local content = "Here is a function:\n" .. f .. "python\ndef f():\n    return 42\n" .. f .. "\nHope this helps!\n"
    -- Escape for JSON embedding
    local json_text = content:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n")
    fake.fire_stdout('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"' .. json_text .. '"}}\n\n')
    fake.fire_exit(0, 0)
    assert(done_err == nil, "fence_stripping: on_complete err want nil got " .. tostring(done_err))
    assert(#lines == 2 and lines[1] == "def f():" and lines[2] == "    return 42",
      "fence_stripping: lines want {def f():,    return 42} got {" .. table.concat(lines, ",") .. "}")
  end)
end)

-- REQUIRED case enforcement
local registered = {}
for _, c in ipairs(cases) do registered[c.name] = true end
for _, name in ipairs(REQUIRED) do
  if not registered[name] then
    error("client_spec: required case missing: " .. name)
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
  error("client_spec: " .. #failures .. " case(s) failed: " .. table.concat(failures, "; "))
end
print("client_spec: all " .. #cases .. " cases passed")
