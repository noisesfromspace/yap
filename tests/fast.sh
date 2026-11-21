#!/usr/bin/env bash
# The fast Lua tier, for the pre-push loop: pure-Lua buffer/fold/winbar cases
# plus quick single-turn integration cases, run in parallel. Skips Go tests,
# the attached-UI fold contract, and the slow streaming/stop/steer tier (which
# run in CI via tests/run.sh). Run with:
#
#   nix develop --command tests/fast.sh
#
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export YAP_ROOT="$ROOT"
export MOONSHOT_API_KEY="test"

cd "$ROOT" || exit 1
YAP_BIN="${XDG_CACHE_HOME:-$HOME/.cache}/yap/bin/yap"
mkdir -p "$(dirname "$YAP_BIN")"
CGO_ENABLED=0 go build -o "$YAP_BIN" ./agent || exit 1
# The Lua tests invoke the agent as "$ROOT/yap" (a gitignored path). Point it
# at the freshly built binary, exactly as tests/run.sh does.
ln -sf "$YAP_BIN" "$ROOT/yap"
export PATH="$(dirname "$YAP_BIN"):$PATH"

# mini.nvim is the test framework and is not vendored: use the checkout the
# devShell provides, or resolve one from nixpkgs.
if [ -z "${YAP_MINI_NVIM:-}" ]; then
  YAP_MINI_NVIM="$(nix build --impure --no-link --print-out-paths --expr '
    (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.vimPlugins.mini-nvim
  ')" || exit 1
fi
export YAP_MINI_NVIM

YAP_TEST_TIER=fast nvim --headless -u NONE -l tests/minitest.lua
