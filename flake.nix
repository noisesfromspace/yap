{
  description = "pitel — the Neovim buffer is the conversation; a Go backend streams LLM replies into it";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # Go backend: provider client + agent loop, invoked by the harness.
          agent = pkgs.buildGoModule {
            pname = "pitel-agent";
            version = self.shortRev or self.dirtyShortRev or "dev";
            src = self;
            subPackages = [ "agent" ];
            vendorHash = "sha256-ZG3xBI73M4Bslx7i1bPdxgC7IkAxRPRgOB1OJMtGFdY=";
            env.CGO_ENABLED = "0";
            meta.mainProgram = "agent";
          };

          # Neovim plugin (the harness). Provides require("harness").
          harness = pkgs.vimUtils.buildVimPlugin {
            pname = "pitel";
            version = self.shortRev or self.dirtyShortRev or "dev";
            src = self;
          };

          default = self.packages.${system}.agent;
        }
      );

      homeManagerModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.pitel;
          json = pkgs.formats.json { };
          system = pkgs.stdenv.hostPlatform.system;
          defaultAgent = self.packages.${system}.agent;
        in
        {
          options.programs.pitel = with lib; {
            enable = mkEnableOption "pitel — buffer-as-conversation LLM chat for Neovim";

            agentPackage = mkOption {
              type = types.package;
              default = defaultAgent;
              defaultText = literalExpression "inputs.pitel.packages.\${system}.agent";
              description = "The pitel backend binary package.";
            };

            settings = mkOption {
              type = json.type;
              default = { };
              example = {
                providers.moonshot = {
                  base_url = "https://api.moonshot.ai/v1";
                  api_key_env = "MOONSHOT_API_KEY";
                };
                pricing.kimi-k3 = {
                  input = 3.0;
                  output = 15.0;
                };
              };
              description = ''
                Agent configuration, written to {file}`~/.config/pitel.json`.
                Keys are `providers` (name → base_url + api_key_env) and
                `pricing` (model → USD per 1M tokens). API keys themselves are
                referenced by environment variable name in `api_key_env`.
              '';
            };

            agentsMd = mkOption {
              type = types.nullOr types.lines;
              default = null;
              description = ''
                System prompt for new buffers, written to
                {file}`~/.config/pitel/AGENTS.md`. When null the file is left
                alone and the harness falls back to `system`.
              '';
            };

            # Harness (Lua) setup options; consumed by the Neovim config.
            provider = mkOption {
              type = types.str;
              default = "moonshot";
              description = "Default provider name for new chat buffers.";
            };
            model = mkOption {
              type = types.str;
              default = "kimi-k3";
              description = "Default model for new chat buffers.";
            };
            system = mkOption {
              type = types.str;
              default = "You are a helpful coding assistant. Answer concisely.";
              description = "Fallback system prompt when no AGENTS.md is present.";
            };
          };

          config = lib.mkIf cfg.enable {
            home.file.".config/pitel.json" = lib.mkIf (cfg.settings != { }) {
              source = json.generate "pitel.json" cfg.settings;
            };
            home.file.".config/pitel/AGENTS.md" = lib.mkIf (cfg.agentsMd != null) {
              text = cfg.agentsMd;
            };
          };
        };
    };
}
