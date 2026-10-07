#!/usr/bin/env bash
# yap test suite: Go unit tests, then headless-Neovim suites against
# local mock providers (Python stdlib) and an attached-UI fold test
# (Python msgpack). Run from anywhere:
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
# yap_fold_ui_test drives an attached Neovim over msgpack RPC, which the
# ambient python may lack, so pull an interpreter that has it from nix.
# `nix shell` is non-pure here, so the 0.13 nvim already on PATH stays
# available for `nvim --embed`.
nix shell --impure --expr '(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.python3.withPackages (ps: [ ps.msgpack ])' -c python3 tests/yap_fold_ui_test.py || exit 1

# Parallel test runner: start all Lua headless tests in background and fail fast
mkdir -p "$ROOT/tests/logs"

pids=()
names=()
mockpids=()
exitfiles=()
processed=()
declare -A mockmap

run() { # name port [mock] [dofile]
  local name="$1" port="$2" mock="${3:-}" mode="${4:-}"
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
  # Point XDG_CONFIG_HOME at the test dir so the spawned agent binary reads
  # the mock provider config written above instead of the user's real one.
  if [ "$mode" = "dofile" ]; then
    (
      XDG_CONFIG_HOME="$TEST_DIR/.config" XDG_CACHE_HOME="$TEST_DIR/.cache" HOME="$TEST_DIR" nvim --headless -u NONE --cmd "set rtp^=$ROOT" "+lua dofile('$ROOT/tests/$name.lua')" +qa >"$log" 2>&1
      echo $? > "$exitfile"
    ) &
  else
    (
      XDG_CONFIG_HOME="$TEST_DIR/.config" XDG_CACHE_HOME="$TEST_DIR/.cache" HOME="$TEST_DIR" nvim --headless -u NONE --cmd "set rtp^=$ROOT" -l "tests/$name.lua" >"$log" 2>&1
      echo $? > "$exitfile"
    ) &
  fi
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
run yap_session_usage_test 18132 mock_slow.py
run yap_scratch_send_test 18132 mock_slow.py
run yap_notify_test 18132 mock_slow.py
run yap_block_test 18132 mock_slow.py
run yap_toolparse_test 18133 mock_tool.py
run yap_close_session_test 18142 mock_close.py
run yap_close_session_picker_test 18142 mock_close.py dofile
run yap_e2e_livetool 18141 mock_stream.py
run yap_e2e_streamfold 18135 mock_write.py
run yap_audit_test 18135 mock_write.py
run yap_audit_view_test 18135 mock_write.py
run yap_audit_rename_test 18135 mock_write.py
run yap_approval_inspect_test 18162 mock_approval.py
run yap_follow_test 18152 mock_follow.py
run yap_picker_test 18137 mock_models.py
run yap_describe_test 18139 mock_describe.py
run yap_steer_test 18160 mock_steer.py
run yap_model_switch_test 18170 mock_model_switch.py
run yap_cwd_test 18132
run yap_git_test 18132
for t in yap_fold_contract_test yap_fold_test yap_detailfold_test yap_fold_peek_test yap_fold_za_test yap_fold_reconcile_test yap_fold_noflicker_test yap_fold_leak_test yap_think_test yap_error_test yap_ml_test \
         yap_streamfold_test yap_marker_test yap_model_test yap_model_cache_test yap_map_test yap_keymap_test yap_clear_test \
         yap_default_model_test yap_live_open_test yap_leave_session_test yap_uidiff_test yap_fencefold_test yap_fence_conformance_test yap_lsp_test \
         yap_template_test yap_frontmatter_test yap_adopt_test yap_alerts_test yap_textobj_test \
         yap_nav_test yap_scratch_test yap_session_preview_test yap_winbar_resize_test yap_winbar_ctx_test yap_winbar_steer_test yap_bd_test yap_open_test yap_help_test yap_fork_test yap_subagent_integration_test; do
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
# budget) and runs alone after the batch so its timing stays deterministic.
run yap_compact_test 18132 mock_slow.py
wait_all

echo "all tests passed"
