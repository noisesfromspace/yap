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
trap 'rm -rf "$TESTHOME"; kill $(jobs -p) 2>/dev/null' EXIT

cd "$ROOT" || exit 1
CGO_ENABLED=0 go build -o yap ./agent || exit 1
CGO_ENABLED=0 go test ./... || exit 1
export PATH="$ROOT:$PATH"

# Parallel test runner: start all Lua headless tests in background and fail fast
mkdir -p "$ROOT/tests/logs"

pids=()
names=()
mockpids=()
exitfiles=()
processed=()
declare -A mockmap

run() { # name port [mock]
  local name="$1" port="$2" mock="${3:-}"
  local TEST_DIR="$TESTHOME/$name"
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR/.config"

  if [ "$mock" = "mock_models.py" ]; then
    cat > "$TEST_DIR/.config/yap.json" <<EOF
{"providers": {"zeta": {"base_url": "http://127.0.0.1:19999/v1", "api_key_env": "MOONSHOT_API_KEY"},
               "alpha": {"base_url": "http://127.0.0.1:$port/v1", "api_key_env": "MOONSHOT_API_KEY"}}}
EOF
  else
    cat > "$TEST_DIR/.config/yap.json" <<EOF
{"providers": {"mock": {"base_url": "http://127.0.0.1:$port/v1", "api_key_env": "MOONSHOT_API_KEY"}},
 "pricing": {"m1": {"input": 2.0, "output": 10.0}}}
EOF
  fi

  local mockpid=""
  if [ -n "$mock" ]; then
    key="$mock:$port"
    if [ -z "${mockmap[$key]:-}" ]; then
      python3 "tests/$mock" & mockpid=$!
      mockmap[$key]="$mockpid"
      sleep 0.3
    else
      mockpid="${mockmap[$key]}"
    fi
  fi

  local log="$ROOT/tests/logs/$name.log"
  local exitfile="$ROOT/tests/logs/$name.exit"
  rm -f "$log" "$exitfile"

  # Run nvim in a background subshell and write its exit code to exitfile.
  (
    HOME="$TEST_DIR" nvim --headless -u NONE --cmd "set rtp^=$ROOT" -l "tests/$name.lua" >"$log" 2>&1
    echo $? > "$exitfile"
  ) &
  local pid=$!

  pids+=("$pid")
  names+=("$name")
  mockpids+=("$mockpid")
  exitfiles+=("$exitfile")
  processed+=(0)
}

# Start all tests in background
run yap_test 18132 mock_slow.py
run yap_static_test 18132 mock_slow.py
run yap_notify_test 18132 mock_slow.py
run yap_block_test 18132 mock_slow.py
run yap_e2e_tool_test 18133 mock_tool.py
run yap_toolparse_test 18133 mock_tool.py
run yap_e2e_livetool 18141 mock_stream.py
run yap_e2e_streamfold 18135 mock_write.py
run yap_audit_test 18135 mock_write.py
run yap_tail_rename_test 18135 mock_write.py
run yap_follow_test 18152 mock_follow.py
run yap_picker_test 18137 mock_models.py
run yap_describe_test 18139 mock_describe.py
for t in yap_fold_test yap_detailfold_test yap_think_test yap_error_test yap_ml_test \
         yap_streamfold_test yap_marker_test yap_model_test yap_map_test yap_keymap_test yap_clear_test \
         yap_live_open_test yap_uidiff_test yap_fencefold_test yap_lsp_test \
         yap_template_test yap_frontmatter_test yap_adopt_test yap_textobj_test \
         yap_nav_test yap_scratch_test; do
  run "$t" 18132
done

# Wait for backgrounded tests, fail fast on first non-zero exit.
wait_all() {
  local remaining=0
  for i in "${!exitfiles[@]}"; do
    if [ "${processed[$i]}" -eq 0 ]; then
      remaining=$((remaining+1))
    fi
  done
  while [ "$remaining" -gt 0 ]; do
    # wait -n blocks until any child process exits
    wait -n 2>/dev/null || true

    # check exitfiles to see which jobs finished
    for i in "${!exitfiles[@]}"; do
      if [ "${processed[$i]}" -eq 1 ]; then
        continue
      fi
      if [ -f "${exitfiles[$i]}" ]; then
        code=$(cat "${exitfiles[$i]}")
        name="${names[$i]}"
        log="$ROOT/tests/logs/$name.log"
        if [ "$code" -eq 0 ]; then
          echo "ok   $name"
          processed[$i]=1
          remaining=$((remaining-1))
        else
          echo "FAIL $name"
          tail -n 5 "$log"
          # kill remaining tests and mocks
          for j in "${!pids[@]}"; do
            if [ "${processed[$j]}" -eq 0 ]; then
              kill "${pids[$j]}" 2>/dev/null || true
            fi
          done
          for mp in "${mockpids[@]}"; do
            if [ -n "$mp" ]; then
              kill "$mp" 2>/dev/null || true
            fi
          done
          exit 1
        fi
      fi
    done
  done
}

wait_all

# yap_compact_test is timing-sensitive (a multi-turn stream with an 8s
# budget) and starves on the shared single-threaded mock when run in
# parallel, so run it alone after the batch.
run yap_compact_test 18132 mock_slow.py
wait_all

echo "all tests passed"
