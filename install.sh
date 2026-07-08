#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${GAIN_AGENT_BASE_URL:-https://www.cyberwardion.com/downloads/gain-agent}"
BASE_URL="${BASE_URL%/}"
ORG_KEY="${GAIN_ORG_API_KEY:-}"
MODE="${GAIN_ENFORCEMENT_MODE:-visibility_only}"
DEPLOYMENT_MODE="${GAIN_DEPLOYMENT_MODE:-}"
LABEL="${GAIN_DEVICE_LABEL:-Developer workstation}"
DEPARTMENT="${GAIN_DEPARTMENT:-}"
NO_SERVICE="${GAIN_AGENT_NO_SERVICE:-}"

for arg in "$@"; do
  case "$arg" in
    --no-service) NO_SERVICE="1" ;;
  esac
done

resolve_url() {
  case "$1" in
    http://*|https://*) printf '%s\n' "$1" ;;
    /*) printf '%s/%s\n' "$BASE_URL" "${1#/}" ;;
    *) printf '%s/%s\n' "$BASE_URL" "$1" ;;
  esac
}

platform_key() {
  os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch_name="$(uname -m | tr '[:upper:]' '[:lower:]')"
  case "$os_name" in
    darwin) os_part="macos" ;;
    linux) os_part="linux" ;;
    *) os_part="$os_name" ;;
  esac
  case "$arch_name" in
    x86_64|amd64) arch_part="x64" ;;
    arm64|aarch64) arch_part="arm64" ;;
    *) arch_part="$arch_name" ;;
  esac
  printf '%s-%s\n' "$os_part" "$arch_part"
}

latest_json() {
  curl -fsSL "$BASE_URL/latest.json" 2>/dev/null || true
}

json_version() {
  printf '%s' "$1" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

json_binary_field() {
  local manifest="$1"
  local key="$2"
  local field="$3"
  printf '%s' "$manifest" \
    | tr '\n' ' ' \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*{[^}]*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
    | head -n 1
}

json_package() {
  printf '%s' "$1" | sed -n 's/.*"package"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

sha_for_file() {
  local file_name="$1"
  local sums_file="${TMPDIR:-/tmp}/gain-agent-SHA256SUMS.txt"
  if curl -fsSL "$BASE_URL/SHA256SUMS.txt" -o "$sums_file"; then
    awk -v f="$file_name" '$2 == f { print $1; exit }' "$sums_file"
  fi
}

verify_sha256() {
  local file_path="$1"
  local expected="$2"
  if [ -z "$expected" ]; then
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file_path" | awk '{ print $1 }')"
  else
    actual="$(shasum -a 256 "$file_path" | awk '{ print $1 }')"
  fi
  if [ "$actual" != "$expected" ]; then
    echo "Downloaded binary checksum mismatch. Expected $expected but got $actual." >&2
    return 1
  fi
  echo "Checksum verified."
}

ensure_path() {
  local dir="$1"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *)
      export PATH="$dir:$PATH"
      profile="$HOME/.profile"
      touch "$profile"
      if ! grep -F "$dir" "$profile" >/dev/null 2>&1; then
        printf '\nexport PATH="%s:$PATH"\n' "$dir" >> "$profile"
        echo "Added $dir to $profile. Open a new terminal to use gain-agent globally."
      fi
      if [ "$(uname -s)" = "Darwin" ]; then
        zprofile="$HOME/.zprofile"
        touch "$zprofile"
        if ! grep -F "$dir" "$zprofile" >/dev/null 2>&1; then
          printf '\nexport PATH="%s:$PATH"\n' "$dir" >> "$zprofile"
          echo "Added $dir to $zprofile."
        fi
      fi
      ;;
  esac
}

set_current_proxy_env() {
  PROXY_HOST="${GAIN_PROXY_HOST:-127.0.0.1}"
  PROXY_PORT="${GAIN_PROXY_PORT:-8787}"
  PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
  export ANTHROPIC_BASE_URL="$PROXY_URL"
  export OPENAI_BASE_URL="$PROXY_URL"
  export OPENAI_API_BASE="$PROXY_URL"
  export COPILOT_PROVIDER_BASE_URL="$PROXY_URL"
}

install_proxy_service() {
  agent_cmd="$1"
  if [ "$NO_SERVICE" = "1" ] || [ "$NO_SERVICE" = "true" ]; then
    echo "Skipped hidden proxy service install because --no-service or GAIN_AGENT_NO_SERVICE was set."
    return 0
  fi
  PROXY_HOST="${GAIN_PROXY_HOST:-127.0.0.1}"
  PROXY_PORT="${GAIN_PROXY_PORT:-8787}"
  if "$agent_cmd" proxy --service install --host "$PROXY_HOST" --port "$PROXY_PORT"; then
    set_current_proxy_env
  else
    echo "Proxy service install warning. Run 'gain-agent proxy --service install' later to enable seamless local proxy routing." >&2
  fi
}

local_proxy_reachable() {
  PROXY_HOST="${GAIN_PROXY_HOST:-127.0.0.1}"
  PROXY_PORT="${GAIN_PROXY_PORT:-8787}"
  node -e "const net=require('net');const s=net.createConnection({host:process.env.GAIN_PROXY_HOST||'127.0.0.1',port:Number(process.env.GAIN_PROXY_PORT||8787)});const done=(ok)=>{s.destroy();process.exit(ok?0:1)};s.setTimeout(1500);s.on('connect',()=>done(true));s.on('timeout',()=>done(false));s.on('error',()=>done(false));" >/dev/null 2>&1
}

auto_wire() {
  agent_cmd="$1"
  if [ "${GAIN_AGENT_SKIP_INTEGRATIONS:-}" = "1" ] || [ "${GAIN_AGENT_NO_AUTOWIRE:-}" = "1" ] || [ "${GAIN_AGENT_NO_AUTOWIRE:-}" = "true" ]; then
    echo "Skipped coding-tool auto-wiring because GAIN_AGENT_SKIP_INTEGRATIONS or GAIN_AGENT_NO_AUTOWIRE was set."
    echo "Wire tools later with: gain-agent integrations --apply"
    return 0
  fi
  if [ "$NO_SERVICE" != "1" ] && [ "$NO_SERVICE" != "true" ] && local_proxy_reachable; then
    echo "Auto-wiring detected coding tools (local proxy is running)..."
    "$agent_cmd" integrations --apply || echo "Auto-wiring warning. Wire tools later with: gain-agent integrations --apply" >&2
  else
    echo "Auto-wiring detected coding tools (without proxy routing: local proxy not reachable)..."
    "$agent_cmd" integrations --apply --no-proxy-env || echo "Auto-wiring warning. Wire tools later with: gain-agent integrations --apply" >&2
  fi
  echo "Restart open terminals and coding tools so hooks and environment changes take effect."
}

run_setup() {
  agent_cmd="$1"
  if [ -n "$ORG_KEY" ]; then
    setup_args=(setup --org-key "$ORG_KEY" --mode "$MODE" --label "$LABEL")
    if [ -n "$DEPLOYMENT_MODE" ]; then setup_args+=(--deployment-mode "$DEPLOYMENT_MODE"); fi
    if [ "${GAIN_TELEMETRY_ENABLED:-}" = "false" ] || [ "${GAIN_NO_TELEMETRY:-}" = "1" ]; then setup_args+=(--no-telemetry); fi
    if [ -n "$DEPARTMENT" ]; then setup_args+=(--department "$DEPARTMENT"); fi
    if [ -n "${GAIN_SIEM_WEBHOOK_URL:-}" ]; then setup_args+=(--siem-webhook-url "$GAIN_SIEM_WEBHOOK_URL"); fi
    if [ -n "${GAIN_SIEM_BEARER_TOKEN:-}" ]; then setup_args+=(--siem-token "$GAIN_SIEM_BEARER_TOKEN"); fi
    "$agent_cmd" "${setup_args[@]}"
    if [ "${GAIN_AGENT_SKIP_HEALTH_SCHEDULE:-}" != "1" ]; then
      "$agent_cmd" install-health-schedule
    fi
    if [ "${GAIN_AGENT_AUTO_UPDATE:-true}" != "false" ] && [ "${GAIN_AGENT_AUTO_UPDATE:-true}" != "0" ]; then
      "$agent_cmd" enable-auto-update
    fi
    install_proxy_service "$agent_cmd"
    auto_wire "$agent_cmd"
    "$agent_cmd" doctor
  else
    echo
    echo "Installed. Connect it with:"
    echo "  curl -fsSL $BASE_URL/install.sh | GAIN_ORG_API_KEY=\"<YOUR_ORG_KEY>\" bash"
    echo "  gain-agent setup --org-key <YOUR_ORG_KEY> --mode visibility_only --label \"$LABEL\" --department Engineering"
  fi
}

install_binary() {
  key="$(platform_key)"
  manifest="$(latest_json)"
  version="${GAIN_AGENT_VERSION:-$(json_version "$manifest")}"
  if [ -z "$version" ]; then version="0.4.28"; fi

  binary_name="gain-agent-$version-$key"
  binary_url_value="$(json_binary_field "$manifest" "$key" "url")"
  if [ -z "$binary_url_value" ]; then binary_url_value="$binary_name"; fi
  binary_url="$(resolve_url "$binary_url_value")"
  tmp_binary="${TMPDIR:-/tmp}/$binary_name"

  if ! curl -fsI "$binary_url" >/dev/null 2>&1; then
    return 1
  fi

  echo "Downloading G.A.I.N Agent $version standalone binary for $key..."
  curl -fsSL "$binary_url" -o "$tmp_binary"
  expected="$(json_binary_field "$manifest" "$key" "sha256")"
  if [ -z "$expected" ]; then expected="$(sha_for_file "$binary_name")"; fi
  verify_sha256 "$tmp_binary" "$expected"

  install_dir="${GAIN_AGENT_INSTALL_DIR:-$HOME/.local/bin}"
  mkdir -p "$install_dir"
  cp "$tmp_binary" "$install_dir/gain-agent"
  chmod +x "$install_dir/gain-agent"
  ensure_path "$install_dir"
  echo "Installed G.A.I.N Agent at $install_dir/gain-agent"
  "$install_dir/gain-agent" --version
  run_setup "$install_dir/gain-agent"
  return 0
}

install_npm_fallback() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "No standalone binary is available for this platform, and npm is not installed. Install Node.js 18+ or contact CyberWardion for your platform binary." >&2
    exit 1
  fi
  manifest="$(latest_json)"
  version="${GAIN_AGENT_VERSION:-$(json_version "$manifest")}"
  if [ -z "$version" ]; then version="0.4.28"; fi
  package_ref="$(json_package "$manifest")"
  if [ -z "$package_ref" ]; then package_ref="gain-agent-$version.tgz"; fi
  package_name="$(basename "$package_ref")"
  tmp_package="${TMPDIR:-/tmp}/$package_name"
  echo "Downloading G.A.I.N Agent $version npm package fallback..."
  curl -fsSL "$(resolve_url "$package_ref")" -o "$tmp_package"
  npm install -g "$tmp_package"
  run_setup "gain-agent"
}

if ! install_binary; then
  echo "No matching standalone binary found for $(platform_key). Using npm fallback."
  install_npm_fallback
fi
