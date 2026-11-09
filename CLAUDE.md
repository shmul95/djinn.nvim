<!-- GSD:project-start source:PROJECT.md -->
## Project

**vim-module**

An AI function-generation plugin for Neovim: press `<super+f>`, type a request ("write me a fibonacci function"), and generated code streams into the buffer starting at the cursor line. Fire-and-forget granularity — function by function, no chat — packaged as its own Nix flake and imported into cabanashmul, following the same dendritic pattern as shmulvim.

**Core Value:** Ask for a function at the point of need and watch it stream into your code, grounded in your project's context.

### Constraints

- **API**: Anthropic Messages API, direct HTTPS from Lua (curl via `vim.system`), SSE streaming. Default model `claude-haiku-4-5` (cheap, far above Copilot quality for prompted generation). API key from `ANTHROPIC_API_KEY` env var — never in the repo.
- **Neovim**: plain Lua plugin, no heavy plugin-manager dependency; must work inside the nvf-managed config; anchors use extmarks so they survive edits above.
- **Nix**: single flake exporting `packages.default` and `homeManagerModules.default`; options for model/keymap/budgets; minimal and settled.
- **Cost**: nothing loaded at startup; first request per project builds a cached tree+docs digest; per-request context packed within a token budget.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core Technologies
#### (a) Async HTTP + SSE streaming
| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| `vim.system()` + system `curl` | Neovim >= 0.10 | Async HTTPS with per-chunk streaming stdout | The de-facto 2026 standard. `vim.system` is Neovim's blessed async process API (async by default with `on_exit`, or sync via `:wait()`), gives per-chunk `stdout(err, data)` callbacks, `stdin` for the POST body, `timeout`, and `SystemObj:kill()` for cancellation — everything SSE streaming needs, with zero dependencies. CodeCompanion (the reference AI plugin for Neovim) ships exactly this: raw `curl` argv + `vim.system` + line-buffered stream callback | HIGH — verified in official `lua.txt` docs and codecompanion source |
| `curl` binary (pin `pkgs.curl`) | any current (>= 7.55 for `--header @file`) | SSE transport: `-N` (no buffering), `--data-binary`, `--dump-header`, `--header @file` | `curl` is on every system incl. NixOS (`/run/current-system/sw/bin`), speaks HTTP/2, TLS, proxies. `-N` is mandatory for SSE or curl buffers. Pass its **absolute Nix path** into plugin config (`curl_bin = "${pkgs.curl}/bin/curl"`) so the plugin never depends on `PATH` | HIGH — curl docs; nvf precedent: `fzf_bin = lib.getExe pkgs.fzf` |
| `vim.schedule()` around all buffer writes | Neovim core | Make stream callbacks textlock/fast-event safe | `vim.system`'s stdout handler runs in a fast event (`vim.in_fast_event()` is true): Lua state only, *no editor state*. Official rule: "To perform editor operations, Lua code must schedule via `vim.defer_fn()` or `vim.schedule()`". Buffer mutation from the curl callback without `vim.schedule` = hard errors | HIGH — verified in official `api.txt` (api-fast section) |
| Anthropic Messages API, SSE (`stream: true`) | `anthropic-version: 2023-06-01` | Code generation backend | Constraint from PROJECT.md. Stream taxonomy from the official SDK: `message_start` → `content_block_start` → `content_block_delta` (`text_delta` chunks) → `content_block_stop` → `message_delta` → `message_stop`, plus `ping` and `error`. Parse `data: ` lines, `vim.json.decode` each, accumulate `text_delta` | HIGH — verified in anthropics/anthropic-sdk-typescript types (`RawMessageStreamEvent`) |
#### (b) Extmark-based buffer insertion UX
| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| `nvim_buf_set_extmark` with `right_gravity = false`, `end_right_gravity = true` | API since 0.8 | Anchor the generation region; it grows as text streams in | One extmark with `end_row` gives a start that stays put (`right_gravity=false`) and an end that shifts right as lines are appended (`end_right_gravity=true`). Anchors survive edits above the region. This is the resolved answer to the "reservation vs streaming" open question: **append at the end anchor, never pre-allocate lines** | HIGH — verified in official `api.txt` option docs |
| `nvim_buf_set_lines(buf, end_row, end_row, false, lines)` at the mark's end | core API | Whole-line appends during streaming | Read the end position fresh from `nvim_buf_get_extmark_by_id` on each flush; insert at the end row only. Never overwrites anything below — the region creeps down (accepted tradeoff, PROJECT.md decision) | HIGH |
| `virt_text` / `virt_lines` on the anchor | core API | "Generating..." placeholder + preview of the incomplete partial line | Show the not-yet-complete line as virtual text at the anchor and only materialize it as real text when the line completes. Zero buffer mutation for partials = zero undo noise, zero cursor disturbance | HIGH — verified in `api.txt` |
| `vim.cmd("undojoin")` (pcall'd) | `:undojoin`, ancient | One undo step per generation | Without it every streamed chunk is its own undo entry — unusable. Docs warn: never call after undo/redo, and it errors if there is no previous change → wrap in `pcall`, call before each append after the first | HIGH — verified in official `undo.txt` |
| `vim.ui.input` | since 0.5 | The one-line prompt input | Dependency-free; overridable by UI plugins (snacks.input is already in shmulvim's config), so the prompt looks native either way | HIGH — verified in `lua.txt` |
| One `nvim_create_namespace` per generation | core API | Independent multi-anchor bookkeeping | Lets `hl_group`/`line_hl_group` tint each AI-drafted region and delete/clean per generation without cross-talk | HIGH |
#### (c) Nix flake + home-manager packaging
| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| `pkgs.vimUtils.buildVimPlugin { pname; version; src = self; }` | nixpkgs unstable | `packages.default` — the plugin as a runtime-path derivation | The standard nixpkgs builder for a self-contained Lua plugin. Ships `neovimRequireCheckHook` which headless-`require`s every lua module at build time (escape hatch: `nvimSkipModule`) — free CI on every `nix build`. Correct granularity: a plugin package, not a wrapped editor | HIGH — verified `nix eval nixpkgs#vimUtils` attr list + nixpkgs manual |
| `flake-utils.lib.eachDefaultSystem` + top-level `homeManagerModules.default` | flake-utils | Flake output shape | Mirrors shmulvim's `flake.nix` exactly (`packages.default` per system, `homeManagerModules.default` merged outside). cabanashmul already consumes `inputs.<flake>.homeManagerModules.default` — matching the sibling means zero adapter code | HIGH — local evidence (shmulvim flake.nix, cabanashmul wiring) |
| Plain home-manager module exposing `programs.vim-module.*` | home-manager | Options: `enable`, `model`, `keymap`, `budgets`, `curl_bin`, `api_key_env` | The shmulvim pattern (`home-manager.nix` exposes `programs.shmulvim.*`, config flows Nix → Lua). vim-module's module needs only HM's `pkgs`/`lib` — **no nvf input binding** (unlike shmulvim's `{ nvf }:` wrapper), because it builds a plugin, not a neovim | HIGH |
| Injection into the shmulvim-built nvim via `programs.shmulvim.extraConfig` | existing option | `vim.opt.runtimepath:prepend("<plugin store path>")` + `require("vim_module").setup({ ... })` with config serialized from Nix options | The only channel that already exists into shmulvim's nvf-built editor. Works because the plugin is designed pure-`lua/` + explicit `setup()` (no `plugin/`-dir side effects to source). Uses the exact escape hatch shmulvim provides (`extraConfig` → `luaConfigRC`) and the same Nix→Lua config-via-globals idiom shmulvim itself uses (`shmulvim_clipboard_provider`) | HIGH — option exists (shmulvim home-manager.nix) |
### Supporting Libraries
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `vim.json` (built-in) | core | Decode SSE `data:` payloads and the context-digest manifest | Always — never hand-roll JSON |
| `vim.fs` / `vim.uv` (built-in) | core | Walk the project tree for the cached context digest; read README/docs | First request per project only (cold-start design) |
| `vim.notify` (built-in) | core | Status: "Generating...", errors, done | Always |
| `mini.test` | current | Headless plugin tests | If/when tests are wanted — dependency-free, the modern choice; do NOT pull plenary for tests either |
### Development Tools
| Tool | Purpose | Notes |
|------|---------|-------|
| `nix build` / `nix flake check` | Build + the `neovimRequireCheckHook` smoke test | The require-check makes every build a load test; use `nvimSkipModule` only for submodules needing live state |
| `nix flake lock --update-input nixpkgs` | Keep the pin moving with shmulvim's nixpkgs | Both flakes follow `nixos-unstable`; consumers set `inputs.nixpkgs.follows = "nixpkgs"` |
| `lua-language-server` + `stylua` (nixpkgs) | Lua DX | Optional; add `.luarc.json` targeting `lua5.1`/Neovim globals if wanted |
| `mini.test` via `nix develop` shell | Tests | Dev-only, never a runtime dep |
## Installation
# Build the plugin package
# In cabanashmul/flake.nix inputs:
#   vim-module.url = "github:shmul95/vim-module";
#   vim-module.inputs.nixpkgs.follows = "nixpkgs";
# In cabanashmul/public/vim-module.nix:
#   imports = [ inputs.vim-module.homeManagerModules.default ];
#   programs.vim-module = { enable = true; model = "claude-haiku-4-5"; };
# API key at runtime (never in Nix):
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| `vim.system` + raw curl | `plenary.curl` (has a real `stream` opt — `on_stdout = opts.stream` over `plenary.job`) | Only if the plugin were already plenary-based. plenary.curl works, but drags all of plenary.nvim (~10k lines, low maintenance) for one job wrapper, and its default `--header name: value` argv style puts the API key on the command line (readable via `ps`). Our vim.system approach copies avante's security hardening instead (see What NOT to Use) |
| `vimUtils.buildVimPlugin` | `neovimUtils.buildNeovimPlugin` | Switch when the plugin gains external build deps (luarocks, treesitter grammars). For self-contained `lua/`, `buildVimPlugin` is the standard and lighter |
| `vimUtils.buildVimPlugin` + rtp injection | `wrapNeovim` / `neovim.override { configure = ... }` | Only for standalone testing of the plugin *outside* shmulvim (a throwaway dev shell). Distributing a wrapped nvim would collide with the shmulvim-built editor — wrong granularity for a plugin flake |
| `programs.shmulvim.extraConfig` injection | New generic `programs.shmulvim.extraPlugins` passthrough in shmulvim (mapping to nvf `vim.extraPlugins` / `vim.lazy.plugins.<name>.keys`) | Choose this if a second external plugin ever follows, or if literal zero-load-at-startup becomes a hard requirement (lazy.nvim `keys`-triggered load — shmulvim already runs lazy.nvim with the harpoon `keys` precedent). Cleaner long-term, but requires one sibling edit; `extraConfig` works today with zero coupling |
| nvf integration surface (consumption) | nvf as the *builder* of this plugin | nvf builds editors, not plugins — never use `nvf.lib.neovimConfiguration` inside vim-module's flake. But the *consumer* is nvf-based, so the injection target is nvf's rtp/lazy world (via shmulvim) |
| flake-utils | flake-parts | cabanashmul uses flake-parts at the meta level, but the sibling plugin flake (shmulvim) uses flake-utils. Mirror the sibling; do not mix styles per flake |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `plenary.nvim` as a runtime dependency | Heavyweight for what `vim.system` does natively; unmaintained relative to core; violates the "no heavy dependency" constraint | `vim.system` + curl |
| API key on curl argv (`-H "x-api-key: …"` as a plain arg) or in Nix options/store | Any user on the machine can read it from `ps`; Nix store is world-readable. avante.nvim literally rewrote plenary.curl to fix this | Write headers to a `0600` temp file and pass `--header @file` (avante's approach), or `--config -` with the config on `vim.system`'s stdin. Key comes from `$ANTHROPIC_API_KEY` read at request time, never compiled into config |
| node / python / external-CLI bridges | Violates the plain-Lua constraint; fragile spawning | curl + `vim.system` |
| `wrapNeovim` as the flake's `packages.default` | Produces a second nvim binary that fights shmulvim's | `vimUtils.buildVimPlugin` (plugin runtime tree) |
| lazy.nvim (or any manager) as a *hard* plugin dependency | Plugin must load in any setup; manager APIs are not a stable contract | Pure `lua/` + `require("vim_module").setup()`; lazy-load only via the host config if at all |
| Buffer writes from curl callbacks / luv callbacks directly | Fast-event/textlock errors ("not allowed when textlock is active") | `vim.schedule()` the flush |
| Pre-reserving blank lines (`12o<esc>` sketch) | The superseded reservation instinct; breaks undo, cursor, and edits below | Extmark end-anchor append (grows downward) |
| `vim.fn.append()` / `nvim_put()` for insertion | Touch the unnamed register and cursor; noisy in insert mode | `nvim_buf_set_lines` / `nvim_buf_set_text` |
| `vim.lsp.util.apply_text_edits` or a fake LSP server | LSP coupling for no gain; text edits fight the anchor model | Extmark-anchored append |
| Fixed user-agent-less/undumped HTTP without `--dump-header` | No way to read the HTTP status on streamed responses | `--dump-header` to a temp file, parse status like codecompanion does |
| keymap `<super+f>` via terminal-ambiguous `<D-f>` assumptions without fallback | Super keybindings depend on terminal/kitty config | Map it, but expose `keymap` as a module option (it already is) |
## Stack Patterns by Variant
- Inject the plugin through shmulvim's future `extraPlugins` passthrough as an nvf `vim.lazy.plugins.<name>` entry with `keys = [ "<super+f>" ]`.
- Because lazy.nvim is already enabled in the shmulvim build and `keys`-triggered loading defers all Lua module loading to first press (harpoon precedent exists).
- v1 acceptable compromise: load the small Lua module at config time via `extraConfig`; the *costly* cold start (context digest, network) is already per-request lazy.
- `curl_bin` module option, default `"${pkgs.curl}/bin/curl"` under Nix, `vim.fn.exepath("curl")` fallback otherwise.
- Because Nix purity should not be assumed from `PATH` inside a wrapped editor.
- Swap the package to `pkgs.neovimUtils.buildNeovimPlugin`.
- Because that's the nixpkgs variant with external-dep hooks.
- Keep one queue per anchor namespace (v1: a single global sequential queue per PROJECT.md).
- Because extmark namespaces give per-generation isolation for free; parallelism is additive later.
## Version Compatibility
| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| Neovim >= 0.10 | `vim.system` | Floor for the whole transport. nvf on nixos-unstable ships 0.11+ in practice; set `vim.version` check in `setup()` and fail early | 
| Neovim >= 0.8 | extmark `end_right_gravity` | Covered by the 0.10 floor |
| `anthropic-version: 2023-06-01` | Messages API streaming | Stream event taxonomy stable since launch (`text_delta` etc. — verified against current official SDK types) |
| nixpkgs unstable `vimUtils.buildVimPlugin` | `neovimRequireCheckHook` | Present on current nixpkgs master (verified via `nix eval`). If a module can't be require-checked standalone, pass `nvimSkipModule = [ ... ]` |
| flake-utils `eachDefaultSystem` | top-level `// { homeManagerModules = ...; }` | The exact shmulvim composition; `homeManagerModules` (not `homeModules`) is what cabanashmul references today — match it |
| `curl` >= 7.55 | `--header @file` | Any current NixOS/nixpkgs curl satisfies this |
| Plugin's `lua/`-only layout | `runtimepath:prepend` + `require` at config time | Works regardless of plugin manager; does not depend on `plugin/` sourcing timing |
## Sources
- Neovim `runtime/doc/lua.txt` (`vim.system()` signature, SystemObj methods, `vim.ui.input`) — official docs via neovim/neovim master; HIGH
- Neovim `runtime/doc/api.txt` (api-fast/textlock rules, `nvim_buf_set_extmark` gravity/virt_text/virt_lines/invalidate options) — official docs; HIGH
- Neovim `runtime/doc/undo.txt` (`:undojoin` semantics and warnings) — official docs; HIGH
- anthropics/anthropic-sdk-typescript `src/resources/messages/messages.ts` (`RawMessageStreamEvent`, `TextDelta {type:'text_delta'}`, `message_start/stop`, `content_block_delta`) — official SDK source; HIGH
- olimorris/codecompanion.nvim `lua/codecompanion/http.lua` + `lua/codecompanion/utils/curl.lua` — reference implementation of the vim.system + curl + vim.schedule SSE pattern; HIGH
- yetone/avante.nvim `lua/avante/utils/curl.lua` — "Drop-in replacement for plenary.curl that keeps headers/body/auth off curl's command line, where any user can read them (e.g. ps)"; source of the `--header @file` hardening; HIGH
- nvl-lua/plenary.nvim `lua/plenary/curl.lua` — verified it *does* stream (`opts.stream` → `on_stdout`) but via plenary.job with key-on-argv defaults; MEDIUM-HIGH (read directly)
- nvf docs `docs/manual/tips/plugin-sources.md` (`vim.extraPlugins = { name = { package; setup; } }`, `vim.startPlugins`, buildVimPlugin-from-source recipe) — official docs; HIGH
- Context7 (`notashelf/nvf`) — corroborated extraPlugins/setup pattern; HIGH
- nixpkgs `vimUtils`/`neovimUtils` attribute sets — verified live via `nix eval nixpkgs#vimUtils`; HIGH
- Local: `~/Repositories/shmulvim/flake.nix`, `~/Repositories/shmulvim/home-manager.nix`, `~/Repositories/cabanashmul/public/shmulvim.nix` — the dendritic contract to match; HIGH
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
