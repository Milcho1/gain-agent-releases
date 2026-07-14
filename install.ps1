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
$Label = $env:GAIN_DEVICE_LABEL
if (-not $Label) { $Label = "Developer workstation" }
$Department = $env:GAIN_DEPARTMENT
$SkipService = $NoService -or $env:GAIN_AGENT_NO_SERVICE -eq "1" -or $env:GAIN_AGENT_NO_SERVICE -eq "true"
$SkipAutoWire = $env:GAIN_AGENT_SKIP_INTEGRATIONS -eq "1" -or $env:GAIN_AGENT_NO_AUTOWIRE -eq "1" -or $env:GAIN_AGENT_NO_AUTOWIRE -eq "true"

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

function Set-CurrentProxyEnv {
  $ProxyHost = if ($env:GAIN_PROXY_HOST) { $env:GAIN_PROXY_HOST } else { "127.0.0.1" }
  $ProxyPort = if ($env:GAIN_PROXY_PORT) { $env:GAIN_PROXY_PORT } else { "8787" }
  $ProxyUrl = "http://${ProxyHost}:$ProxyPort"
  foreach ($Name in @("ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "OPENAI_API_BASE", "COPILOT_PROVIDER_BASE_URL")) {
    Set-Item -Path "Env:$Name" -Value $ProxyUrl
  }
}

function Install-ProxyService([string]$AgentPath) {
  if ($SkipService) {
    Write-Host "Skipped hidden proxy service install because --no-service or GAIN_AGENT_NO_SERVICE was set."
    return
  }
  $ProxyHost = if ($env:GAIN_PROXY_HOST) { $env:GAIN_PROXY_HOST } else { "127.0.0.1" }
  $ProxyPort = if ($env:GAIN_PROXY_PORT) { $env:GAIN_PROXY_PORT } else { "8787" }
  try {
    & $AgentPath proxy --service install --host $ProxyHost --port $ProxyPort
    Set-CurrentProxyEnv
  } catch {
    Write-Host "Proxy service install warning: $($_.Exception.Message)"
    Write-Host "Run 'gain-agent proxy --service install' later to enable seamless local proxy routing."
  }
}

function Test-LocalProxyReachable {
  try {
    $ProxyHost = if ($env:GAIN_PROXY_HOST) { $env:GAIN_PROXY_HOST } else { "127.0.0.1" }
    $ProxyPort = if ($env:GAIN_PROXY_PORT) { [int]$env:GAIN_PROXY_PORT } else { 8787 }
    $client = New-Object System.Net.Sockets.TcpClient
    $async = $client.BeginConnect($ProxyHost, $ProxyPort, $null, $null)
    $connected = $async.AsyncWaitHandle.WaitOne(1500) -and $client.Connected
    $client.Close()
    return $connected
  } catch {
    return $false
  }
}

function Invoke-AutoWire([string]$AgentPath) {
  if ($SkipAutoWire) {
    Write-Host "Skipped coding-tool auto-wiring because GAIN_AGENT_SKIP_INTEGRATIONS or GAIN_AGENT_NO_AUTOWIRE was set."
    Write-Host "Wire tools later with: gain-agent integrations --apply"
    return
  }
  $proxyUp = (-not $SkipService) -and (Test-LocalProxyReachable)
  try {
    if ($proxyUp) {
      Write-Host "Auto-wiring detected coding tools (local proxy is running)..."
      & $AgentPath integrations --apply
    } else {
      Write-Host "Auto-wiring detected coding tools (without proxy routing: local proxy not reachable)..."
      & $AgentPath integrations --apply --no-proxy-env
      Write-Host "Enable proxy redaction later with: gain-agent proxy --service install; gain-agent integrations --apply"
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
    if ($DeploymentMode) { $setupArgs += @("--deployment-mode", $DeploymentMode) }
    if ($env:GAIN_TELEMETRY_ENABLED -eq "false" -or $env:GAIN_NO_TELEMETRY -eq "1") { $setupArgs += @("--no-telemetry") }
    if ($Department) { $setupArgs += @("--department", $Department) }
    if ($env:GAIN_SIEM_WEBHOOK_URL) { $setupArgs += @("--siem-webhook-url", $env:GAIN_SIEM_WEBHOOK_URL) }
    if ($env:GAIN_SIEM_BEARER_TOKEN) { $setupArgs += @("--siem-token", $env:GAIN_SIEM_BEARER_TOKEN) }
    & $AgentPath @setupArgs
    if ($env:GAIN_AGENT_SKIP_HEALTH_SCHEDULE -ne "1") {
      & $AgentPath install-health-schedule
    }
    if ($env:GAIN_AGENT_AUTO_UPDATE -ne "false" -and $env:GAIN_AGENT_AUTO_UPDATE -ne "0") {
      & $AgentPath enable-auto-update
    }
    Install-ProxyService $AgentPath
    Invoke-AutoWire $AgentPath
    & $AgentPath doctor
  } else {
    Write-Host ""
    Write-Host "Installed. Connect it with:"
    Write-Host "  $env:GAIN_ORG_API_KEY=""<YOUR_ORG_KEY>""; irm $BaseUrl/install.ps1 | iex"
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

  Move-Item -LiteralPath $tempPath -Destination $agentPath -Force
  Add-ToUserPath $installDir
  Write-Host "Installed G.A.I.N Agent at $agentPath"
  & $agentPath --version
  Invoke-AgentSetup $agentPath
  return $true
}

function Install-NpmFallback([object]$Manifest) {
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "No standalone binary is available for this platform, and npm is not installed. Install Node.js 18+ or contact CyberWardion for your platform binary."
  }

  $version = $env:GAIN_AGENT_VERSION
  if (-not $version -and $Manifest -and $Manifest.version) { $version = $Manifest.version }
  if (-not $version) { $version = "0.4.30" }
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
