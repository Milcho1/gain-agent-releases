G.A.I.N Agent 0.4.31 hosted download files

Upload these files to:
  https://www.cyberwardion.com/downloads/gain-agent/

Files:
  install.ps1
  install.sh
  latest.json
  SHA256SUMS.txt

GitHub Release assets for gain-agent-v0.4.31:
  gain-agent-0.4.31.tgz
  gain-agent-0.4.31-win-x64.exe
  gain-agent-0.4.31-macos-x64
  gain-agent-0.4.31-macos-arm64
  gain-agent-0.4.31-linux-x64
  gain-agent-0.4.31-linux-arm64

Dashboard install commands:

Windows PowerShell:
  $env:GAIN_ORG_API_KEY="<ORG_KEY>"; irm https://www.cyberwardion.com/downloads/gain-agent/install.ps1 | iex

macOS / Linux:
  curl -fsSL https://www.cyberwardion.com/downloads/gain-agent/install.sh | GAIN_ORG_API_KEY="<ORG_KEY>" bash

Installer behavior:
  1. Read latest.json.
  2. Download the matching standalone binary from the GitHub Release URL in latest.json.
  3. Verify SHA256.
  4. Install on PATH.
  5. Connect to the org when GAIN_ORG_API_KEY is provided.
  6. Install health schedule, enable auto-update unless disabled, start hidden proxy service, auto-wire detected coding tools, and run doctor last.

If no standalone binary exists for the platform, the installers fall back to the
GitHub Release tarball:
  npm install -g https://github.com/Milcho1/gain-agent-releases/releases/download/gain-agent-v0.4.31/gain-agent-0.4.31.tgz

The fallback tarball is hosted at the package URL in latest.json.

The binary path does not require Node.js.

Large standalone binaries and tarballs are ignored by git under
public/downloads/gain-agent. Upload them as GitHub Release assets instead of
committing them to the website repo.
