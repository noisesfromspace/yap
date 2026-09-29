#!/usr/bin/env bash
# yap test suite: Go unit tests, then headless-Neovim suites against
# local mock providers (python3 stdlib only). Run from anywhere:
#
#   tests/run.sh
#
# Go tests cover the agent loop, tools, diffing and /models listing;
# the Lua suites cover buffer semantics, parsing, folds and winbar.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export YAP_ROOT="$ROOT"
export MOONSHOT_API_KEY="${MOONSHOT_API_KEY:-yap-test-key}"

TESTHOME="$(mktemp -d)"
mkdir -p "$TESTHOME/.config"
trap 'rm -rf "$TESTHOME"; kill $(jobs -p) 2>/dev/null' EXIT
export XDG_CONFIG_HOME="$TESTHOME/.config"

cd "$ROOT" || exit 1
CGO_ENABLED=0 go build -o yap ./agent || exit 1
CGO_ENABLED=0 go test ./... || exit 1
export PATH="$ROOT:$PATH"

fail=0
run() { # name port [mock]
  local name="$1" port="$2" mock="${3:-}"
  rm -rf "$TESTHOME/.yap"
  if [ "$mock" = "mock_models.py" ]; then
    cat > "$TESTHOME/.config/yap.json" <<EOF
{"providers": {"zeta": {"base_url": "http://127.0.0.1:19999/v1", "api_key_env": "MOONSHOT_API_KEY"},
               "alpha": {"base_url": "http://127.0.0.1:$port/v1", "api_key_env": "MOONSHOT_API_KEY"}}}
EOF
  else
    cat > "$TESTHOME/.config/yap.json" <<EOF
{"providers": {"mock": {"base_url": "http://127.0.0.1:$port/v1", "api_key_env": "MOONSHOT_API_KEY"}},
 "pricing": {"m1": {"input": 2.0, "output": 10.0}}}
EOF
  fi
  local mockpid=""
  if [ -n "$mock" ]; then
    python3 "tests/$mock" & mockpid=$!
    sleep 0.3
  fi
  local out
  # -u NONE skips user config, but a nix-pack-installed yap can still
  # shadow the repo on rtp; prepend the repo so tests exercise THIS tree.
  # `nvim -l` (not -c luafile + qa!): a failing assert exits non-zero —
  # with -c, E5113 prints but `qa!` still exits 0 and failures pass.
  if out=$(HOME="$TESTHOME" nvim --headless -u NONE \
      --cmd "set rtp^=$ROOT" -l "tests/$name.lua" 2>&1); then
    echo "ok   $name"
  else
    echo "FAIL $name"
    echo "$out" | tail -5
    fail=1
  fi
  if [ -n "$mockpid" ]; then
    kill $mockpid 2>/dev/null
    wait $mockpid 2>/dev/null
  fi
}

run yap_test 18132 mock_slow.py
run yap_static_test 18132 mock_slow.py
run yap_notify_test 18132 mock_slow.py
run yap_block_test 18132 mock_slow.py
run yap_compact_test 18132 mock_slow.py
run yap_e2e_tool_test 18133 mock_tool.py
run yap_toolparse_test 18133 mock_tool.py
run yap_e2e_livetool 18141 mock_stream.py
run yap_e2e_streamfold 18135 mock_write.py
run yap_audit_test 18135 mock_write.py
run yap_tail_rename_test 18135 mock_write.py
run yap_follow_test 18152 mock_follow.py
run yap_picker_test 18137 mock_models.py
for t in yap_fold_test yap_detailfold_test yap_think_test yap_error_test yap_ml_test \
         yap_streamfold_test yap_marker_test yap_model_test yap_map_test yap_clear_test \
         yap_live_open_test yap_uidiff_test yap_fencefold_test yap_lsp_test \
         yap_template_test yap_frontmatter_test yap_adopt_test; do
  run "$t" 18132
done

if [ "$fail" -eq 0 ]; then
  echo "all tests passed"
else
  exit 1
fi
