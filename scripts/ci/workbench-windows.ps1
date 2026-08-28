$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$buildDirectory = Join-Path $root "build-windows-x86_64"
$binary = Join-Path $buildDirectory "src\pragtical.exe"
$agent = Join-Path $buildDirectory "src\workbench-agent.exe"
$dataRoot = Join-Path $root "data"
$workbenchTestTimeoutMilliseconds = 120000
$agentLogDirectory = Join-Path $env:RUNNER_TEMP `
  "pragtical-workbench-agent-logs-$env:GITHUB_RUN_ID"
New-Item -ItemType Directory -Force -Path $agentLogDirectory | Out-Null

# The MSYS2 build is statically linked where possible, but the MinGW runtime
# and any remaining shared dependencies are installed in the MSYS2 tree. The
# setup-msys2 action provides the actual installation path because hosted
# runners do not use a stable location.
$msys2Root = $env:MSYS2_LOCATION
if (-not $msys2Root) {
  throw "MSYS2_LOCATION was not provided by the setup-msys2 action"
}
if (-not (Test-Path (Join-Path $msys2Root "mingw64\bin"))) {
  throw "MSYS2 installation was not found: $msys2Root"
}

$runtimeDirectories = @(
  (Join-Path $buildDirectory "subprojects\terminal"),
  (Join-Path $msys2Root "mingw64\bin"),
  (Join-Path $msys2Root "usr\bin")
) | Where-Object { Test-Path $_ }
$env:Path = "$($runtimeDirectories -join ';');$env:Path"
Write-Host "Using MSYS2 runtime: $msys2Root"
$env:SDL_VIDEODRIVER = "dummy"
$env:SDL_VIDEO_DRIVER = "dummy"

if (-not (Test-Path $binary)) {
  throw "Pragtical binary was not built: $binary"
}
if (-not (Test-Path $agent)) {
  throw "Workbench agent binary was not built: $agent"
}

function Invoke-WorkbenchTest {
  param([Parameter(Mandatory = $true)][string]$TestFile)

  Write-Host "Running Workbench test: $TestFile"
  $process = Start-Process -FilePath $binary -ArgumentList @("test", $TestFile) `
    -WorkingDirectory $root -PassThru -NoNewWindow
  if (-not $process.WaitForExit($workbenchTestTimeoutMilliseconds)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit()
    throw "Workbench test timed out after $($workbenchTestTimeoutMilliseconds / 1000)s: $TestFile"
  }
  if ($process.ExitCode -ne 0) {
    throw "Workbench test failed: $TestFile (exit code $($process.ExitCode))"
  }
}

function Start-WorkbenchAgent {
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$StateDirectory,
    [string]$FaultBoundary = ""
  )

  New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null
  $endpoint = "workbench-ci-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-$Workspace"
  $logName = Split-Path $StateDirectory -Leaf
  $stdout = Join-Path $agentLogDirectory "$logName.stdout.log"
  $stderr = Join-Path $agentLogDirectory "$logName.stderr.log"
  $arguments = @(
    "--data-root", $dataRoot,
    "--data-dir", $StateDirectory,
    "--endpoint", $endpoint,
    "--workspace", $Workspace
  )

  $previousFaultBoundary = [Environment]::GetEnvironmentVariable(
    "WORKBENCH_AGENT_FAULT_BOUNDARY", "Process")
  try {
    [Environment]::SetEnvironmentVariable("WORKBENCH_AGENT_FAULT_BOUNDARY",
      $(if ($FaultBoundary) { $FaultBoundary } else { $null }), "Process")
    $process = Start-Process -FilePath $agent -ArgumentList $arguments `
      -WorkingDirectory $root -PassThru -RedirectStandardOutput $stdout `
      -RedirectStandardError $stderr
  } finally {
    [Environment]::SetEnvironmentVariable("WORKBENCH_AGENT_FAULT_BOUNDARY",
      $previousFaultBoundary, "Process")
  }

  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if ($process.HasExited) {
      $log = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { "" }
      throw "Workbench agent exited during startup: $log"
    }
    Start-Sleep -Milliseconds 100
  }

  return [PSCustomObject]@{
    Process = $process
    Endpoint = $endpoint
    StateDirectory = $StateDirectory
  }
}

function Get-WorkbenchAgentProcessIds {
  param([Parameter(Mandatory = $true)][string]$StateDirectory)

  $normalizedStateDirectory = [System.IO.Path]::GetFullPath($StateDirectory).TrimEnd('\')
  return @(Get-CimInstance Win32_Process -Filter "Name = 'workbench-agent.exe'" |
    Where-Object {
      $_.CommandLine -and
        $_.CommandLine.IndexOf($normalizedStateDirectory,
          [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    } |
    Select-Object -ExpandProperty ProcessId)
}

function Stop-WorkbenchAgent {
  param([Parameter(Mandatory = $true)]$Instance)

  $process = $Instance.Process
  $process.Refresh()
  if (-not $process.HasExited) {
    # MinGW processes can leave descendants holding redirected stdio handles;
    # terminate the complete tree before removing its state directory.
    & taskkill.exe /PID $process.Id /T /F | Out-Null
    if (-not $process.WaitForExit(10000)) {
      throw "Workbench agent did not exit after termination"
    }
  }

  # If the parent has already exited, taskkill /T cannot reach a descendant
  # that outlived it. Find any agent still carrying this exact data directory
  # and terminate it before the directory is reused or removed.
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    $remaining = @(Get-WorkbenchAgentProcessIds $Instance.StateDirectory)
    if ($remaining.Count -eq 0) { return }
    foreach ($processId in $remaining) {
      & taskkill.exe /PID $processId /T /F | Out-Null
    }
    Start-Sleep -Milliseconds 100
  }
  throw "Workbench agent process still owns its state directory: $($Instance.StateDirectory)"
}

function Remove-WorkbenchState {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) { return }
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      Remove-Item -Recurse -Force -Path $Path -ErrorAction Stop
      return
    } catch {
      if ($attempt -eq 19) { throw }
      Start-Sleep -Milliseconds 250
    }
  }
}

function Test-WorkbenchAgentLock {
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$StateDirectory
  )

  Write-Host "Running Workbench agent ownership-lock test"
  $primary = Start-WorkbenchAgent $Workspace $StateDirectory
  $secondaryEndpoint = "workbench-ci-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-$Workspace-secondary"
  $logName = "$(Split-Path $StateDirectory -Leaf)-secondary"
  $secondaryStdout = Join-Path $agentLogDirectory "$logName.stdout.log"
  $secondaryStderr = Join-Path $agentLogDirectory "$logName.stderr.log"
  $arguments = @(
    "--data-root", $dataRoot,
    "--data-dir", $StateDirectory,
    "--endpoint", $secondaryEndpoint,
    "--workspace", "$Workspace-secondary"
  )
  try {
    $secondary = Start-Process -FilePath $agent -ArgumentList $arguments `
      -WorkingDirectory $root -PassThru -RedirectStandardOutput $secondaryStdout `
      -RedirectStandardError $secondaryStderr
    if (-not $secondary.WaitForExit(10000)) {
      & taskkill.exe /PID $secondary.Id /T /F | Out-Null
      if (-not $secondary.WaitForExit(10000)) {
        throw "Second Workbench agent did not exit after termination"
      }
    }
    $log = if (Test-Path $secondaryStderr) { Get-Content $secondaryStderr -Raw } else { "" }
    if ($secondary.ExitCode -ne 3 -or -not $log.Contains("workspace_in_use:")) {
      throw "Second Workbench agent was not rejected by the ownership lock: $log"
    }
    if ($primary.Process.HasExited) {
      throw "Primary Workbench agent exited while the second agent was rejected"
    }
  } finally {
    Stop-WorkbenchAgent $primary
  }
}

function Test-FragmentedWorkbenchTransport {
  param(
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $true)][string]$Workspace
  )

  # The native transport hashes non-prefixed endpoint names with FNV-1a.
  [uint32]$hash = 2166136261
  foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes($Endpoint)) {
    $hash = [uint32]($hash -bxor [uint32]$byte)
    $hash = [uint32]($hash * 16777619)
  }
  $pipeName = "\\.\pipe\pragtical-workbench-{0:x8}" -f $hash
  $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
    ".", $pipeName.Substring(9),
    [System.IO.Pipes.PipeDirection]::InOut,
    [System.IO.Pipes.PipeOptions]::None)
  try {
    $pipe.Connect(5000)
    $payload = [System.Collections.Generic.List[byte]]::new()
    $addString = {
      param([string]$Value)
      $encoded = [System.Text.Encoding]::UTF8.GetBytes($Value)
      if ($encoded.Length -ge 32) { throw "fragmentation test string is too long" }
      $payload.Add([byte](0xa0 -bor $encoded.Length))
      foreach ($item in $encoded) { $payload.Add($item) }
    }
    $payload.Add([byte]0x84)
    & $addString "protocol"
    $payload.Add([byte]2)
    & $addString "kind"
    & $addString "hello"
    & $addString "request_id"
    & $addString "fragment-test"
    & $addString "workspace_id"
    & $addString $Workspace

    $length = [BitConverter]::GetBytes([uint32]$payload.Count)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($length) }
    $frame = [byte[]]($length + $payload.ToArray())
    foreach ($item in $frame) {
      $pipe.WriteByte($item)
      $pipe.Flush()
      Start-Sleep -Milliseconds 1
    }

    $header = New-Object byte[] 4
    $read = 0
    while ($read -lt $header.Length) {
      $count = $pipe.Read($header, $read, $header.Length - $read)
      if ($count -le 0) { throw "agent closed the transport while replying" }
      $read += $count
    }
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($header) }
    $responseLength = [BitConverter]::ToUInt32($header, 0)
    if ($responseLength -gt 16MB) { throw "agent returned an oversized response frame" }
    $response = New-Object byte[] $responseLength
    $read = 0
    while ($read -lt $response.Length) {
      $count = $pipe.Read($response, $read, $response.Length - $read)
      if ($count -le 0) { throw "agent closed the transport while replying" }
      $read += $count
    }
    $text = [System.Text.Encoding]::UTF8.GetString($response)
    if (-not $text.Contains("hello_result")) {
      throw "fragmented hello did not receive hello_result"
    }
  } finally {
    $pipe.Dispose()
  }
}

function Invoke-AgentTest {
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$StateDirectory,
    [Parameter(Mandatory = $true)][string]$TestFile
  )

  $instance = Start-WorkbenchAgent $Workspace $StateDirectory
  Test-FragmentedWorkbenchTransport $instance.Endpoint $Workspace
  $previousEndpoint = $env:WORKBENCH_AGENT_ENDPOINT
  $env:WORKBENCH_AGENT_ENDPOINT = $instance.Endpoint
  try {
    Invoke-WorkbenchTest $TestFile
  } finally {
    if ($null -eq $previousEndpoint) {
      Remove-Item Env:WORKBENCH_AGENT_ENDPOINT -ErrorAction SilentlyContinue
    } else {
      $env:WORKBENCH_AGENT_ENDPOINT = $previousEndpoint
    }
    Stop-WorkbenchAgent $instance
  }
}

function Invoke-WorkbenchFaultTest {
  param(
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $true)][string]$Phase,
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][string]$Boundary,
    [Parameter(Mandatory = $true)][string]$RuntimeId,
    [Parameter(Mandatory = $true)][string]$OperationId
  )

  $values = @{
    WORKBENCH_AGENT_ENDPOINT = $Endpoint
    WORKBENCH_FAULT_PHASE = $Phase
    WORKBENCH_FAULT_ACTION = $Action
    WORKBENCH_FAULT_BOUNDARY = $Boundary
    WORKBENCH_FAULT_RUNTIME_ID = $RuntimeId
    WORKBENCH_FAULT_OPERATION_ID = $OperationId
  }
  $previous = @{}
  try {
    foreach ($name in $values.Keys) {
      $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
      [Environment]::SetEnvironmentVariable($name, $values[$name], "Process")
    }
    Invoke-WorkbenchTest "data/plugins/workbench/tests/agent_fault.lua"
  } finally {
    foreach ($name in $values.Keys) {
      [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process")
    }
  }
}

function Invoke-AgentFaultCase {
  param(
    [Parameter(Mandatory = $true)][string]$Boundary,
    [Parameter(Mandatory = $true)][string]$Action
  )

  $caseName = "${Boundary}_${Action}"
  $stateDirectory = Join-Path $env:RUNNER_TEMP `
    "pragtical-workbench-fault-$env:GITHUB_RUN_ID-$caseName"
  if (Test-Path $stateDirectory) {
    Remove-WorkbenchState $stateDirectory
  }
  New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
  $runtimeId = "fault-$caseName"
  $operationId = "fault-$Action-$runtimeId"
  try {
    Write-Host "Running Workbench fault boundary: $Boundary"
    $instance = Start-WorkbenchAgent "agent-fault-test" $stateDirectory $Boundary
    try {
      Invoke-WorkbenchFaultTest $instance.Endpoint "trigger" $Action $Boundary `
        $runtimeId $operationId
    } finally {
      Stop-WorkbenchAgent $instance
    }

    $instance = Start-WorkbenchAgent "agent-fault-test" $stateDirectory
    try {
      Invoke-WorkbenchFaultTest $instance.Endpoint "recover" $Action $Boundary `
        $runtimeId $operationId
    } finally {
      Stop-WorkbenchAgent $instance
    }
  } finally {
    if (Test-Path $stateDirectory) {
      Remove-WorkbenchState $stateDirectory
    }
  }
}

$workbenchTests = @(
  "data/plugins/workbench/tests/client.lua",
  "data/plugins/workbench/tests/persistence.lua",
  "data/plugins/workbench/tests/protocol.lua",
  "data/plugins/workbench/tests/provider.lua",
  "data/plugins/workbench/tests/provider_recovery.lua",
  "data/plugins/workbench/tests/sakura_import.lua",
  "data/plugins/workbench/tests/service.lua",
  "data/plugins/workbench/tests/terminal.lua",
  "data/plugins/workbench/tests/ui.lua"
)

foreach ($testFile in $workbenchTests) {
  Invoke-WorkbenchTest $testFile
}

$agentState = Join-Path $env:RUNNER_TEMP "pragtical-workbench-agent-$env:GITHUB_RUN_ID"
if (Test-Path $agentState) {
  Remove-WorkbenchState $agentState
}
New-Item -ItemType Directory -Force -Path $agentState | Out-Null

  try {
    Invoke-AgentTest "agent-test" $agentState "data/plugins/workbench/tests/agent.lua"

    $lockState = Join-Path $env:RUNNER_TEMP "pragtical-workbench-agent-lock-$env:GITHUB_RUN_ID"
    if (Test-Path $lockState) {
      Remove-WorkbenchState $lockState
    }
    New-Item -ItemType Directory -Force -Path $lockState | Out-Null
    try {
      Test-WorkbenchAgentLock "agent-lock-test" $lockState
    } finally {
      if (Test-Path $lockState) {
        Remove-WorkbenchState $lockState
      }
    }

    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -ne $codexCommand) {
      $providerState = Join-Path $env:RUNNER_TEMP `
        "pragtical-workbench-agent-provider-$env:GITHUB_RUN_ID"
      if (Test-Path $providerState) {
        Remove-WorkbenchState $providerState
      }
      New-Item -ItemType Directory -Force -Path $providerState | Out-Null
      $previousCodexExecutable = $env:WORKBENCH_CODEX_EXECUTABLE
      try {
        $env:WORKBENCH_CODEX_EXECUTABLE = $codexCommand.Source
        Invoke-AgentTest "agent-codex-test" $providerState `
          "data/plugins/workbench/tests/agent_provider.lua"
      } finally {
        if ($null -eq $previousCodexExecutable) {
          Remove-Item Env:WORKBENCH_CODEX_EXECUTABLE -ErrorAction SilentlyContinue
        } else {
          $env:WORKBENCH_CODEX_EXECUTABLE = $previousCodexExecutable
        }
        if (Test-Path $providerState) {
          Remove-WorkbenchState $providerState
        }
      }
    } else {
      Write-Host "Skipping live Codex provider test: codex executable was not found"
    }

    Invoke-AgentTest "agent-test" $agentState "data/plugins/workbench/tests/agent_reconnect.lua"

  $terminalState = Join-Path $env:RUNNER_TEMP "pragtical-workbench-agent-terminal-$env:GITHUB_RUN_ID"
  if (Test-Path $terminalState) {
    Remove-WorkbenchState $terminalState
  }
  New-Item -ItemType Directory -Force -Path $terminalState | Out-Null
  try {
    Invoke-AgentTest "agent-terminal-test" $terminalState `
      "data/plugins/workbench/tests/agent_terminal.lua"
  } finally {
    if (Test-Path $terminalState) {
      Remove-WorkbenchState $terminalState
    }
  }

  $stressState = Join-Path $env:RUNNER_TEMP "pragtical-workbench-agent-stress-$env:GITHUB_RUN_ID"
  if (Test-Path $stressState) {
    Remove-WorkbenchState $stressState
  }
  New-Item -ItemType Directory -Force -Path $stressState | Out-Null
  try {
    Invoke-AgentTest "agent-stress-test" $stressState `
      "data/plugins/workbench/tests/agent_stress.lua"
  } finally {
    if (Test-Path $stressState) {
      Remove-WorkbenchState $stressState
    }
  }

  Invoke-AgentFaultCase "after_starting_commit" "start"
  Invoke-AgentFaultCase "after_process_creation" "start"
  Invoke-AgentFaultCase "before_running_commit" "start"
  Invoke-AgentFaultCase "after_stopping_commit" "stop"
  Invoke-AgentFaultCase "during_close" "stop"
  Invoke-AgentFaultCase "before_stopped_commit" "stop"
  Invoke-AgentFaultCase "after_running_commit" "start"
  Invoke-AgentFaultCase "after_stopped_commit" "stop"
} finally {
  if (Test-Path $agentState) {
    Remove-WorkbenchState $agentState
  }
}

Write-Host "Workbench Windows tests completed successfully."
