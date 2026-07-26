$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$buildDirectory = Join-Path $root "build-windows-x86_64"
$binary = Join-Path $buildDirectory "src\pragtical.exe"
$agent = Join-Path $buildDirectory "src\workbench-agent.exe"
$dataRoot = Join-Path $root "data"

# The MSYS2 build is statically linked where possible, but the MinGW runtime
# and any remaining shared dependencies are installed in these directories.
$env:Path = "C:\msys64\mingw64\bin;C:\msys64\usr\bin;$env:Path"
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
  & $binary test $TestFile
  if ($LASTEXITCODE -ne 0) {
    throw "Workbench test failed: $TestFile (exit code $LASTEXITCODE)"
  }
}

function Start-WorkbenchAgent {
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$StateDirectory
  )

  New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null
  $endpoint = "workbench-ci-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-$Workspace"
  $stdout = Join-Path $StateDirectory "agent.stdout.log"
  $stderr = Join-Path $StateDirectory "agent.stderr.log"
  $arguments = @(
    "--data-root", $dataRoot,
    "--data-dir", $StateDirectory,
    "--endpoint", $endpoint,
    "--workspace", $Workspace
  )

  $process = Start-Process -FilePath $agent -ArgumentList $arguments `
    -WorkingDirectory $root -PassThru -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr

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
  }
}

function Stop-WorkbenchAgent {
  param([Parameter(Mandatory = $true)]$Instance)

  if (-not $Instance.Process.HasExited) {
    Stop-Process -Id $Instance.Process.Id -Force
    $Instance.Process.WaitForExit()
  }
}

function Invoke-AgentTest {
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$StateDirectory,
    [Parameter(Mandatory = $true)][string]$TestFile
  )

  $instance = Start-WorkbenchAgent $Workspace $StateDirectory
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

$workbenchTests = @(
  "data/plugins/workbench/tests/client.lua",
  "data/plugins/workbench/tests/persistence.lua",
  "data/plugins/workbench/tests/protocol.lua",
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
  Remove-Item -Recurse -Force $agentState
}
New-Item -ItemType Directory -Force -Path $agentState | Out-Null

try {
  Invoke-AgentTest "agent-test" $agentState "data/plugins/workbench/tests/agent.lua"
  Invoke-AgentTest "agent-test" $agentState "data/plugins/workbench/tests/agent_reconnect.lua"

  $terminalState = Join-Path $env:RUNNER_TEMP "pragtical-workbench-agent-terminal-$env:GITHUB_RUN_ID"
  if (Test-Path $terminalState) {
    Remove-Item -Recurse -Force $terminalState
  }
  New-Item -ItemType Directory -Force -Path $terminalState | Out-Null
  try {
    Invoke-AgentTest "agent-terminal-test" $terminalState `
      "data/plugins/workbench/tests/agent_terminal.lua"
  } finally {
    if (Test-Path $terminalState) {
      Remove-Item -Recurse -Force $terminalState
    }
  }
} finally {
  if (Test-Path $agentState) {
    Remove-Item -Recurse -Force $agentState
  }
}

Write-Host "Workbench Windows tests completed successfully."
