# vim-module

An AI function-generation plugin for Neovim: press `<D-f>`, type a request ("write me a fibonacci function"), and generated code streams into the buffer starting at the cursor line. Fire-and-forget granularity — function by function, no chat — packaged as a Nix flake consumed by cabanashmul.

## Installation

Wire the flake into cabanashmul with two artifacts (final form — the wiring below assumes the GitHub repo exists; local checks use `--override-input`).

`flake.nix` inputs (in `/home/shmul95/Repositories/cabanashmul/flake.nix`):

```nix
vim-module.url                    = "github:shmul95/vim-module";
vim-module.inputs.nixpkgs.follows = "nixpkgs";
```

`public/vim-module.nix` (new file in `/home/shmul95/Repositories/cabanashmul/public/`):

```nix
{ inputs, ... }: {
  flake.cabanashmul.homeModules.vim-module = { ... }: {
    imports = [ inputs.vim-module.homeManagerModules.default ];

    programs.vim-module = {
      enable = true;
      model  = "claude-haiku-4-5";
    };
  };
}
```

Note: `import-tree ./public` picks the file up automatically — `_builder.nix` needs NO edit.

## Options

All options live under `programs.vim-module.*` (home-manager):

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the plugin |
| `model` | str | `claude-haiku-4-5` | Anthropic model id used for generation |
| `keymap` | str | `<D-f>` | Main trigger keymap (normal + insert) |
| `fallback_keymap` | str | `<leader>af` | Terminal-safe fallback chord (Super silently fails in many terminals) |
| `api_key_env` | str | `ANTHROPIC_API_KEY` | NAME of the environment variable read for the API key |
| `curl_bin` | str | `lib.getExe pkgs.curl` | Absolute path to the curl binary used for HTTPS |
| `budgets.context_tokens` | int | `4000` | Token budget for per-request context packing |
| `budgets.max_output_tokens` | int | `1024` | Token budget for generated output |

`api_key_env` holds the NAME of an environment variable, never a key value — no option ever holds secret material.

## Security rules

The invariant: never log request payloads or headers — they may carry API keys; logs and notifications carry status and sanitized error messages only. The API key is read from the configured environment variable at request time; it never touches the repo, the Nix store, or a process command line. This rule binds all later phases.

## Manual steps (user only — no automation)

1. Create and push the GitHub repo when ready, choosing visibility: `gh repo create shmul95/vim-module [--public|--private] --source . --push` (if private, the cabanashmul input must switch to `git+ssh://git@github.com/shmul95/vim-module`).
2. After publishing: `cd /home/shmul95/Repositories/cabanashmul && nix flake update vim-module`.
3. Rebuild/switch home-manager (e.g. `scripts/build-profiles.sh && scripts/switch-profile.sh <profile>` or `home-manager switch --flake /home/shmul95/Repositories/cabanashmul`).
4. Verify in nvim: `:lua print(require('vim_module'))`.

WARNING: Until the GitHub repo exists and `nix flake update vim-module` runs, any cabanashmul build WITHOUT `--override-input` fails resolving the `vim-module` input. Local verification uses `--override-input vim-module path:/home/shmul95/Repositories/vim-module` and does not depend on the remote.

## Development

Build/load-test with `nix build` — every build runs `neovimRequireCheckHook`, headless-requiring every lua module. `nix flake check` does the same via `checks.default`.
