#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd -- "$script_dir/.." && pwd)"
build_dir="${1:-build}"

if [[ "$build_dir" != /* ]]; then
  build_dir="$root_dir/$build_dir"
fi

binary="$build_dir/src/pragtical"
agent="$build_dir/src/workbench-agent"

if [[ ! -x "$binary" ]]; then
  echo "Pragtical binary was not found: $binary" >&2
  echo "Build Pragtical first, or pass the build directory as the first argument." >&2
  exit 1
fi
if [[ ! -x "$agent" ]]; then
  echo "Workbench agent binary was not found: $agent" >&2
  echo "Build with the Workbench agent target enabled." >&2
  exit 1
fi

state_root="$(mktemp -d "${TMPDIR:-/tmp}/pragtical-workbench-test.XXXXXX")"
test_run_dir="$state_root/local-run"
test_user_dir="$state_root/user"
test_runtime_dir="$state_root/xdg-runtime"
agent_pid=""
copied_runtime=false

mkdir -p -- "$test_user_dir" "$test_runtime_dir"
chmod 700 -- "$test_user_dir" "$test_runtime_dir"
cat >"$test_user_dir/init.lua" <<'LUA'
local config = require "core.config"
config.plugins.workbench = { startup = "never" }
LUA

cleanup() {
  if [[ -n "$agent_pid" ]]; then
    if kill -0 "$agent_pid" 2>/dev/null; then
      kill "$agent_pid" 2>/dev/null || true
      wait "$agent_pid" 2>/dev/null || true
    fi
    agent_pid=""
  fi
  rm -rf -- "$state_root"
}
trap cleanup EXIT INT TERM

start_agent() {
  local workspace="$1"
  local data_dir="$2"
  local endpoint="$3"
  local fault_boundary="${4:-}"
  local log_file="$data_dir/agent.log"

  mkdir -p -- "$data_dir"
  chmod 700 -- "$data_dir"
  rm -f -- "$endpoint"
  local -a command=(
    "$agent"
    --data-root "$root_dir/data"
    --data-dir "$data_dir"
    --endpoint "$endpoint"
    --workspace "$workspace"
  )
  if [[ -n "$fault_boundary" ]]; then
    WORKBENCH_AGENT_FAULT_BOUNDARY="$fault_boundary" \
      "${command[@]}" >"$log_file" 2>&1 &
  else
    "${command[@]}" >"$log_file" 2>&1 &
  fi
  agent_pid=$!

  for _ in $(seq 1 100); do
    if ! kill -0 "$agent_pid" 2>/dev/null; then
      echo "Workbench agent exited during startup:" >&2
      sed -n '1,160p' "$log_file" >&2 || true
      return 1
    fi
    if [[ -e "$endpoint" ]]; then return 0; fi
    sleep 0.1
  done

  echo "Timed out waiting for Workbench agent endpoint: $endpoint" >&2
  sed -n '1,160p' "$log_file" >&2 || true
  return 1
}

stop_agent() {
  if [[ -z "$agent_pid" ]]; then return 0; fi
  if kill -0 "$agent_pid" 2>/dev/null; then
    kill "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
  fi
  agent_pid=""
}

run_agent_lock_test() {
  local lock_state="$state_root/agent-lock"
  local primary_endpoint="$lock_state/primary.sock"
  local secondary_endpoint="$lock_state/secondary.sock"
  local secondary_log="$lock_state/secondary.log"
  local secondary_pid
  local secondary_status

  echo "Running Workbench agent ownership-lock test"
  start_agent "agent-lock-test" "$lock_state" "$primary_endpoint"
  "$agent" \
    --data-root "$root_dir/data" \
    --data-dir "$lock_state" \
    --endpoint "$secondary_endpoint" \
    --workspace "agent-lock-test" >"$secondary_log" 2>&1 &
  secondary_pid=$!
  if wait "$secondary_pid"; then
    secondary_status=0
  else
    secondary_status=$?
  fi
  if [[ "$secondary_status" -ne 3 ]] \
      || ! grep -q '^workspace_in_use:' "$secondary_log"; then
    echo "Second Workbench agent was not rejected by the ownership lock:" >&2
    sed -n '1,160p' "$secondary_log" >&2 || true
    stop_agent
    return 1
  fi
  if ! kill -0 "$agent_pid" 2>/dev/null; then
    echo "Primary Workbench agent exited while the second agent was rejected" >&2
    stop_agent
    return 1
  fi
  stop_agent
}

run_test() {
  local test_file="$1"
  local endpoint="${2:-}"
  local -a command=("$script_dir/run-local")

  if [[ "$copied_runtime" == true ]]; then
    command+=("-keep")
  fi
  command+=("$build_dir" "test" "$test_file")

  if [[ -n "$endpoint" ]]; then
    PRAGTICAL_RUN_DIR="$test_run_dir" \
      PRAGTICAL_USERDIR="$test_user_dir" \
      XDG_RUNTIME_DIR="$test_runtime_dir" \
    WORKBENCH_AGENT_ENDPOINT="$endpoint" \
      SDL_VIDEO_DRIVER=dummy "${command[@]}"
  else
    PRAGTICAL_RUN_DIR="$test_run_dir" \
      PRAGTICAL_USERDIR="$test_user_dir" \
      XDG_RUNTIME_DIR="$test_runtime_dir" \
    SDL_VIDEO_DRIVER=dummy "${command[@]}"
  fi
  copied_runtime=true
}

run_agent_provider_test() {
  local endpoint="$1"
  local executable="$2"
  local -a command=("$script_dir/run-local")

  if [[ "$copied_runtime" == true ]]; then
    command+=("-keep")
  fi
  command+=("$build_dir" "test" "data/plugins/workbench/tests/agent_provider.lua")
  PRAGTICAL_RUN_DIR="$test_run_dir" \
    PRAGTICAL_USERDIR="$test_user_dir" \
    XDG_RUNTIME_DIR="$test_runtime_dir" \
  WORKBENCH_AGENT_ENDPOINT="$endpoint" \
    WORKBENCH_CODEX_EXECUTABLE="$executable" \
    SDL_VIDEO_DRIVER=dummy "${command[@]}"
  copied_runtime=true
}

run_fault_test() {
  local endpoint="$1"
  local phase="$2"
  local action="$3"
  local runtime_id="$4"
  local operation_id="$5"
  local boundary="$6"
  local -a command=("$script_dir/run-local")

  if [[ "$copied_runtime" == true ]]; then
    command+=("-keep")
  fi
  command+=("$build_dir" "test" "data/plugins/workbench/tests/agent_fault.lua")
  PRAGTICAL_RUN_DIR="$test_run_dir" \
    PRAGTICAL_USERDIR="$test_user_dir" \
    XDG_RUNTIME_DIR="$test_runtime_dir" \
  WORKBENCH_AGENT_ENDPOINT="$endpoint" \
    WORKBENCH_FAULT_PHASE="$phase" \
    WORKBENCH_FAULT_ACTION="$action" \
    WORKBENCH_FAULT_BOUNDARY="$boundary" \
    WORKBENCH_FAULT_RUNTIME_ID="$runtime_id" \
    WORKBENCH_FAULT_OPERATION_ID="$operation_id" \
    SDL_VIDEO_DRIVER=dummy "${command[@]}"
  copied_runtime=true
}

run_fault_case() {
  local boundary="$1"
  local action="$2"
  local case_name="${boundary}_${action}"
  local fault_state="$state_root/fault-$case_name"
  local fault_endpoint="$fault_state/workbench.sock"
  local runtime_id="fault-$case_name"
  local operation_id="fault-$action-$runtime_id"

  echo "Running Workbench fault boundary: $boundary"
  start_agent "agent-fault-test" "$fault_state" "$fault_endpoint" "$boundary"
  run_fault_test "$fault_endpoint" trigger "$action" "$runtime_id" "$operation_id" "$boundary"
  stop_agent

  start_agent "agent-fault-test" "$fault_state" "$fault_endpoint"
  run_fault_test "$fault_endpoint" recover "$action" "$runtime_id" "$operation_id" "$boundary"
  stop_agent
}

echo "Running Workbench in-process tests"
for test_file in \
  data/plugins/workbench/tests/client.lua \
  data/plugins/workbench/tests/persistence.lua \
  data/plugins/workbench/tests/protocol.lua \
  data/plugins/workbench/tests/http_protocol.lua \
  data/plugins/workbench/tests/provider.lua \
  data/plugins/workbench/tests/provider_recovery.lua \
  data/plugins/workbench/tests/sakura_import.lua \
  data/plugins/workbench/tests/service.lua \
  data/plugins/workbench/tests/terminal.lua \
  data/plugins/workbench/tests/ui.lua; do
  run_test "$test_file"
done

agent_state="$state_root/agent"
agent_endpoint="$agent_state/workbench.sock"
echo "Running Workbench agent persistence tests"
start_agent "agent-test" "$agent_state" "$agent_endpoint"
echo "Running fragmented Unix Workbench transport test"
python3 "$script_dir/test-workbench-transport.py" "$agent_endpoint" "agent-test"
run_test data/plugins/workbench/tests/agent.lua "$agent_endpoint"
stop_agent

run_agent_lock_test

codex_executable="$(type -P codex || true)"
if [[ -n "$codex_executable" ]]; then
  provider_state="$state_root/agent-provider"
  provider_endpoint="$provider_state/workbench.sock"
  echo "Running Workbench live Codex provider test"
  start_agent "agent-codex-test" "$provider_state" "$provider_endpoint"
  run_agent_provider_test "$provider_endpoint" "$codex_executable"
  stop_agent
else
  echo "Skipping live Codex provider test: codex executable was not found"
fi

start_agent "agent-test" "$agent_state" "$agent_endpoint"
run_test data/plugins/workbench/tests/agent_reconnect.lua "$agent_endpoint"
stop_agent

terminal_state="$state_root/agent-terminal"
terminal_endpoint="$terminal_state/workbench.sock"
echo "Running Workbench agent terminal tests"
start_agent "agent-terminal-test" "$terminal_state" "$terminal_endpoint"
run_test data/plugins/workbench/tests/agent_terminal.lua "$terminal_endpoint"
stop_agent

stress_state="$state_root/agent-stress"
stress_endpoint="$stress_state/workbench.sock"
echo "Running Workbench agent stress tests"
start_agent "agent-stress-test" "$stress_state" "$stress_endpoint"
run_test data/plugins/workbench/tests/agent_stress.lua "$stress_endpoint"
stop_agent

echo "Running Workbench runtime lifecycle fault tests"
run_fault_case after_starting_commit start
run_fault_case after_process_creation start
run_fault_case before_running_commit start
run_fault_case after_stopping_commit stop
run_fault_case during_close stop
run_fault_case before_stopped_commit stop
run_fault_case after_running_commit start
run_fault_case after_stopped_commit stop

echo "Workbench tests completed successfully."
