param(
  [switch]$NoService
)

$ErrorActionPreference = "Stop"

$BaseUrl = $env:GAIN_AGENT_BASE_URL
if (-not $BaseUrl) { $BaseUrl = "https://www.cyberwardion.com/downloads/gain-agent" }
$BaseUrl = $BaseUrl.TrimEnd([char[]]@("/"))

$OrgKey = $env:GAIN_ORG_API_KEY
$Mode = $env:GAIN_ENFORCEMENT_MODE
if (-not $Mode) { $Mode = "visibility_only" }
$DeploymentMode = $env:GAIN_DEPLOYMENT_MODE
$SupabaseUrl = $env:GAIN_SUPABASE_URL
$SupabaseKey = $env:GAIN_SUPABASE_KEY
$Label = $env:GAIN_DEVICE_LABEL
if (-not $Label) { $Label = "Developer workstation" }
$Department = $env:GAIN_DEPARTMENT
$SkipService = $NoService -or $env:GAIN_AGENT_NO_SERVICE -eq "1" -or $env:GAIN_AGENT_NO_SERVICE -eq "true"
$SkipAutoWire = $env:GAIN_AGENT_SKIP_INTEGRATIONS -eq "1" -or $env:GAIN_AGENT_NO_AUTOWIRE -eq "1" -or $env:GAIN_AGENT_NO_AUTOWIRE -eq "true"
$SkipUserPath = $env:GAIN_AGENT_SKIP_USER_PATH -eq "1"
$ProxyFailPolicy = if ($env:GAIN_PROXY_FAIL_POLICY -eq "fail_closed") { "fail_closed" } else { "fail_open" }
$EnableAutoUpdate = $env:GAIN_AGENT_AUTO_UPDATE -eq "true" -or $env:GAIN_AGENT_AUTO_UPDATE -eq "1"
$GainConfigDir = if ($env:GAIN_CONFIG_DIR) { $env:GAIN_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".gain" }
$GainConfigPath = Join-Path $GainConfigDir "config.json"
$ExistingConfigBackup = $null
$ExistingEnrollment = $null
if (Test-Path -LiteralPath $GainConfigPath) {
  try {
    $ExistingEnrollment = Get-Content -LiteralPath $GainConfigPath -Raw | ConvertFrom-Json
    if ($ExistingEnrollment.org_api_key) {
      $ExistingConfigBackup = Join-Path $env:TEMP "gain-agent-existing-config-$PID.json"
      Copy-Item -LiteralPath $GainConfigPath -Destination $ExistingConfigBackup -Force
    }
  } catch {
    Write-Host "Existing G.A.I.N configuration could not be read; continuing with a new setup."
  }
}

function Resolve-GainUrl([string]$UrlOrPath) {
  if ($UrlOrPath -match "^https?://") { return $UrlOrPath }
  return "$BaseUrl/$($UrlOrPath.TrimStart([char[]]@('/')))"
}

function Get-LatestManifest {
  try {
    return Invoke-RestMethod -Uri "$BaseUrl/latest.json" -UseBasicParsing
  } catch {
    Write-Host "Could not load latest.json. Falling back to npm package install."
    return $null
  }
}

function Get-PlatformKey {
  $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  if ($arch -eq "x64") { return "win-x64" }
  if ($arch -eq "arm64") { return "win-arm64" }
  return "win-$arch"
}

function Add-ToUserPath([string]$Dir) {
  if ($SkipUserPath) {
    $env:Path = "$Dir;$env:Path"
    Write-Host "Skipped persistent user PATH update because GAIN_AGENT_SKIP_USER_PATH=1 was set."
    return
  }
  $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @()
  if ($currentUserPath) { $parts = $currentUserPath -split ";" | Where-Object { $_ } }
  if ($parts -notcontains $Dir) {
    $nextPath = (($parts + $Dir) -join ";")
    [Environment]::SetEnvironmentVariable("Path", $nextPath, "User")
    Write-Host "Added $Dir to your user PATH. Open a new terminal to use gain-agent globally."
  }
  if (($env:Path -split ";") -notcontains $Dir) {
    $env:Path = "$Dir;$env:Path"
  }
}

function Stop-ExistingGainProcesses([string]$AgentPath) {
  if (-not (Test-Path -LiteralPath $AgentPath)) { return }

  # A running proxy, health worker, or desktop guard holds gain-agent.exe open on Windows.
  # Do not call the old binary's uninstall command here: older agents can mutate
  # config.json during cleanup. Clear only persistent loopback routes, then stop
  # processes from this exact install location.
  foreach ($name in @("ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "OPENAI_API_BASE", "COPILOT_PROVIDER_BASE_URL")) {
    try { & reg delete "HKCU\Environment" /V $name /F 2>$null | Out-Null } catch {}
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
  }

  $targetPath = [System.IO.Path]::GetFullPath($AgentPath)
  for ($attempt = 1; $attempt -le 20; $attempt++) {
    $running = @(Get-Process -Name "gain-agent" -ErrorAction SilentlyContinue | Where-Object {
      $_.Path -and ([System.IO.Path]::GetFullPath($_.Path) -ieq $targetPath)
    })
    if (-not $running.Count) { return }
    foreach ($process in $running) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Milliseconds 500
  }

  throw "G.A.I.N Agent is still running and Windows cannot replace it. Close any G.A.I.N Agent processes, then rerun this installer."
}

function Replace-AgentBinary([string]$TempPath, [string]$AgentPath) {
  Stop-ExistingGainProcesses $AgentPath
  $lastError = $null
  for ($attempt = 1; $attempt -le 20; $attempt++) {
    try {
      Move-Item -LiteralPath $TempPath -Destination $AgentPath -Force
      return
    } catch {
      $lastError = $_.Exception.Message
      Start-Sleep -Milliseconds 500
    }
  }
  throw "Windows could not replace the running G.A.I.N Agent binary. Fix: close any G.A.I.N Agent processes and rerun this installer. Last error: $lastError"
}

function Install-ProxyService([string]$AgentPath) {
  if ($SkipService) {
    Write-Host "Skipped hidden proxy service install because --no-service or GAIN_AGENT_NO_SERVICE was set."
    return
  }
  $ProxyHost = if ($env:GAIN_PROXY_HOST) { $env:GAIN_PROXY_HOST } else { "127.0.0.1" }
  $ProxyPort = if ($env:GAIN_PROXY_PORT) { $env:GAIN_PROXY_PORT } else { "8787" }
  try {
    & $AgentPath proxy --service install --host $ProxyHost --port $ProxyPort --proxy-fail-policy $ProxyFailPolicy
  } catch {
    Write-Host "Proxy service install warning: $($_.Exception.Message)"
    Write-Host "The agent remains connected and your AI tools keep their direct connection. Run 'gain-agent proxy --service install' later if you need it."
  }
}

function Test-GainProxyIdentity {
  try {
    $ProxyHost = if ($env:GAIN_PROXY_HOST) { $env:GAIN_PROXY_HOST } else { "127.0.0.1" }
    $ProxyPort = if ($env:GAIN_PROXY_PORT) { [int]$env:GAIN_PROXY_PORT } else { 8787 }
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://${ProxyHost}:$ProxyPort/_gain/health"
    $payload = $response.Content | ConvertFrom-Json
    return $response.StatusCode -eq 200 -and $payload.ok -eq $true -and $payload.service -eq "gain-agent-proxy"
  } catch {
    return $false
  }
}

function Invoke-AgentCommand([string]$AgentPath, [string[]]$Arguments, [string]$Description, [string]$Fix) {
  & $AgentPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE. Fix: $Fix"
  }
}

function Invoke-AutoWire([string]$AgentPath) {
  if ($SkipAutoWire) {
    Write-Host "Skipped coding-tool auto-wiring because GAIN_AGENT_SKIP_INTEGRATIONS or GAIN_AGENT_NO_AUTOWIRE was set."
    Write-Host "Wire tools later with: gain-agent integrations --apply"
    return
  }
  $proxyUp = $ProxyFailPolicy -eq "fail_closed" -and (-not $SkipService) -and (Test-GainProxyIdentity)
  try {
    if ($proxyUp) {
      Write-Host "Auto-wiring detected coding tools (local proxy is running)..."
      Invoke-AgentCommand -AgentPath $AgentPath -Arguments @("integrations", "--apply") -Description "Coding-tool auto-wiring" -Fix "Run gain-agent integrations --apply after resolving the message above."
    } else {
      Write-Host "Auto-wiring detected coding tools without proxy routing (fail-open default or the local G.A.I.N proxy was not verified)..."
      Invoke-AgentCommand -AgentPath $AgentPath -Arguments @("integrations", "--apply", "--no-proxy-env") -Description "Coding-tool auto-wiring" -Fix "Run gain-agent integrations --apply --no-proxy-env after resolving the message above."
      Write-Host "To deliberately enable fail-closed proxy routing later: set GAIN_PROXY_FAIL_POLICY=fail_closed, then run gain-agent proxy --service install and gain-agent integrations --apply."
    }
    Write-Host "Restart open terminals and coding tools so hooks and environment changes take effect."
  } catch {
    Write-Host "Auto-wiring warning: $($_.Exception.Message)"
    Write-Host "Wire tools later with: gain-agent integrations --apply"
  }
}

function Invoke-AgentSetup([string]$AgentPath) {
  if ($OrgKey) {
    $setupArgs = @("setup", "--org-key", $OrgKey, "--mode", $Mode, "--label", $Label)
    $setupArgs += @("--proxy-fail-policy", $ProxyFailPolicy)
    if ($EnableAutoUpdate) { $setupArgs += "--auto-update" } else { $setupArgs += "--disable-auto-update" }
    if ($DeploymentMode) { $setupArgs += @("--deployment-mode", $DeploymentMode) }
    if ($SupabaseUrl) { $setupArgs += @("--supabase-url", $SupabaseUrl) }
    if ($SupabaseKey) { $setupArgs += @("--supabase-key", $SupabaseKey) }
    if ($env:GAIN_TELEMETRY_ENABLED -eq "false" -or $env:GAIN_NO_TELEMETRY -eq "1") { $setupArgs += @("--no-telemetry") }
    if ($Department) { $setupArgs += @("--department", $Department) }
    if ($env:GAIN_SIEM_WEBHOOK_URL) { $setupArgs += @("--siem-webhook-url", $env:GAIN_SIEM_WEBHOOK_URL) }
    if ($env:GAIN_SIEM_BEARER_TOKEN) { $setupArgs += @("--siem-token", $env:GAIN_SIEM_BEARER_TOKEN) }
    Invoke-AgentCommand -AgentPath $AgentPath -Arguments $setupArgs -Description "Agent setup" -Fix "Check the Organization Key and network connection, then rerun this installer."
    if ($env:GAIN_AGENT_SKIP_HEALTH_SCHEDULE -ne "1") {
      Invoke-AgentCommand -AgentPath $AgentPath -Arguments @("install-health-schedule") -Description "Health schedule installation" -Fix "Run gain-agent install-health-schedule from an elevated PowerShell, then rerun gain-agent doctor."
    }
    if ($EnableAutoUpdate) {
      Invoke-AgentCommand -AgentPath $AgentPath -Arguments @("enable-auto-update") -Description "Auto-update scheduling" -Fix "Run gain-agent enable-auto-update from an elevated PowerShell after resolving the message above."
    } else {
      & $AgentPath disable-auto-update | Out-Null
    }
    Install-ProxyService $AgentPath
    Invoke-AutoWire $AgentPath
    Invoke-AgentCommand -AgentPath $AgentPath -Arguments @("doctor") -Description "Final health check" -Fix "Run gain-agent doctor and follow its named repair command before relying on G.A.I.N."
  } elseif ($ExistingConfigBackup -and (Test-Path -LiteralPath $ExistingConfigBackup)) {
    New-Item -ItemType Directory -Path $GainConfigDir -Force | Out-Null
    Copy-Item -LiteralPath $ExistingConfigBackup -Destination $GainConfigPath -Force
    $Preserved = Get-Content -LiteralPath $GainConfigPath -Raw | ConvertFrom-Json
    $PreservedFailPolicy = if ($Preserved.proxy_fail_policy -eq "fail_closed") { "fail_closed" } else { "fail_open" }
    if ($env:GAIN_AGENT_SKIP_HEALTH_SCHEDULE -ne "1") {
      Invoke-AgentCommand -AgentPath $AgentPath -Arguments @("install-health-schedule") -Description "Health schedule restoration" -Fix "Run gain-agent install-health-schedule from an elevated PowerShell, then rerun gain-agent doctor."
    }
    if ($Preserved.auto_update -eq $true) {
      Invoke-AgentCommand -AgentPath $AgentPath -Arguments @("enable-auto-update") -Description "Auto-update restoration" -Fix "Run gain-agent enable-auto-update after resolving the message above."
    } else {
      & $AgentPath disable-auto-update | Out-Null
    }
    if (-not $SkipService) {
      try { Invoke-AgentCommand -AgentPath $AgentPath -Arguments @("proxy", "--service", "install", "--proxy-fail-policy", $PreservedFailPolicy) -Description "Proxy service restoration" -Fix "Run gain-agent proxy --service install later if needed." } catch { Write-Host "Proxy service restoration warning: $($_.Exception.Message)" }
    }
    Write-Host "Updated G.A.I.N Agent and preserved the existing organization enrollment."
    Invoke-AgentCommand -AgentPath $AgentPath -Arguments @("doctor") -Description "Final health check" -Fix "Run gain-agent doctor and follow its named repair command before relying on G.A.I.N."
  } else {
    Write-Host ""
    Write-Host "Installed. Connect it with:"
    Write-Host ('  $env:GAIN_ORG_API_KEY="<YOUR_ORG_KEY>"; irm ' + $BaseUrl + '/install.ps1 | iex')
    Write-Host "  gain-agent setup --org-key <YOUR_ORG_KEY> --mode visibility_only --label ""$Label"" --department Engineering"
  }
}

function Install-Binary([object]$Manifest) {
  $platformKey = Get-PlatformKey
  $binary = $null
  if ($Manifest -and $Manifest.binaries) {
    $prop = $Manifest.binaries.PSObject.Properties | Where-Object { $_.Name -eq $platformKey } | Select-Object -First 1
    if ($prop) { $binary = $prop.Value }
  }
  if (-not $binary -or -not $binary.url) { return $false }

  $installDir = $env:GAIN_AGENT_INSTALL_DIR
  if (-not $installDir) { $installDir = Join-Path $env:LOCALAPPDATA "Programs\GAIN\bin" }
  New-Item -ItemType Directory -Path $installDir -Force | Out-Null

  $agentPath = Join-Path $installDir "gain-agent.exe"
  $tempPath = Join-Path $env:TEMP "gain-agent-$($Manifest.version)-$platformKey.exe"
  $downloadUrl = Resolve-GainUrl $binary.url

  Write-Host "Downloading G.A.I.N Agent $($Manifest.version) standalone binary for $platformKey..."
  Invoke-WebRequest -Uri $downloadUrl -OutFile $tempPath -UseBasicParsing

  if ($binary.sha256) {
    $actualHash = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = [string]$binary.sha256
    $expectedHash = $expectedHash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
      throw "Downloaded binary checksum mismatch. Expected $expectedHash but got $actualHash."
    }
    Write-Host "Checksum verified."
  }

  Replace-AgentBinary $tempPath $agentPath
  Add-ToUserPath $installDir
  Write-Host "Installed G.A.I.N Agent at $agentPath"
  & $agentPath --version
  if ($LASTEXITCODE -ne 0) {
    throw "Installed G.A.I.N Agent binary could not start. Delete $agentPath, rerun the installer, and contact CyberWardion if the problem remains."
  }
  Invoke-AgentSetup $agentPath
  return $true
}

function Install-NpmFallback([object]$Manifest) {
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "No standalone binary is available for this platform, and npm is not installed. Install Node.js 18+ or contact CyberWardion for your platform binary."
  }

  $version = $env:GAIN_AGENT_VERSION
  if (-not $version -and $Manifest -and $Manifest.version) { $version = $Manifest.version }
  if (-not $version) { $version = "0.5.44" }
  $packageRef = $null
  if ($Manifest -and $Manifest.package) { $packageRef = [string]$Manifest.package }
  if (-not $packageRef) { $packageRef = "gain-agent-$version.tgz" }
  $packageName = Split-Path $packageRef -Leaf
  if (-not $packageName) { $packageName = "gain-agent-$version.tgz" }
  $packageUrl = Resolve-GainUrl $packageRef
  $tempPackage = Join-Path $env:TEMP $packageName

  Write-Host "Downloading G.A.I.N Agent $version npm package fallback..."
  Invoke-WebRequest -Uri $packageUrl -OutFile $tempPackage -UseBasicParsing
  npm install -g "$tempPackage"
  Invoke-AgentSetup "gain-agent"
}

$latest = Get-LatestManifest
if (-not (Install-Binary $latest)) {
  Write-Host "No matching standalone binary found for $(Get-PlatformKey). Using npm fallback."
  Install-NpmFallback $latest
}
