#!/usr/bin/env bash
# yap test suite: Go unit tests, the attached-UI fold contract (Python
# msgpack), then the Lua suites under mini.test. Run from anywhere:
#
#   tests/run.sh
#
# Go tests cover the agent loop, tools, diffing and /models listing; the Lua
# suites cover buffer semantics, parsing, folds and winbar. tests/minitest.lua
# drives those: one case per tests/yap_*_test.lua script (see tests/suite.lua),
# each in its own child Neovim with an isolated $HOME.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export YAP_ROOT="$ROOT"
export MOONSHOT_API_KEY="${MOONSHOT_API_KEY:-yap-test-key}"

cd "$ROOT" || exit 1
YAP_BIN="${XDG_CACHE_HOME:-$HOME/.cache}/yap/bin/yap"
mkdir -p "$(dirname "$YAP_BIN")"
CGO_ENABLED=0 go build -o "$YAP_BIN" ./agent || exit 1
# The Lua tests invoke the agent as "$ROOT/yap" (a gitignored path). Point it
# at the freshly built binary so the suite is self-contained and does not
# depend on a pre-existing symlink in the checkout.
ln -sf "$YAP_BIN" "$ROOT/yap"
CGO_ENABLED=0 go test ./... || exit 1
export PATH="$(dirname "$YAP_BIN"):$PATH"
# yap_fold_ui_test drives an attached Neovim over msgpack RPC. The devShell's
# python3 already has msgpack; when the ambient one does not, pull an
# interpreter that has it from nix. `nix shell` is non-pure here, so the 0.13
# nvim already on PATH stays available for `nvim --embed`.
if python3 -c 'import msgpack' >/dev/null 2>&1; then
  python3 tests/yap_fold_ui_test.py || exit 1
else
  nix shell --impure --expr '(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.python3.withPackages (ps: [ ps.msgpack ])' -c python3 tests/yap_fold_ui_test.py || exit 1
fi

# mini.nvim is the test framework and is not vendored: use the checkout the
# devShell provides, or resolve one from nixpkgs.
if [ -z "${YAP_MINI_NVIM:-}" ]; then
  YAP_MINI_NVIM="$(nix build --impure --no-link --print-out-paths --expr '
    (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.vimPlugins.mini-nvim
  ')" || exit 1
fi
export YAP_MINI_NVIM

nvim --headless -u NONE -l tests/minitest.lua || exit 1
echo "all tests passed"
