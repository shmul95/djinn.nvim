# djinn.nvim

An AI function-generation plugin for Neovim: press a key, type a one-line request ("write me a fibonacci function"), and the generated code streams into the buffer at your cursor. Fire-and-forget by design — function by function, no chat, no autocomplete. AI drafts; you sculpt by hand.

**Version 1.0.0** — shipped and in daily use.

## How it works

- Plain Lua plugin, no plugin-manager dependency; `require("djinn").setup(opts)` is the only entry point.
- Streaming HTTPS via `vim.system` + `curl` speaking the Anthropic Messages API (SSE), so it also works with Anthropic-compatible providers (DeepSeek, etc.) through the `base_url` option.
- Context is gathered lazily on first request per project (tree + README/docs digest, cached) and packed per request within a token budget — nothing is loaded at editor startup.
- The API key is read from an environment variable at request time; it never appears in options, the Nix store, or a process command line.

## Requirements

- Neovim >= 0.10 (`vim.system`)
- `curl` (>= 7.55 for `--header @file`); under Nix an absolute path is injected automatically
- An API key for Anthropic or an Anthropic-compatible provider, exported as an environment variable

## Installation

### Home Manager (Nix)

Add the flake input:

```nix
djinn.url                    = "github:shmul95/djinn.nvim";
djinn.inputs.nixpkgs.follows = "nixpkgs";
```

Import the module and configure it:

```nix
{ inputs, ... }: {
  imports = [ inputs.djinn.homeManagerModules.default ];

  programs.djinn = {
    enable = true;
    model  = "claude-haiku-4-5";
  };
}
```

The module injects the plugin into a shmulvim-built Neovim via
`programs.shmulvim.extraConfig` (a runtimepath splice plus a `setup()` call).
Nothing else requires editing.

### Any other Neovim setup

`nix build` produces a standard plugin tree. Put it on your `runtimepath` and call:

```lua
require("djinn").setup({
  model = "claude-haiku-4-5",
  api_key_env = "ANTHROPIC_API_KEY",
})
```

## Usage

1. Put the cursor on the line where the code should start.
2. Press `<D-f>` (or `<leader>af` — Super often doesn't reach the terminal).
3. Type a one-line request, e.g. `write me a fibonacci function in python`.
4. Code streams in below the cursor. Existing text is never overwritten.

**Continuation mode** — write a function header yourself (e.g. `def fib(n: int) -> int:`), put the cursor on it, trigger djinn, and ask for "the rest". Only the body is generated, indented to match.

**Commands** — `:DjinnCancel` aborts the running generation; `:DjinnCancelAll` drains the queue. Requests are queued and run one at a time; each shows a "Generating…" indicator at its anchor.

Tip: give the API key only to the editor process, e.g. a shell wrapper or function that exports the variable just for `nvim`, rather than exporting it in your whole session.

## Options

All options live under `programs.djinn.*` (home-manager):

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the plugin |
| `model` | str | `claude-haiku-4-5` | Model id used for generation |
| `base_url` | str | `https://api.anthropic.com` | API root — set for Anthropic-compatible providers (e.g. `https://api.deepseek.com/anthropic`) |
| `keymap` | str | `<D-f>` | Main trigger keymap (normal + insert) |
| `fallback_keymap` | str | `<leader>af` | Terminal-safe fallback chord (Super silently fails in many terminals) |
| `api_key_env` | str | `ANTHROPIC_API_KEY` | NAME of the environment variable read for the API key |
| `curl_bin` | str | `lib.getExe pkgs.curl` | Absolute path to the curl binary used for HTTPS |
| `budgets.context_tokens` | int | `4000` | Token budget for per-request context packing |
| `budgets.max_output_tokens` | int | `1024` | Token budget for generated output |

`api_key_env` holds the NAME of an environment variable, never a key value — no option ever holds secret material.

## Using an Anthropic-compatible provider (e.g. DeepSeek)

```nix
programs.djinn = {
  enable      = true;
  model       = "deepseek-flash";
  base_url    = "https://api.deepseek.com/anthropic";
  api_key_env = "DEEPSEEK_API_KEY";
};
```

Export `DEEPSEEK_API_KEY` in the shell that launches Neovim.

## Security rules

The invariant: never log request payloads or headers — they may carry API keys; logs and notifications carry status and sanitized error messages only. The API key is read from the configured environment variable at request time; it never touches the repo, the Nix store, or a process command line.

## Development

Build/load-test with `nix build` — every build runs `neovimRequireCheckHook`, headless-requiring every lua module. `nix flake check` does the same via `checks.default`.

Run the test suite headless:

```sh
for f in tests/*.lua tests/*.lua-lite; do nvim --headless -u NONE -l "$f"; done
```
