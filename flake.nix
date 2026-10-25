{
  description = "yap — the Neovim buffer is the conversation; a Go backend streams LLM replies into it";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Only used by `programs.yap.jail` (the optional bubblewrap launcher).
  # jail.nix is a dependency-free Nix library, so this costs consumers a
  # single small source fetch and nothing else.
  inputs.jail-nix.url = "sourcehut:~alexdavid/jail.nix";

  outputs =
    { self, nixpkgs, ... }:
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
                vendorHash = "sha256-w1A3+0/EL7oStJx4WsNNThP5uzTyOGHcZjjPGdCRkFs=";
                env.CGO_ENABLED = "0";
                meta.mainProgram = "agent";
              };
            in
            pkgs.runCommand "yap-agent"
              {
                nativeBuildInputs = [ pkgs.makeWrapper ];
                meta.mainProgram = "agent";
              }
              ''
                mkdir -p "$out/bin"
                makeWrapper "${agentBin}/bin/agent" "$out/bin/agent" \
                  --set-default PLAYWRIGHT_NODEJS_PATH "${pkgs.nodejs}/bin/node" \
                  --set-default PLAYWRIGHT_CHROMIUM_PATH "${pkgs.chromium}/bin/chromium"
              '';

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

          # The harness floor is Neovim 0.11 (`vim.snippet.expand`,
          # `vim.lsp.get_clients`); nixpkgs ships 0.12, which satisfies it,
          # so the dev shell uses pkgs.neovim directly (no from-master
          # overlay needed).

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
              pkgs.vimPlugins.mini-nvim # mini.test: the Lua suite's framework (tests/minitest.lua)
              # Browser + runtime for the playwright tool (native Go client;
              # it shells out to the Node driver and drives nixpkgs chromium).
              pkgs.nodejs
              pkgs.chromium
              # Test/lint tooling the suite shells out to: ripgrep backs the
              # search/glob tools' tests; golangci-lint enforces .golangci.yml.
              pkgs.ripgrep
              pkgs.golangci-lint
              yap-nvim
              yap-nvim-treesitter
              yap-nvim-touchup
              yap-nvim-render-markdown
            ];

            shellHook = ''
              export YAP_ROOT="$(pwd)"
              export TOUCHUP_ROOT="''${TOUCHUP_ROOT:-/opt/code/touchup.nvim}"
              # The Lua suite runs under mini.test; tests/run.sh falls back to
              # nixpkgs when this is unset (and outside the devShell).
              export YAP_MINI_NVIM="${pkgs.vimPlugins.mini-nvim}"
              if [ -d "$YAP_ROOT/agent" ]; then
                export YAP_CACHE="''${XDG_CACHE_HOME:-$HOME/.cache}/yap"
                export YAP_BIN="$YAP_CACHE/bin/yap"
                mkdir -p "$YAP_CACHE/bin"
                if ( cd "$YAP_ROOT" && CGO_ENABLED=0 ${pkgs.go}/bin/go build -o "$YAP_BIN" ./agent ); then
                  echo "yap: built agent -> $YAP_BIN"
                else
                  echo "yap: agent build failed (see above); Neovim still usable, send() will not work" >&2
                fi
                export PATH="$YAP_CACHE/bin:$PATH"
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

          # --- optional bubblewrap filesystem jail --------------------------
          # `programs.yap.jail` builds a launcher that runs the editor (and
          # therefore the yap backend it spawns) inside a bwrap namespace
          # whose filesystem is reduced to the launch directory plus the
          # binds below. That is what bounds a prompt-injected model: it can
          # only touch the case directory, not the rest of the home dir.
          jailCfg = cfg.jail;
          jailHome = config.home.homeDirectory;
          jailConfigHome = config.xdg.configHome;

          # These targets must match harness.setup() when the consumer overrides
          # the harness defaults.
          jailSessionsDir =
            if jailCfg.sessionsDir != null then jailCfg.sessionsDir else "${jailConfigHome}/yap/sessions";
          jailAgentsPath =
            if jailCfg.agentsTargetFile != null then
              jailCfg.agentsTargetFile
            else
              "${jailConfigHome}/yap/AGENTS.md";

          # Env-var names the configured providers and tools read credentials
          # from. GitHub defaults to GITHUB_TOKEN when no name is configured.
          jailEnvNames = lib.unique (
            lib.filter (v: v != null && v != "") (
              lib.mapAttrsToList (_: p: p.api_key_env or null) (cfg.settings.providers or { })
              ++ [
                (cfg.settings.websearch.api_key_env or null)
                (
                  let
                    name = cfg.settings.github.api_key_env or null;
                  in
                  if name == null || name == "" then "GITHUB_TOKEN" else name
                )
              ]
            )
          );

          sourceEnv =
            envFile:
            lib.optionalString (envFile != null) ''
              # Expand shell variables in paths such as $XDG_RUNTIME_DIR at launch.
              if [ -f "${envFile}" ]; then
                set -a
                . "${envFile}"
                set +a
              fi
            '';

          backendLauncher = pkgs.writeShellScriptBin "yap" ''
            ${sourceEnv cfg.envFile}
            exec ${lib.getExe cfg.agentPackage} "$@"
          '';

          jailLib = self.inputs.jail-nix.lib.extend {
            inherit pkgs;
            # jail.nix's default base permissions re-bind every store path in
            # the command's runtime closure. That collides with the wholesale
            # `--ro-bind /nix /nix` added below (a symlinked store path such
            # as Chromium's sandbox cannot be mounted over read-only /nix),
            # and the wholesale bind already exposes the whole closure.
            basePermissions =
              combinators: with combinators; [
                base
                fake-passwd
              ];
          };

          # What to run inside the jail. Defaults to the declarative Neovim
          # build (with wrapRc = false the config itself lives on disk, which
          # the module binds read-only below).
          jailCommand =
            if jailCfg.package != null then
              jailCfg.package
            else if config.programs.nixvim.enable or false then
              config.programs.nixvim.build.package
            else
              throw "programs.yap.jail: `package` must be set (programs.nixvim is not enabled, so there is nothing to wrap)";

          jailedPackage = jailLib "${jailCfg.name}-jailed" jailCommand (
            with jailLib.combinators;
            [
              # nvim is a TUI: `--new-session` would break ^C and the tty.
              no-new-session
              # Bind the launch directory read-write at its real path. jails'
              # base permissions tmpfs the home directory, which removes the
              # parents of any cwd beneath it, so recreate the immediate
              # parent first and then chdir back to the real path so `:pwd`
              # (and the agent's cwd) is the directory you launched from.
              (add-runtime ''
                RUNTIME_ARGS+=(--dir "$(dirname "$PWD")")
                RUNTIME_ARGS+=(--bind "$PWD" "$PWD")
              '')
              (unsafe-add-raw-args "--chdir \"$PWD\"")
              # Expose the whole toolchain: the nix store read-only plus the
              # system and user profile symlink-farms (resolved at runtime —
              # they move on rebuild) and the host PATH.
              (ro-bind "/nix" "/nix")
              (add-runtime ''
                for p in /run/current-system/sw ${escape "${jailHome}/.nix-profile"}; do
                  if [ -e "$p" ] || [ -L "$p" ]; then
                    t=$(readlink -f "$p" 2>/dev/null || true)
                    [ -n "$t" ] && RUNTIME_ARGS+=(--ro-bind "$t" "$p")
                  fi
                done
              '')
              (fwd-env "PATH")
              # Yap's config directory read-write: the ChatGPT subscription
              # login keeps a rotating refresh token there and rewrites it on
              # refresh. settings.json stays a symlink into the read-only
              # store. Everything else yap reads is bound read-only below.
              (add-runtime ''
                mkdir -p ${escape "${jailConfigHome}/yap"}
                RUNTIME_ARGS+=(--bind ${escape "${jailConfigHome}/yap"} ${escape "${jailConfigHome}/yap"})
              '')
              # The editor's own config (keymaps, theme, plugins). With
              # wrapRc = false this is a directory in the config home; bind it
              # only when it exists so non-nixvim setups still work.
              (add-runtime ''
                if [ -d ${escape "${jailConfigHome}/nvim"} ]; then
                  RUNTIME_ARGS+=(--ro-bind ${escape "${jailConfigHome}/nvim"} ${escape "${jailConfigHome}/nvim"})
                fi
              '')
            ]
            ++ lib.optional jailCfg.network network
            # Skills/agents/templates are instructions the model follows, so
            # they are read-only inside the jail: a prompt-injected model
            # must not be able to rewrite its own rules.
            ++ lib.optionals (jailCfg.extraReadOnlyPaths != [ ]) (
              map (p: try-ro-bind p p) jailCfg.extraReadOnlyPaths
            )
            ++ lib.optionals (jailCfg.extraWritablePaths != [ ]) [
              (add-runtime (
                lib.concatMapStrings (p: ''
                  mkdir -p ${escape p}
                  RUNTIME_ARGS+=(--bind ${escape p} ${escape p})
                '') jailCfg.extraWritablePaths
              ))
            ]
            # Mount sessions after the instruction directory binds so a
            # read-only parent cannot hide the writable session target.
            ++ lib.optional jailCfg.sessionsInCwd (add-runtime ''
              mkdir -p "$PWD/.yap-sessions"
              RUNTIME_ARGS+=(--bind "$PWD/.yap-sessions" ${escape jailSessionsDir})
            '')
            # Last, so it wins over the instruction-directory bind above. Guarded at
            # runtime: the override file is user-managed and may not exist yet.
            ++ lib.optional (jailCfg.agentsFile != null) (add-runtime ''
              if [ -f ${escape jailCfg.agentsFile} ]; then
                RUNTIME_ARGS+=(--ro-bind ${escape jailCfg.agentsFile} ${escape jailAgentsPath})
              fi
            '')
            ++ map (v: try-fwd-env v) jailEnvNames
          );

          jailLauncher = pkgs.writeShellScriptBin jailCfg.name ''
            ${sourceEnv (if jailCfg.envFile != null then jailCfg.envFile else cfg.envFile)}
            exec ${lib.concatStringsSep " " jailCfg.preExec} ${lib.getExe jailedPackage} "$@"
          '';
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
                websearch.provider = "exa";
                websearch.api_key_env = "EXA_API_KEY";
              };
              description = ''
                Agent configuration, written to
                {file}`$XDG_CONFIG_HOME/yap/settings.json` (default
                {file}`~/.config/yap/settings.json`).
                Keys are `providers` (name → base_url + api_key_env, or
                auth = "chatgpt" for a `yap login` subscription),
                `websearch` (provider name + api_key_env for the search
                tool). Model prices come from the committed catalog in
                agent/price. API keys themselves are referenced by
                environment variable name in `api_key_env`.
              '';
            };

            envFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = literalExpression ''"/run/agenix/my-api-keys"'';
              description = ''
                Shell file sourced by the generated backend launcher before
                starting the agent. Keep key values out of Nix settings.
              '';
            };

            backendPackage = mkOption {
              type = types.package;
              readOnly = true;
              default = backendLauncher;
              description = "Generated backend launcher; pass its executable to harness.setup({ bin = ... }).";
            };

            jail = {
              enable = mkEnableOption ''
                a bubblewrap launcher that runs the editor in a filesystem jail.
                The jail exposes the launch directory (read-write), the nix
                store and profile toolchain (read-only) and yap's own config,
                and nothing else: the rest of the home directory — `~/.ssh`,
                other projects, notes — simply is not mounted. This is what
                bounds a prompt-injected model. Linux only, and NOT a network
                boundary: it does not isolate the network namespace, so pair
                it with a VPN wrapper (see {option}`preExec`) if you need
                anonymity'';

              name = mkOption {
                type = types.str;
                default = "yap-jail";
                description = "Name of the launcher this adds to {file}`$PATH`.";
              };

              package = mkOption {
                type = types.nullOr types.package;
                default = null;
                defaultText = literalExpression "config.programs.nixvim.build.package";
                example = literalExpression "config.programs.nixvim.build.package";
                description = ''
                  Command to run inside the jail. Defaults to the declarative
                  Neovim build when {option}`programs.nixvim.enable` is set.
                  With `wrapRc = false` the editor config lives in
                  {file}`$XDG_CONFIG_HOME/nvim`, which the jail binds
                  read-only; editor *state* (shada/undo/sessions) stays
                  ephemeral on the jail's tmpfs home.
                '';
              };

              preExec = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = literalExpression ''[ "/run/wrappers/bin/tunnel" ]'';
                description = ''
                  Command words to place in front of the jailed command, for
                  hooks that must run *outside* bubblewrap. A setuid network
                  namespace wrapper belongs here: bwrap sets `NoNewPrivs`, so
                  it has to be the outermost process, never the inner one.
                '';
              };

              envFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Override {option}`programs.yap.envFile` for the jail.
                  Sourced outside bubblewrap; only configured credential
                  variable names are forwarded inside.
                '';
              };

              sessionsDir = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Session mount target inside the jail. Set this when
                  harness.setup() uses a non-default `sessions_dir`.
                '';
              };

              agentsTargetFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Target for the jail's `agentsFile` override. Set this when
                  harness.setup() uses a non-default `agents_file`.
                '';
              };

              network = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Share the host network namespace (plus TLS/DNS files).
                  Setting this to false removes network access entirely, which
                  makes exfiltration from the jail impossible but also breaks
                  model providers — it is only useful with a pre-populated
                  local model endpoint.
                '';
              };

              sessionsInCwd = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Keep sessions in {file}`$PWD/.yap-sessions` (bound onto the
                  harness's sessions directory) instead of the shared
                  sessions dir, so work stays with the case directory and is
                  not synced or backed up with everything else. Remember to
                  gitignore it (yap does not add to your ignore files).
                '';
              };

              agentsFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Bind this file over the harness's `agents_file` path inside
                  the jail, so this launcher gets different system prompt
                  rules while a normal session keeps the shared ones. The
                  content is read by the harness at session creation; the
                  file is not merged with the normal harness rules.
                '';
              };

              extraReadOnlyPaths = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = ''
                  Additional host paths to bind read-only at the same path
                  inside the jail. Missing paths are ignored.
                '';
              };

              extraWritablePaths = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = literalExpression ''[ "''${config.home.homeDirectory}/.local/share/nvim/site/spell" ]'';
                description = ''
                  Additional host paths to bind read-write at the same path
                  inside the jail (created if absent). Use for data that is
                  expensive to regenerate — spell dictionaries, for instance,
                  are re-downloaded on every launch without this.
                '';
              };
            };
          };

          config = lib.mkIf cfg.enable {
            xdg.configFile."yap/settings.json" = lib.mkIf (cfg.settings != { }) {
              source = json.generate "settings.json" cfg.settings;
            };

            assertions = [
              {
                assertion = !jailCfg.enable || pkgs.stdenv.hostPlatform.isLinux;
                message = "programs.yap.jail: bubblewrap jails are Linux-only.";
              }
            ];

            home.packages = [
              backendLauncher
            ]
            ++ lib.optional (jailCfg.enable && pkgs.stdenv.hostPlatform.isLinux) jailLauncher;
          };
        };
    };
}
