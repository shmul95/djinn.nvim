# home-manager.nix — structure mirrors shmulvim's home-manager.nix, minus nvf
# SECURITY: no option holds a secret VALUE. api_key_env is the NAME of an env var.
# SECURITY: never log request payloads or headers — they may carry API keys.
{ self }: { config, lib, pkgs, options, ... }:
let
  inherit (lib) mkEnableOption mkIf mkAfter mkOption types optionalAttrs;
  cfg = config.programs.djinn;
  plugin = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # SAFE Nix->Lua serialization: JSON payload inside a Lua long-bracket string
  # whose bracket level is chosen so the closing delimiter can never occur in
  # the payload (otherwise a value containing e.g. ']==]' terminates the string
  # early and the remainder executes as Lua at editor startup).
  setupJson = builtins.toJSON {
    model = cfg.model; keymap = cfg.keymap; fallback_keymap = cfg.fallback_keymap;
    api_key_env = cfg.api_key_env; curl_bin = cfg.curl_bin; budgets = cfg.budgets;
  };
  # least n >= 0 such that ']' + n*'=' + ']' is not a substring of setupJson
  brLen = let
    go = n: if lib.hasInfix ("]${lib.concatStringsSep "" (lib.genList (_: "=") n)}]") setupJson then go (n + 1) else n;
  in go 0;
  br = lib.concatStringsSep "" (lib.genList (_: "=") brLen);
in {
  options.programs.djinn = {
    enable = mkEnableOption "djinn.nvim AI function generation" // { default = false; };
    model = mkOption { type = types.str; default = "claude-haiku-4-5"; description = "Anthropic model id"; };
    keymap = mkOption { type = types.str; default = "<D-f>"; description = "Primary trigger keymap (normal + insert)"; };
    fallback_keymap = mkOption { type = types.str; default = "<leader>af"; description = "Terminal-safe fallback chord"; };
    api_key_env = mkOption { type = types.str; default = "ANTHROPIC_API_KEY"; description = "NAME of the env var holding the API key — never a key value"; };
    curl_bin = mkOption { type = types.str; default = lib.getExe pkgs.curl; description = "Absolute path to curl"; };
    budgets = mkOption {
      type = types.submodule { options = {
        context_tokens = mkOption { type = types.ints.positive; default = 4000; description = "Token budget for packed context"; };
        max_output_tokens = mkOption { type = types.ints.positive; default = 1024; description = "Token budget for generated output"; };
      }; };
      default = {};
      description = "Token budgets (no secrets, ints only)";
    };
  };
  config = mkIf cfg.enable (optionalAttrs (options.programs ? shmulvim) {
    programs.shmulvim.extraConfig = mkAfter ''
      vim.opt.runtimepath:prepend("${plugin}")
      require("djinn").setup(vim.json.decode([${br}[${setupJson}]${br}]))
    '';
  });
}
