G.A.I.N Agent 0.4.28 hosted download files

Upload these files to:
  https://www.cyberwardion.com/downloads/gain-agent/

Files:
  install.ps1
  install.sh
  latest.json
  SHA256SUMS.txt
  gain-agent-0.4.28.tgz
  gain-agent-0.4.28-win-x64.exe
  gain-agent-0.4.28-macos-x64
  gain-agent-0.4.28-macos-arm64
  gain-agent-0.4.28-linux-x64
  gain-agent-0.4.28-linux-arm64

Dashboard install commands:

Windows PowerShell:
  $env:GAIN_ORG_API_KEY="<ORG_KEY>"; irm https://www.cyberwardion.com/downloads/gain-agent/install.ps1 | iex

macOS / Linux:
  curl -fsSL https://www.cyberwardion.com/downloads/gain-agent/install.sh | GAIN_ORG_API_KEY="<ORG_KEY>" bash

Installer behavior:
  1. Read latest.json.
  2. Download the matching standalone binary from the URL in latest.json.
  3. Verify SHA256.
  4. Install on PATH.
  5. Connect to the org when GAIN_ORG_API_KEY is provided.
  6. Install health schedule, enable auto-update unless disabled, start hidden proxy service, auto-wire detected coding tools, and run doctor last.

If no standalone binary exists for the platform, the installers fall back to:
  npm install -g ./gain-agent-0.4.28.tgz

The fallback tarball is also hosted at the package URL in latest.json.

The binary path does not require Node.js.

Large standalone binaries and tarballs are ignored by git under
public/downloads/gain-agent. Publish them to the live host/CDN together with
latest.json and SHA256SUMS.txt.
