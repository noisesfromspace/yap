#!/usr/bin/env bash
# pitel test suite: Go unit tests, then headless-Neovim suites against
# local mock providers (python3 stdlib only). Run from anywhere:
#
#   tests/run.sh
#
# Go tests cover the agent loop, tools, diffing and /models listing;
# the Lua suites cover buffer semantics, parsing, folds and winbar.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PITEL_ROOT="$ROOT"
export MOONSHOT_API_KEY="${MOONSHOT_API_KEY:-pitel-test-key}"

TESTHOME="$(mktemp -d)"
mkdir -p "$TESTHOME/.config"
trap 'rm -rf "$TESTHOME"; kill $(jobs -p) 2>/dev/null' EXIT
export XDG_CONFIG_HOME="$TESTHOME/.config"

cd "$ROOT" || exit 1
CGO_ENABLED=0 go build -o pitel ./agent || exit 1
CGO_ENABLED=0 go test ./... || exit 1

fail=0
run() { # name port [mock]
  local name="$1" port="$2" mock="${3:-}"
  rm -rf "$TESTHOME/.pitel/sessions"
  if [ "$mock" = "mock_models.py" ]; then
    cat > "$TESTHOME/.config/pitel.json" <<EOF
{"providers": {"zeta": {"base_url": "http://127.0.0.1:19999/v1", "api_key_env": "MOONSHOT_API_KEY"},
               "alpha": {"base_url": "http://127.0.0.1:$port/v1", "api_key_env": "MOONSHOT_API_KEY"}}}
EOF
  else
    cat > "$TESTHOME/.config/pitel.json" <<EOF
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
  # -u NONE skips user config, but a nix-pack-installed pitel can still
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

run pitel_test 18132 mock_slow.py
run pitel_static_test 18132 mock_slow.py
run pitel_block_test 18132 mock_slow.py
run pitel_e2e_tool_test 18133 mock_tool.py
run pitel_toolparse_test 18133 mock_tool.py
run pitel_e2e_livetool 18141 mock_stream.py
run pitel_e2e_streamfold 18135 mock_write.py
run pitel_picker_test 18137 mock_models.py
for t in pitel_fold_test pitel_detailfold_test pitel_think_test pitel_error_test pitel_ml_test \
         pitel_streamfold_test pitel_marker_test pitel_model_test pitel_map_test; do
  run "$t" 18132
done

if [ "$fail" -eq 0 ]; then
  echo "all tests passed"
else
  exit 1
fi
