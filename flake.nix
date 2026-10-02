{
  description = "yap — the Neovim buffer is the conversation; a Go backend streams LLM replies into it";

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
            pname = "yap-agent";
            version = self.shortRev or self.dirtyShortRev or "dev";
            src = self;
            subPackages = [ "agent" ];
            vendorHash = "sha256-84XL+Y4InzLLiKG+BWrPS/t2ryb81EBA2PmixqxnlPY=";
            env.CGO_ENABLED = "0";
            meta.mainProgram = "agent";
          };

          # Neovim plugin (the harness). Provides require("harness").
          harness = pkgs.vimUtils.buildVimPlugin {
            pname = "yap";
            version = self.shortRev or self.dirtyShortRev or "dev";
            src = self;
          };

          default = self.packages.${system}.agent;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # markdown + markdown_inline grammars for Neovim's built-in
          # treesitter (auto-discovered from parser/*.so on the runtimepath).
          markdownParsers = pkgs.symlinkJoin {
            name = "yap-markdown-parsers";
            paths = [
              pkgs.vimPlugins.nvim-treesitter.grammarPlugins.markdown
              pkgs.vimPlugins.nvim-treesitter.grammarPlugins.markdown_inline
            ];
          };

          # Same grammars plus nvim-treesitter's highlight queries.
          markdownTreesitter = pkgs.symlinkJoin {
            name = "yap-markdown-treesitter";
            paths = [
              pkgs.vimPlugins.nvim-treesitter
              markdownParsers
            ];
          };

          # render-markdown.nvim (bundles its own queries; needs the parsers).
          renderMarkdown = pkgs.vimPlugins.render-markdown-nvim;

          # Clean dev Neovim, this plugin only. Extra launchers below add
          # treesitter highlighting or the touchup renderer on top of the
          # same clean base.
          yap-nvim = pkgs.writeShellApplication {
            name = "yap-nvim";
            runtimeInputs = [ pkgs.neovim ];
            text = ''
              root="''${YAP_ROOT:-$(pwd)}"
              # Ignore an ambient Neovim install (e.g. a home-manager nightly):
              # otherwise its VIMRUNTIME shadows the Nix neovim's own runtime.
              unset VIM VIMRUNTIME
              exec nvim -u NONE -i NONE --cmd "set rtp^=$root" -c "runtime! plugin/yap.lua" -c "lua require('harness').setup()" "$@"
            '';
          };

          # Clean + markdown treesitter syntax highlighting.
          yap-nvim-treesitter = pkgs.writeShellApplication {
            name = "yap-nvim-treesitter";
            runtimeInputs = [ pkgs.neovim ];
            text = ''
              root="''${YAP_ROOT:-$(pwd)}"
              unset VIM VIMRUNTIME
              exec nvim -u NONE -i NONE \
                --cmd "set rtp^=$root,${markdownTreesitter}" \
                -c "runtime! plugin/yap.lua" \
                -c "lua require('harness').setup()" \
                -c "lua vim.api.nvim_create_autocmd('FileType', { pattern = 'markdown', callback = function(e) vim.treesitter.start(e.buf, 'markdown') end })" \
                "$@"
            '';
          };

          # Clean + touchup renderer (needs the markdown grammars).
          yap-nvim-touchup = pkgs.writeShellApplication {
            name = "yap-nvim-touchup";
            runtimeInputs = [ pkgs.neovim ];
            text = ''
              root="''${YAP_ROOT:-$(pwd)}"
              tu="''${TOUCHUP_ROOT:-/opt/code/touchup.nvim}"
              if [ ! -d "$tu" ]; then
                echo "yap-nvim-touchup: TOUCHUP_ROOT not found: $tu" >&2
              fi
              unset VIM VIMRUNTIME
              exec nvim -u NONE -i NONE \
                --cmd "set rtp^=$root,$tu,${markdownParsers}" \
                -c "runtime! plugin/yap.lua" \
                -c "lua require('harness').setup()" \
                -c "lua require('touchup').setup()" \
                "$@"
            '';
          };

          # Clean + render-markdown.nvim (bundles its own queries; needs the
          # markdown grammars). Sources its plugin file like yap does.
          yap-nvim-render-markdown = pkgs.writeShellApplication {
            name = "yap-nvim-render-markdown";
            runtimeInputs = [ pkgs.neovim ];
            text = ''
              root="''${YAP_ROOT:-$(pwd)}"
              unset VIM VIMRUNTIME
              exec nvim -u NONE -i NONE \
                --cmd "set rtp^=$root,${renderMarkdown},${markdownParsers}" \
                -c "runtime! plugin/yap.lua" \
                -c "lua require('harness').setup()" \
                -c "runtime! plugin/render-markdown.lua" \
                "$@"
            '';
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.go
              pkgs.neovim
              yap-nvim
              yap-nvim-treesitter
              yap-nvim-touchup
              yap-nvim-render-markdown
            ];

            shellHook = ''
              export YAP_ROOT="$(pwd)"
              export TOUCHUP_ROOT="''${TOUCHUP_ROOT:-/opt/code/touchup.nvim}"
              if [ -d "$YAP_ROOT/agent" ]; then
                export YAP_BIN="$YAP_ROOT/.dev/bin/yap"
                mkdir -p "$YAP_ROOT/.dev/bin"
                if ( cd "$YAP_ROOT" && ${pkgs.go}/bin/go build -o "$YAP_BIN" ./agent ); then
                  echo "yap: built agent -> $YAP_BIN"
                else
                  echo "yap: agent build failed (see above); Neovim still usable, :YapSend will not work" >&2
                fi
                export PATH="$YAP_ROOT/.dev/bin:$PATH"
              else
                echo "yap: run 'nix develop' from the repo root (agent/ not found)" >&2
              fi
              echo "yap: yap-nvim (clean) | yap-nvim-treesitter | yap-nvim-touchup | yap-nvim-render-markdown"
            '';
          };
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
          cfg = config.programs.yap;
          json = pkgs.formats.json { };
          system = pkgs.stdenv.hostPlatform.system;
          defaultAgent = self.packages.${system}.agent;
        in
        {
          options.programs.yap = with lib; {
            enable = mkEnableOption "yap — buffer-as-conversation LLM chat for Neovim";

            agentPackage = mkOption {
              type = types.package;
              default = defaultAgent;
              defaultText = literalExpression "inputs.yap.packages.\${system}.agent";
              description = "The yap backend binary package.";
            };

            settings = mkOption {
              type = json.type;
              default = { };
              example = {
                providers.moonshot = {
                  base_url = "https://api.moonshot.ai/v1";
                  api_key_env = "MOONSHOT_API_KEY";
                };
                websearch.api_key_env = "EXA_API_KEY";
                pricing.kimi-k3 = {
                  input = 3.0;
                  output = 15.0;
                };
              };
              description = ''
                Agent configuration, written to {file}`~/.config/yap.json`.
                Keys are `providers` (name → base_url + api_key_env),
                `websearch` (api_key_env for the Exa search tool) and
                `pricing` (model → USD per 1M tokens, an override for the
                committed catalog in agent/pricing). API keys themselves are
                referenced by environment variable name in `api_key_env`.
              '';
            };

            agentsFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Path to the system-prompt file for new buffers, passed to
                the harness as `agents_file`. The file is user-managed;
                point it at a file outside the Nix store (for example
                {file}`~/.yap/AGENTS.md`). When null the harness falls back
                to its default and then to `system`. The harness always
                prepends its own `# About Yap` boilerplate to every turn,
                independent of this file.
              '';
            };

            templatesDir = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Directory of `:YapInsert` templates, passed to the harness
                as `templates_dir`. When null the harness default
                ({file}`~/.config/yap/templates`) is used.
              '';
            };

            skillsDir = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Directory of skill files merged into the system block,
                passed to the harness as `skills_dir`. When null the
                harness default ({file}`~/.config/yap/skills`) is used.
              '';
            };

            rolesDir = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Directory of subagent role definitions, passed to the harness
                as `roles_dir`. When null the harness default
                ({file}`~/.yap/roles`) is used.
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
            descriptionModel = mkOption {
              type = types.str;
              default = "openai/gpt-5-nano";
              description = "Smallest provider/model combo used to label a session from the latest user message on send.";
            };
            descriptionAnswerModel = mkOption {
              type = types.str;
              default = "openai/gpt-5-mini";
              description = "Bigger provider/model combo that writes the final whole-session title once each turn completes.";
            };
          };

          config = lib.mkIf cfg.enable {
            home.file.".config/yap.json" = lib.mkIf (cfg.settings != { }) {
              source = json.generate "yap.json" cfg.settings;
            };
          };
        };
    };
}
