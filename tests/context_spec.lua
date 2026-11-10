local this = debug.getinfo(1, "S").source:sub(2)
local root = this:match("^(.*)/tests/") or "."
-- Same bootstrap shape as tests/stream_spec.lua, plus the "?/init.lua" pattern
-- so require("vim_module") resolves lua/vim_module/init.lua (case 1 needs it).
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- NOTE: no require("vim_module.context") at file scope — case 1 proves that
-- requiring + setup()ing vim_module loads no context machinery. Cases 2-9
-- pull the module through ctx() after that case has run.

local cases = {}
local REQUIRED = {
  "startup_loads_no_context",
  "denylist_fixture_readme_only",
  "cache_outside_worktree",
  "stale_file_count_triggers_refresh",
  "stale_mtime_triggers_refresh",
  "cold_get_digest_nonblocking",
  "render_caps",
  "gitignore_pattern_parse",
  "walk_chunked_yields",
}
local function case(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
end

-- helpers ---------------------------------------------------------------

local function ctx()
  return require("vim_module.context")
end

local CACHE_DIR = vim.fn.stdpath("cache") .. "/vim-module"
local cache_dir_existed = vim.fn.isdirectory(CACHE_DIR) == 1
local cleanup_roots = {}
local fixture_roots = {}

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function assert_file_contains(path, marker, label)
  local text = read_file(path)
  assert(text ~= nil, label .. ": cannot read " .. path)
  assert(text:find(marker, 1, true),
    label .. ": " .. path .. " must contain " .. marker .. " (fixture precondition), got: " .. text)
end

-- Fixture layout (6 files):
--   README.md -> "# Fixture project\nreadme-marker-SENTINEL\n"
--   .env               -> "leak-env-SENTINEL=1\n"
--   secrets/creds.txt  -> "leak-secrets-SENTINEL\n"
--   .gitignore         -> "ignored.txt\n"
--   ignored.txt        -> "leak-gitignored-SENTINEL\n"
--   api_key.txt        -> "leak-key-SENTINEL\n"
local FIXTURE_FILES = {
  ["README.md"] = "# Fixture project\nreadme-marker-SENTINEL\n",
  [".env"] = "leak-env-SENTINEL=1\n",
  ["secrets/creds.txt"] = "leak-secrets-SENTINEL\n",
  [".gitignore"] = "ignored.txt\n",
  ["ignored.txt"] = "leak-gitignored-SENTINEL\n",
  ["api_key.txt"] = "leak-key-SENTINEL\n",
}

local function make_fixture()
  local base = vim.fn.tempname()
  local proj = base .. "/proj"
  vim.fn.mkdir(proj .. "/secrets", "p")
  for rel, text in pairs(FIXTURE_FILES) do
    write_file(proj .. "/" .. rel, text)
  end
  cleanup_roots[#cleanup_roots + 1] = base
  fixture_roots[#fixture_roots + 1] = proj
  return proj
end

-- Spec-side recursive file listing (used to prove the worktree gains zero
-- files from a digest build). Lists every regular file, incl. denied ones.
local function list_files(dir, prefix, out)
  out = out or {}
  prefix = prefix or ""
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return out end
  while true do
    local name, typ = vim.uv.fs_scandir_next(handle)
    if not name then break end
    local rel = prefix == "" and name or (prefix .. "/" .. name)
    if typ == "directory" then
      list_files(dir .. "/" .. name, rel, out)
    else
      out[#out + 1] = rel
    end
  end
  return out
end

local function sorted_copy(t)
  local c = {}
  for i, v in ipairs(t) do c[i] = v end
  table.sort(c)
  return c
end

local function assert_same_set(got, want, label)
  got = sorted_copy(got)
  want = sorted_copy(want)
  local g = table.concat(got, ", ")
  local w = table.concat(want, ", ")
  assert(#got == #want and g == w,
    label .. ": want {" .. w .. "} got {" .. g .. "}")
end

-- cases -----------------------------------------------------------------
-- Case 1 MUST run first: it asserts that nothing has loaded vim_module.context.

case("startup_loads_no_context", function()
  require("vim_module").setup({})
  assert(package.loaded["vim_module.context"] == nil,
    "startup_loads_no_context: require+setup of vim_module must not load vim_module.context")
  assert(package.loaded["vim_module.queue"] == nil,
    "startup_loads_no_context: require+setup of vim_module must not load vim_module.queue")
end)

case("denylist_fixture_readme_only", function()
  local context = ctx()
  -- Denylist unit contract (behavior spec)
  assert(context.is_denied("secrets/creds.txt", {}) == true, "secrets/ dir must be denied")
  assert(context.is_denied(".env", {}) == true, ".env must be denied")
  assert(context.is_denied("api_key.txt", {}) == true, "*key* must be denied")
  assert(context.is_denied(".env.local", {}) == true, ".env* must be denied")
  assert(context.is_denied("id.pem", {}) == true, "*.pem must be denied")
  assert(context.is_denied("README.md", {}) == false, "README.md must not be denied")

  local proj = make_fixture()
  -- Fixture precondition: every sentinel actually present before digest asserts
  assert_file_contains(proj .. "/README.md", "readme-marker-SENTINEL", "denylist_fixture_readme_only")
  assert_file_contains(proj .. "/.env", "leak-env-SENTINEL", "denylist_fixture_readme_only")
  assert_file_contains(proj .. "/secrets/creds.txt", "leak-secrets-SENTINEL", "denylist_fixture_readme_only")
  assert_file_contains(proj .. "/ignored.txt", "leak-gitignored-SENTINEL", "denylist_fixture_readme_only")
  assert_file_contains(proj .. "/api_key.txt", "leak-key-SENTINEL", "denylist_fixture_readme_only")

  local digest = context.render_digest(context.build_sync(proj))
  assert(digest:find("readme-marker-SENTINEL", 1, true),
    "denylist_fixture_readme_only: digest must contain README content")
  assert(digest:find("README.md", 1, true),
    "denylist_fixture_readme_only: digest tree must list README.md")
  for _, leak in ipairs({ "leak-env-SENTINEL", "leak-secrets-SENTINEL", "leak-gitignored-SENTINEL", "leak-key-SENTINEL" }) do
    assert(not digest:find(leak, 1, true),
      "denylist_fixture_readme_only: digest leaks " .. leak)
  end
  for _, p in ipairs({ ".env", "secrets/", "ignored.txt", "api_key.txt" }) do
    assert(not digest:find(p, 1, true),
      "denylist_fixture_readme_only: digest leaks path " .. p)
  end
end)

case("cache_outside_worktree", function()
  local context = ctx()
  local proj = make_fixture()
  local cp = context.cache_path(proj)
  assert(cp:find(vim.fn.stdpath("cache"), 1, true) == 1,
    "cache_outside_worktree: cache_path must start with stdpath('cache'): " .. cp)
  assert(not cp:find(proj, 1, true),
    "cache_outside_worktree: cache_path must not contain the project root: " .. cp)
  context.build_sync(proj)
  assert_same_set(list_files(proj), {
    ".env", ".gitignore", "README.md", "api_key.txt", "ignored.txt", "secrets/creds.txt",
  }, "cache_outside_worktree: worktree must hold exactly the 6 fixture files")
end)

case("stale_file_count_triggers_refresh", function()
  local context = ctx()
  -- needs_refresh is pure (behavior spec)
  assert(context.needs_refresh({ file_count = 2, max_mtime = 10 }, { file_count = 3, max_mtime = 10 }) == true,
    "needs_refresh must fire on file_count change")
  assert(context.needs_refresh({ file_count = 2, max_mtime = 10 }, { file_count = 2, max_mtime = 10 }) == false,
    "needs_refresh must not fire when nothing changed")

  local proj = make_fixture()
  context.build_sync(proj)
  local cached = context.load_cache(proj)
  assert(cached and cached.file_count == 6,
    "stale_file_count_triggers_refresh: fixture baseline file_count want 6 got " ..
    tostring(cached and cached.file_count))

  write_file(proj .. "/newfile.txt", "new-marker-SENTINEL\n")
  assert_file_contains(proj .. "/newfile.txt", "new-marker-SENTINEL", "stale_file_count_triggers_refresh")

  local r = context.get_digest(proj)
  assert(r ~= nil, "stale_file_count_triggers_refresh: warm get_digest must return text immediately")
  assert(not r:find("newfile.txt", 1, true),
    "stale_file_count_triggers_refresh: get_digest returned before refresh must still be stale")

  local ok = vim.wait(2000, function()
    local c = context.load_cache(proj)
    return c ~= nil and c.file_count == 7
  end)
  local now = context.load_cache(proj)
  assert(ok, "stale_file_count_triggers_refresh: cache never refreshed to file_count 7, got " ..
    tostring(now and now.file_count))
  local r2 = context.get_digest(proj)
  assert(r2 and r2:find("newfile.txt", 1, true),
    "stale_file_count_triggers_refresh: refreshed digest must list newfile.txt")
end)

case("stale_mtime_triggers_refresh", function()
  local context = ctx()
  local proj = make_fixture()
  context.build_sync(proj)
  local prev = context.load_cache(proj).max_mtime
  assert(type(prev) == "number", "stale_mtime_triggers_refresh: cached max_mtime must be a number")

  -- Rewrite README and force a strictly newer mtime (fs mtimes have second
  -- precision; same-second rewrites would make this case flaky).
  write_file(proj .. "/README.md", "# Fixture project v2\nreadme-v2-SENTINEL\n")
  local newer = prev + 1
  assert(vim.uv.fs_utime(proj .. "/README.md", newer, newer),
    "stale_mtime_triggers_refresh: fs_utime failed")
  assert_file_contains(proj .. "/README.md", "readme-v2-SENTINEL", "stale_mtime_triggers_refresh")

  local r = context.get_digest(proj)
  assert(r ~= nil and not r:find("readme-v2-SENTINEL", 1, true),
    "stale_mtime_triggers_refresh: pre-refresh digest must still be stale")

  local ok = vim.wait(2000, function()
    local c = context.load_cache(proj)
    return c ~= nil and type(c.max_mtime) == "number" and c.max_mtime > prev
  end)
  local now = context.load_cache(proj)
  assert(ok, "stale_mtime_triggers_refresh: cache never refreshed on mtime change, max_mtime got " ..
    tostring(now and now.max_mtime) .. " want > " .. tostring(prev))
  local r2 = context.get_digest(proj)
  assert(r2 and r2:find("readme-v2-SENTINEL", 1, true),
    "stale_mtime_triggers_refresh: refreshed digest must contain readme-v2-SENTINEL")
end)

case("cold_get_digest_nonblocking", function()
  local context = ctx()
  local proj = make_fixture()
  local r = context.get_digest(proj)
  assert(r == nil, "cold_get_digest_nonblocking: cold get_digest must return nil synchronously")
  assert(context.load_cache(proj) == nil,
    "cold_get_digest_nonblocking: cache must not exist synchronously (build is deferred)")
  local ok = vim.wait(2000, function() return context.load_cache(proj) ~= nil end)
  assert(ok, "cold_get_digest_nonblocking: cache never built")
  local r2 = context.get_digest(proj)
  assert(type(r2) == "string" and r2:find("README.md", 1, true),
    "cold_get_digest_nonblocking: warm get_digest must return digest text")
end)

case("render_caps", function()
  local context = ctx()
  local tree = {}
  for i = 1, 2005 do tree[i] = string.format("src/file%04d.lua", i) end
  local out = context.render_digest({ tree = tree, docs = {} })
  local section = out:match("<project_tree>\n(.-)\n</project_tree>")
  assert(section, "render_caps: tree section missing")
  local n = 0
  for _ in section:gmatch("[^\n]+") do n = n + 1 end
  assert(n <= 2000, "render_caps: tree lines must be capped at 2000, got " .. n)

  local big = string.rep("x", 100 * 1024)
  local out2 = context.render_digest({
    tree = {},
    docs = {
      { path = "a", text = big },
      { path = "b", text = big },
      { path = "c", text = big },
    },
  })
  local dsection = out2:match("<project_docs>\n(.*)\n</project_docs>")
  assert(dsection, "render_caps: docs section missing")
  assert(#dsection <= 200 * 1024,
    "render_caps: doc text must be capped at 200KB, got " .. #dsection)
end)

case("gitignore_pattern_parse", function()
  local context = ctx()
  assert(context.is_denied("ignored.txt", { "^ignored%.txt$" }) == true,
    "gitignore hit must deny")
  assert(context.is_denied("src/a.lua", { "^ignored%.txt$" }) == false,
    "non-matching path must not be denied by gitignore")

  local proj = make_fixture()
  local pats = context.parse_gitignore(proj)
  assert(type(pats) == "table" and #pats > 0, "parse_gitignore must return patterns")
  local matched = false
  for _, p in ipairs(pats) do
    if ("ignored.txt"):match(p) then matched = true end
  end
  assert(matched, "parse_gitignore must produce a pattern matching ignored.txt")
  assert(context.is_denied("ignored.txt", pats) == true,
    "is_denied must deny the gitignored fixture file")
end)

case("walk_chunked_yields", function()
  local context = ctx()
  local proj = make_fixture()
  -- Controlled fake scheduler: queue scheduled fns instead of running them on
  -- the real event loop. Counting raw vim.schedule calls across vim.wait is
  -- self-defeating — deferred refresh walks left over from earlier cases fire
  -- during the wait and inflate the count (caught by the Task 1/2 mutation
  -- audit). With a private queue, only THIS walk's schedule hops are counted.
  local queue = {}
  local orig_schedule = vim.schedule
  vim.schedule = function(fn)
    queue[#queue + 1] = fn
    return true
  end
  local got, walk_err
  local ok, err = pcall(function()
    context.walk(proj, function(m) got = m end, 2)
    assert(got == nil, "walk_chunked_yields: async walk must do no inline work (on_done fired inline)")
    assert(#queue == 1,
      "walk_chunked_yields: walk must queue exactly one entry point, got " .. #queue)
    local hops = 0
    while #queue > 0 do
      local fn = table.remove(queue, 1)
      hops = hops + 1
      fn()
    end
    assert(got ~= nil, "walk_chunked_yields: on_done never fired while draining scheduled steps")
    assert(hops >= 2,
      "walk_chunked_yields: walk must yield periodically via vim.schedule (>=2 hops), got " .. hops)
  end)
  vim.schedule = orig_schedule
  walk_err = err
  assert(ok, "walk_chunked_yields: " .. tostring(walk_err))
  assert(got ~= nil and got.tree, "walk_chunked_yields: on_done must deliver a manifest")
  local listed = false
  for _, p in ipairs(got.tree) do
    if p == "README.md" then listed = true end
  end
  assert(listed, "walk_chunked_yields: manifest tree must list README.md")
end)

-- teardown + runner -----------------------------------------------------

local function teardown()
  local context = pcall(require, "vim_module.context") and require("vim_module.context") or nil
  for _, proj in ipairs(fixture_roots) do
    if context then
      pcall(vim.fn.delete, context.cache_path(proj))
    end
  end
  for _, base in ipairs(cleanup_roots) do
    pcall(vim.fn.delete, base, "rf")
  end
  -- The spec created stdpath('cache')/vim-module/ only if it did not exist
  -- before the run; remove it together with its fixture cache files.
  if not cache_dir_existed then
    if context then
      for _, proj in ipairs(fixture_roots) do
        pcall(vim.fn.delete, context.cache_path(proj))
      end
    end
    pcall(vim.fn.delete, CACHE_DIR, "d")
  end
end

local registered = {}
for _, c in ipairs(cases) do registered[c.name] = true end
for _, name in ipairs(REQUIRED) do
  if not registered[name] then
    error("context_spec: required case missing: " .. name)
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
teardown()
if #failures > 0 then
  error("context_spec: " .. #failures .. " case(s) failed: " .. table.concat(failures, "; "))
end
print("context_spec: all " .. #cases .. " cases passed")
