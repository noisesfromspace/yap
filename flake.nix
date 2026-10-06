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
          lib = pkgs.lib;

          # Filter what each derivation ships. The flake is consumed via a
          # `path:` input (see /etc/nixos/flake), which copies the raw tree —
          # including .git/, build artifacts, and any `result` symlink that
          # `nix build` (without --no-link) drops in the repo root. Shipping
          # `self` verbatim leaks all of that into the store paths and trips
          # the plugin's noBrokenSymlinks check.
          pluginSrc = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./lua
              ./plugin
              ./doc
              ./README.md
              ./LICENSE
            ];
          };

          agentSrc = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./go.mod
              ./go.sum
              ./agent
            ];
          };

          # bubblewrap filesystem jail for the code-executing tools (bash,
          # python, curl). Generates a wrapper named <name> that execs <tool>
          # inside a user/mount namespace: the nix store is read-only, the home
          # is writable except the secret dirs (shadowed by empty tmpfs,
          # mirroring agent/utils/pathguard.go secretPaths), /etc is never
          # mounted (so /etc/ssh and agenix secrets stay invisible), and only
          # $PWD and /tmp are writable. Network is deliberately shared, like
          # the pi-jailed precedent, so git/nix/curl keep working inside the
          # tool; the filesystem is the security boundary here.
          jailTool = name: tool:
            pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = [ pkgs.bubblewrap pkgs.coreutils ];
              text = ''
                set -euo pipefail

                # Per-user fake passwd/group so the jail exposes no host
                # accounts (root + the caller), generated at runtime like the
                # pi-jailed wrapper. uid/gid come from bash builtins; only the
                # cosmetic group name shells out to id (bash has no builtin
                # for it), so this is one exec instead of four.
                uid="''${UID:-$(id -u)}"
                gid="''${GROUPS[0]:-$(id -g)}"
                user="''${USER:-$(id -un)}"
                group="$(id -gn)"
                jail_dir="''${XDG_CACHE_HOME:-''$HOME/.cache}/yap-jail"
                mkdir -p "$jail_dir"
                {
                  printf 'root:x:0:0:System administrator:/root:/bin/false\n'
                  printf '%s:x:%s:%s::%s:/bin/false\n' "$user" "$uid" "$gid" "$HOME"
                } > "$jail_dir/passwd"
                {
                  printf 'root:x:0:\n'
                  printf '%s:x:%s:\n' "$group" "$gid"
                } > "$jail_dir/group"

                cwd="$(pwd -P)"

                ARGS=(
                  # User + process isolation; network stays shared on purpose.
                  --unshare-user --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup
                  --new-session --die-with-parent
                  --proc /proc --dev /dev

                  # Shebang interpreters: scripts (#!...), make, git hooks,
                  # and npm run all resolve /bin/sh and /usr/bin/env, so point
                  # them at the store copies instead of leaving them absent.
                  --symlink ${pkgs.bash}/bin/sh /bin/sh
                  --symlink ${pkgs.coreutils}/bin/env /usr/bin/env

                  # Read-only nix (store + profiles + daemon socket) so the
                  # system's binaries stay usable, plus the system profile
                  # (/run/current-system/sw/bin: git, rg, curl, nix, ...) and
                  # the real host /tmp so the agent's temp scripts and scratch
                  # survive across calls.
                  --ro-bind /nix /nix
                  --ro-bind-try /run/current-system /run/current-system
                  --bind /tmp /tmp

                  # Writable home with fake accounts; the secret dirs are
                  # shadowed below. This differs from pi-jailed's empty tmpfs
                  # home: yap tools need git config, ~/.config, ~/.yap, etc.
                  --bind "$HOME" "$HOME"
                  --ro-bind "$jail_dir/passwd" /etc/passwd
                  --ro-bind "$jail_dir/group" /etc/group

                  # The current working directory is the other writable path.
                  --bind "$cwd" "$cwd"
                )

                # Shadow secret directories (mirrors agent/utils/pathguard.go).
                for p in "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$HOME/.config/sops"; do
                  if [ -d "$p" ]; then ARGS+=( --tmpfs "$p" ); fi
                done

                # known_hosts are public host fingerprints (not secrets);
                # bind them read-only so git-over-ssh works while the private
                # keys in ~/.ssh stay hidden by the tmpfs shadow above.
                for kh in "$HOME/.ssh/known_hosts" /etc/ssh/ssh_known_hosts; do
                  if [ -f "$kh" ]; then ARGS+=( --ro-bind "$kh" "$kh" ); fi
                done

                # Keep the ssh-agent socket reachable so git-over-ssh works.
                if [ -n "''${SSH_AUTH_SOCK-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
                  ARGS+=( --bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK" )
                fi

                # Network + TLS plumbing, read-only; /etc itself is never
                # mounted, so /etc/ssh and agenix secrets are invisible.
                for p in /etc/resolv.conf /etc/hosts /etc/nsswitch.conf /etc/ssl /etc/localtime /etc/nix; do
                  if [ -e "$p" ]; then ARGS+=( --ro-bind "$p" "$p" ); fi
                done
                if [ -e /run/systemd/resolve ]; then
                  ARGS+=( --ro-bind /run/systemd/resolve /run/systemd/resolve )
                fi

                exec bwrap "''${ARGS[@]}" -- ${tool} "$@"
              '';
            };

          jailBash = jailTool "yap-jail-bash" "${pkgs.bash}/bin/bash";
          jailPython = jailTool "yap-jail-python" "${pkgs.python3}/bin/python3";
          jailCurl = jailTool "yap-jail-curl" "${pkgs.curl}/bin/curl";
        in
        {
          # Go backend: provider client + agent loop, invoked by the harness.
          # Wrapped with the Playwright runtime (Node driver + Chromium) so the
          # playwright tool works out of the box, not only in the devShell. The
          # driver JS itself is downloaded once by playwright-go into
          # ~/.cache/ms-playwright-go on first use; the Node runtime and the
          # browser come from nixpkgs, not npm or the devShell.
          agent =
            let
              agentBin = pkgs.buildGoModule {
                pname = "yap-agent";
                version = self.shortRev or self.dirtyShortRev or "dev";
                src = agentSrc;
                subPackages = [ "agent" ];
                vendorHash = "sha256-I7sLCaZx1WvnjQeX23f/ihpXHnWPOXnOdKzah4PZ4hs=";
                env.CGO_ENABLED = "0";
                meta.mainProgram = "agent";
              };
            in
            pkgs.runCommand "yap-agent" {
              nativeBuildInputs = [ pkgs.makeWrapper ];
              meta.mainProgram = "agent";
            } ''
              mkdir -p "$out/bin"
              makeWrapper "${agentBin}/bin/agent" "$out/bin/agent" \
                --set-default PLAYWRIGHT_NODEJS_PATH "${pkgs.nodejs}/bin/node" \
                --set-default PLAYWRIGHT_CHROMIUM_PATH "${pkgs.chromium}/bin/chromium" \
                --set-default YAP_JAIL_BASH "$out/bin/yap-jail-bash" \
                --set-default YAP_JAIL_PYTHON "$out/bin/yap-jail-python" \
                --set-default YAP_JAIL_CURL "$out/bin/yap-jail-curl"
              # Ship the jail wrappers alongside the agent; the wrapper sets
              # YAP_JAIL_* above to these paths (see agent/utils/jail.go).
              for j in "${jailBash}" "${jailPython}" "${jailCurl}"; do
                ln -s "$j/bin/"* "$out/bin/"
              done
            '';

          # Standalone jail wrappers (for testing without a full agent build).
          "yap-jail-bash" = jailBash;
          "yap-jail-python" = jailPython;
          "yap-jail-curl" = jailCurl;

          # Neovim plugin (the harness). Provides require("harness").
          harness = pkgs.vimUtils.buildVimPlugin {
            pname = "yap";
            version = self.shortRev or self.dirtyShortRev or "dev";
            src = pluginSrc;
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
              (pkgs.python3.withPackages (p: [ p.msgpack ])) # attached-UI regression tests
              # Browser + runtime for the playwright tool (native Go client;
              # it shells out to the Node driver and drives nixpkgs chromium).
              pkgs.nodejs
              pkgs.chromium
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

            sessionsDir = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Directory where yap autosaves sessions and their scratch
                queues, passed to the harness as `sessions_dir`. When null
                the harness default ({file}`~/.yap/sessions`) is used.
              '';
            };

            auditDir = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Directory where yap writes audit logs, passed to the harness
                as `audit_dir`. When null the harness default
                ({file}`~/.yap/audit`) is used.
              '';
            };

            # Harness (Lua) setup options; consumed by the Neovim config.
            defaultProvider = mkOption {
              type = types.str;
              default = "moonshot";
              description = "Default provider name for new chat buffers.";
            };
            defaultModel = mkOption {
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
