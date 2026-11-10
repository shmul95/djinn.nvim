-- Project context digest: denylist-filtered tree + README/docs text, cached
-- outside the worktree, lazily built and refreshed on staleness.
--
-- SECURITY (RESEARCH rule 2): denylist is applied BEFORE any read — denied
-- paths are never opened, never listed in the tree, never scanned (denied
-- directories are not descended). The digest is untrusted project DATA; the
-- wiring plan (04-04) frames it as such in the prompt.
--
-- Require-safe: no top-level vim.* execution — every vim call lives inside a
-- function (nix build's neovimRequireCheckHook loads this module standalone).
--
-- Accepted simplification (recorded in 04-01 plan): the digest walk is a
-- chunked vim.uv walk driven by vim.schedule (yields every N entries), not a
-- vim.system subprocess; the trigger path stays non-blocking either way.

local M = {}

local CHUNK_DEFAULT = 200      -- entries processed per step before yielding
local TREE_CAP = 2000          -- max tree lines rendered
local DOCS_CAP = 200 * 1024    -- max total doc text rendered

-- denylist ---------------------------------------------------------------

local DENIED_DIRS = { secrets = true, private = true, [".git"] = true }

-- Case-insensitive denylist over the path RELATIVE to root. Deny BEFORE read.
-- Denied if: any path segment is "secrets" or "private" or ".git";
-- OR basename lowercased starts with ".env", or contains "key", "secret",
-- "token", or ends with ".pem"; OR the relpath matches a gitignore pattern.
function M.is_denied(relpath, ignore_pats)
  local lower = relpath:lower()
  for seg in lower:gmatch("[^/]+") do
    if DENIED_DIRS[seg] then
      return true
    end
  end
  local base = lower:match("[^/]+$") or lower
  if base:sub(1, 4) == ".env" then
    return true
  end
  if base:find("key", 1, true) or base:find("secret", 1, true) or base:find("token", 1, true) then
    return true
  end
  if base:sub(-4) == ".pem" then
    return true
  end
  if ignore_pats ~= nil then
    for _, pat in ipairs(ignore_pats) do
      -- match the path and the path-as-dir-prefix so "build/" patterns
      -- catch the directory entry itself
      if relpath:match(pat) or (relpath .. "/"):match(pat) then
        return true
      end
    end
  end
  return false
end

local MAGIC = "[%^%$%(%)%%%.%[%]%*%+%-%?]"
local function lua_escape(s)
  return (s:gsub(MAGIC, "%%%0"))
end

-- Read root .gitignore; return list of Lua patterns (simple v1 translation).
function M.parse_gitignore(root)
  local pats = {}
  local f = io.open(root .. "/.gitignore", "r")
  if f == nil then
    return pats
  end
  for line in f:lines() do
    local l = line:match("^%s*(.-)%s*$")
    if l ~= "" and not l:match("^#") then
      if l:sub(-1) == "/" then
        -- dir prefix
        pats[#pats + 1] = "^" .. lua_escape(l:sub(1, -2)) .. "/"
      elseif l:find("*", 1, true) then
        -- "*" -> "[^/]*", anchored
        pats[#pats + 1] = "^" .. lua_escape(l):gsub("%%%*", "[^/]*") .. "$"
      else
        pats[#pats + 1] = "^" .. lua_escape(l) .. "$"
      end
    end
  end
  f:close()
  return pats
end

-- walk -------------------------------------------------------------------

local function is_doc(relpath)
  local base = relpath:match("[^/]+$") or relpath
  if base:match("^README") then
    return true
  end
  if relpath:match("^docs?/") then
    local lb = base:lower()
    if lb:match("%.md$") or lb:match("%.txt$") then
      return true
    end
  end
  return false
end

local function new_walk_state(root, chunk)
  return {
    root = root,
    chunk = chunk or CHUNK_DEFAULT,
    ignore_pats = nil,
    work = { { rel = "", dir = true } },
    tree = {},
    docs = {},
    file_count = 0,
    max_mtime = 0,
  }
end

-- Process at most chunk work items; returns true when the walk is complete.
-- Denylist runs BEFORE any read: a denied entry is never enqueued, never
-- listed, never opened; denied directories are never scanned. file_count
-- counts every entry the walk encounters (cheap staleness signal — the plan's
-- case "stale_file_count_triggers_refresh" pins it to all fixture entries),
-- while tree/docs/max_mtime only ever see non-denied files.
local function step(state)
  if state.ignore_pats == nil then
    state.ignore_pats = M.parse_gitignore(state.root)
  end
  local n = 0
  while n < state.chunk and #state.work > 0 do
    local item = table.remove(state.work, 1)
    n = n + 1
    if item.dir then
      local dir_path = item.rel == "" and state.root or (state.root .. "/" .. item.rel)
      local handle = vim.uv.fs_scandir(dir_path)
      if handle ~= nil then
        while true do
          local name, typ = vim.uv.fs_scandir_next(handle)
          if name == nil then
            break
          end
          local rel = item.rel == "" and name or (item.rel .. "/" .. name)
          state.file_count = state.file_count + 1
          if not M.is_denied(rel, state.ignore_pats) then
            state.work[#state.work + 1] = { rel = rel, dir = (typ == "directory") }
          end
        end
      end
    else
      -- denylist BEFORE read (belt and braces: checked at discovery too)
      if not M.is_denied(item.rel, state.ignore_pats) then
        local path = state.root .. "/" .. item.rel
        -- CR-02: lstat guard — refuse symlinks entirely. io.open/fs_stat would
        -- follow them: a README.md -> .env (or -> ~/.ssh/id_rsa) symlink puts
        -- denied/foreign CONTENT into the digest. Symlinks contribute nothing:
        -- no tree line, no doc read. Same for entries that vanished mid-walk.
        local st_link = vim.uv.fs_lstat(path)
        if st_link ~= nil and st_link.type ~= "link" then
          local st = vim.uv.fs_stat(path)
          if st ~= nil and st.mtime ~= nil and type(st.mtime.sec) == "number" then
            if st.mtime.sec > state.max_mtime then
              state.max_mtime = st.mtime.sec
            end
          end
          state.tree[#state.tree + 1] = item.rel
          if is_doc(item.rel) then
            local f = io.open(path, "r")
            if f ~= nil then
              local text = f:read("*a")
              f:close()
              state.docs[#state.docs + 1] = { path = item.rel, text = text or "" }
            end
          end
        end
      end
    end
  end
  return #state.work == 0
end

local function finalize(state)
  table.sort(state.tree)
  return {
    file_count = state.file_count,
    max_mtime = state.max_mtime,
    tree = state.tree,
    docs = state.docs,
  }
end

-- Recursive chunked walk of root. on_done mode (async): the call itself does
-- NO I/O — even the first chunk runs from vim.schedule; on_done(manifest)
-- fires when the walk completes. No-on_done mode (spec entry): drains every
-- chunk inline and returns the manifest.
function M.walk(root, on_done, chunk)
  local state = new_walk_state(root, chunk)
  if on_done == nil then
    while not step(state) do
      -- drain every chunk inline
    end
    return finalize(state)
  end
  local function pump()
    if step(state) then
      on_done(finalize(state))
    else
      vim.schedule(pump) -- periodic chunk yield
    end
  end
  vim.schedule(pump)
  return nil
end

-- render -----------------------------------------------------------------

-- Pure. Digest string:
--   "<project_tree>\n" .. first min(#tree, 2000) relpaths joined "\n"
--     .. "\n</project_tree>\n\n"
--   .. "<project_docs>\n" .. docs text .. "\n</project_docs>"
-- Docs total text hard-capped at 200KB (whole docs until the one that
-- crosses the cap; its tail is truncated).
function M.render_digest(manifest)
  local tree = manifest.tree or {}
  local n = math.min(#tree, TREE_CAP)
  local lines = {}
  for i = 1, n do
    lines[i] = tree[i]
  end
  local acc = {}
  local used = 0
  for _, doc in ipairs(manifest.docs or {}) do
    local text = doc.text or ""
    if used + #text > DOCS_CAP then
      acc[#acc + 1] = text:sub(1, DOCS_CAP - used)
      used = DOCS_CAP
      break
    end
    acc[#acc + 1] = text
    used = used + #text
  end
  -- WR-03: neutralize the framing close delimiter inside digest content —
  -- untrusted repo text must never be able to close a <project_files> block
  -- (defense in depth; pack() re-neutralizes at the framing boundary).
  return (("<project_tree>\n"
    .. table.concat(lines, "\n")
    .. "\n</project_tree>\n\n"
    .. "<project_docs>\n"
    .. table.concat(acc)
    .. "\n</project_docs>"):gsub("</project_files>", "</project_files >"))
end

-- Budget packing (CTX-02). Priority when over budget:
--   request (NEVER truncated) > buffer slice > digest (truncate digest tail first).
-- opts: request (string), slice (string), digest (string|nil), budget_chars (number)
-- returns: user_content (string), digest_truncated (boolean), digest_dropped (boolean)
local DIGEST_OPEN = "<project_files>\n"
local DIGEST_CLOSE = "\n</project_files>\n\n"
local DIGEST_OVERHEAD = #DIGEST_OPEN + #DIGEST_CLOSE
local REQUEST_PREFIX = "\n\nRequest: "

function M.pack(opts)
  local request = opts.request or ""
  local slice = opts.slice or ""
  local digest = opts.digest
  -- WR-03: framing must be unbreakable — neutralize any close delimiter
  -- inside the digest BEFORE it is pasted between the <project_files> tags,
  -- so repo content can neither close the block early nor forge one.
  if digest ~= nil then
    digest = (digest:gsub("</project_files>", "</project_files >"))
  end
  local budget = opts.budget_chars or 0
  local digest_truncated = false
  local digest_dropped = false

  local tail = slice .. REQUEST_PREFIX .. request

  -- Digest block only when digest is non-nil and non-empty.
  if digest ~= nil and digest ~= "" then
    local avail = budget - #tail
    if #digest + DIGEST_OVERHEAD <= avail then
      -- full digest fits
    elseif avail - DIGEST_OVERHEAD > 0 then
      digest = digest:sub(1, avail - DIGEST_OVERHEAD)
      digest_truncated = true
    else
      digest = nil
      digest_dropped = true
    end
  end

  local user_content
  if digest ~= nil and digest ~= "" then
    user_content = DIGEST_OPEN .. digest .. DIGEST_CLOSE .. tail
  else
    user_content = tail
  end

  -- Slice truncation only when still over budget (digest already handled).
  if #user_content > budget then
    local req_part = REQUEST_PREFIX .. request
    local max_slice = budget - #req_part
    if max_slice < 0 then max_slice = 0 end
    slice = slice:sub(1, max_slice)
    user_content = slice .. req_part
  end

  return user_content, digest_truncated, digest_dropped
end

-- cache ------------------------------------------------------------------

-- stdpath("cache") .. "/vim-module/" .. sha256(root) .. ".json" — never
-- inside the repo worktree.
function M.cache_path(root)
  return vim.fn.stdpath("cache") .. "/vim-module/" .. vim.fn.sha256(root) .. ".json"
end

function M.load_cache(root)
  local f = io.open(M.cache_path(root), "r")
  if f == nil then
    return nil
  end
  local text = f:read("*a")
  f:close()
  if text == nil or text == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

function M.save_cache(root, manifest)
  local dir = vim.fn.stdpath("cache") .. "/vim-module"
  vim.fn.mkdir(dir, "p")
  -- WR-04: 0600 (384) — the cache carries the full project tree and docs
  -- text; it must not be world-readable (same mode as client.write_temp_file
  -- key material). fs_open's mode applies at creation; fs_chmod covers
  -- rewrites of an already-existing wider-mode file.
  local path = M.cache_path(root)
  local fd = vim.uv.fs_open(path, "w", 384)
  if not fd then
    return
  end
  vim.uv.fs_write(fd, vim.json.encode(manifest))
  vim.uv.fs_close(fd)
  vim.uv.fs_chmod(path, 384)
end

-- Pure. Staleness = file-count or max-mtime change (documented TTL is
-- secondary and not implemented).
function M.needs_refresh(cached, fresh)
  return cached.file_count ~= fresh.file_count or cached.max_mtime ~= fresh.max_mtime
end

-- Walk (inline drain of all chunks) + save; returns manifest. Spec entry
-- point for the fixture specs; the async path uses walk(root, on_done).
function M.build_sync(root)
  local manifest = M.walk(root, nil, nil)
  M.save_cache(root, manifest)
  return manifest
end

-- NON-BLOCKING (trigger-path contract, RESEARCH rule 1): returns before any
-- walk runs; the function body contains NO wait/loop. Cold cache -> nil now,
-- build deferred to vim.schedule. Warm cache -> the cached digest now, and an
-- ALWAYS-scheduled freshness walk that re-saves when needs_refresh fires.
function M.get_digest(root)
  local cached = M.load_cache(root)
  if cached == nil then
    vim.schedule(function()
      M.walk(root, function(fresh)
        M.save_cache(root, fresh)
      end)
    end)
    return nil
  end
  vim.schedule(function()
    M.walk(root, function(fresh)
      if M.needs_refresh(cached, fresh) then
        M.save_cache(root, fresh)
      end
    end)
  end)
  return M.render_digest(cached)
end

return M
