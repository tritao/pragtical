local core = require "core"
local config = require "core.config"

local stats_path = os.getenv("PRAGTICAL_PERF_STATS_PATH")
if not stats_path or stats_path == "" then
  error("PRAGTICAL_PERF_STATS_PATH is required")
end
local start_path = os.getenv("PRAGTICAL_PERF_START_PATH")

local warmup = tonumber(os.getenv("PRAGTICAL_PERF_WARMUP")) or 1
local duration = tonumber(os.getenv("PRAGTICAL_PERF_DURATION")) or 5
if warmup < 0 or duration <= 0 then
  error("invalid terminal redraw benchmark timing")
end

-- Keep the benchmark focused on the terminal view and avoid inherited state
-- from a developer's normal Pragtical session.
config.auto_fps = false
config.draw_stats = "uncapped"
config.fps = 1000
config.plugins.terminal.term = "xterm-256color"
config.plugins.terminal.shell = "/bin/sh"
config.plugins.terminal.arguments = { "-c", [[
python3 -c 'import sys,time
for batch in range(600):
    rows = []
    for row in range(40):
        n = batch * 40 + row
        fg = n % 256
        bg = (fg + 80) % 256
        rows.append(f"\033[38;5;{fg}m\033[48;5;{bg}mframe {n:07d} \u2588 \u03bb\u754c\033[0m\r\n")
    sys.stdout.write("".join(rows))
    sys.stdout.flush()
    time.sleep(0.01)'
]] }

local state = {
  started = false,
  finished = false,
  frames = 0,
  total_time = 0,
  max_time = 0,
  frame_times = {}
}

-- core.step() returns true only when it actually redraws. Measuring around it
-- includes the UI update and renderer submission for each redraw, while the
-- frame count excludes loop iterations that were intentionally skipped.
local core_step = core.step
core.step = function(...)
  local start = system.get_time()
  local redrawn = core_step(...)
  local elapsed = system.get_time() - start
  if state.started and not state.finished and redrawn then
    state.frames = state.frames + 1
    state.total_time = state.total_time + elapsed
    state.max_time = math.max(state.max_time, elapsed)
    state.frame_times[#state.frame_times + 1] = elapsed
  end
  return redrawn
end

local function wait_seconds(seconds)
  local deadline = system.get_time() + seconds
  while system.get_time() < deadline do coroutine.yield() end
end

local function wait_for_start_signal()
  if not start_path or start_path == "" then return end
  while not system.get_file_info(start_path) do coroutine.yield() end
end

local function write_stats(elapsed)
  local sorted = {}
  for i, value in ipairs(state.frame_times) do sorted[i] = value end
  table.sort(sorted)
  local p95 = sorted[math.max(1, math.ceil(#sorted * 0.95))] or 0
  local average = state.frames > 0 and state.total_time / state.frames or 0
  local fps = elapsed > 0 and state.frames / elapsed or 0
  local temporary_path = stats_path .. ".tmp"
  local fp, err = io.open(temporary_path, "w")
  if not fp then error(err) end
  fp:write(string.format(
    "frames=%d\nelapsed=%.3f\nfps=%.2f\navg_step_ms=%.3f\np95_step_ms=%.3f\nmax_step_ms=%.3f\n",
    state.frames, elapsed, fps, average * 1000, p95 * 1000, state.max_time * 1000
  ))
  fp:close()
  assert(os.rename(temporary_path, stats_path))
end

core.add_thread(function()
  wait_for_start_signal()
  wait_seconds(warmup)

  state.started = true
  local start = system.get_time()
  wait_seconds(duration)
  state.finished = true
  write_stats(system.get_time() - start)
  core.quit(true)
end)
