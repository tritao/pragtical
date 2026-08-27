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
agent_pid=""
copied_runtime=false

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
  local log_file="$data_dir/agent.log"

  mkdir -p -- "$data_dir"
  chmod 700 -- "$data_dir"
  rm -f -- "$endpoint"
  "$agent" \
    --data-root "$root_dir/data" \
    --data-dir "$data_dir" \
    --endpoint "$endpoint" \
    --workspace "$workspace" \
    >"$log_file" 2>&1 &
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

run_test() {
  local test_file="$1"
  local endpoint="${2:-}"
  local -a command=("$script_dir/run-local")

  if [[ "$copied_runtime" == true ]]; then
    command+=("-keep")
  fi
  command+=("$build_dir" "test" "$test_file")

  if [[ -n "$endpoint" ]]; then
    WORKBENCH_AGENT_ENDPOINT="$endpoint" \
      SDL_VIDEO_DRIVER=dummy "${command[@]}"
  else
    SDL_VIDEO_DRIVER=dummy "${command[@]}"
  fi
  copied_runtime=true
}

echo "Running Workbench in-process tests"
for test_file in \
  data/plugins/workbench/tests/client.lua \
  data/plugins/workbench/tests/persistence.lua \
  data/plugins/workbench/tests/protocol.lua \
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
run_test data/plugins/workbench/tests/agent.lua "$agent_endpoint"
stop_agent

start_agent "agent-test" "$agent_state" "$agent_endpoint"
run_test data/plugins/workbench/tests/agent_reconnect.lua "$agent_endpoint"
stop_agent

terminal_state="$state_root/agent-terminal"
terminal_endpoint="$terminal_state/workbench.sock"
echo "Running Workbench agent terminal tests"
start_agent "agent-terminal-test" "$terminal_state" "$terminal_endpoint"
run_test data/plugins/workbench/tests/agent_terminal.lua "$terminal_endpoint"
stop_agent

echo "Workbench tests completed successfully."
