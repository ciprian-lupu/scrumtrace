#!/usr/bin/env bash
# Install a LaunchAgent that pulls and publishes logs every 3 minutes.
# It does not xcodebuild unless agent.request_rebuild exists or the app is missing.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "mac_install_agent_loop.sh must run on macOS" >&2
  exit 2
fi

REPO="${SCRUMTRACE_REPO:-$HOME/development/scrumtrace}"
LABEL="com.str8minds.ScrumTrace.agentloop"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOOP="${REPO}/scripts/mac_agent_loop.sh"
LOG_DIR="${HOME}/Library/Logs/ScrumTrace"

chmod +x "$REPO"/scripts/*.sh "$REPO"/scripts/*.py 2>/dev/null || true
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${LOOP}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartInterval</key>
  <integer>180</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/loop.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/loop.stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SCRUMTRACE_REPO</key>
    <string>${REPO}</string>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
echo "installed $PLIST"
echo "kickstart once:"
echo "  launchctl kickstart -k gui/$(id -u)/${LABEL}"
