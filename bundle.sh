#!/usr/bin/env bash
# Builds CodeUsageBar.app from the SPM executable.
set -euo pipefail

cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/CodeUsageBar"
APP="$PWD/CodeUsageBar.app"
CLAUDE_HELPER="claude-statusline-capture.sh"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CodeUsageBar"
cp "$CLAUDE_HELPER" "$APP/Contents/Resources/$CLAUDE_HELPER"
chmod 755 "$APP/Contents/Resources/$CLAUDE_HELPER"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>CodeUsageBar</string>
  <key>CFBundleIdentifier</key><string>com.example.codeusagebar</string>
  <key>CFBundleName</key><string>CodeUsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [[ "${1:-}" == "--install-claude-helper" ]]; then
  CLAUDE_DIR="$HOME/.claude"
  CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
  INSTALLED_HELPER="$CLAUDE_DIR/$CLAUDE_HELPER"

  mkdir -p "$CLAUDE_DIR"
  cp "$APP/Contents/Resources/$CLAUDE_HELPER" "$INSTALLED_HELPER"
  chmod 700 "$INSTALLED_HELPER"

  if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    printf '{}\n' > "$CLAUDE_SETTINGS"
  fi

  if plutil -extract statusLine json -o - "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
    echo "Installed $INSTALLED_HELPER"
    echo "Kept the existing Claude Code statusLine in $CLAUDE_SETTINGS"
    echo "Point it to $INSTALLED_HELPER if you want CodeUsageBar plan limits."
  else
    plutil -insert statusLine -dictionary "$CLAUDE_SETTINGS"
    plutil -insert statusLine.type -string command "$CLAUDE_SETTINGS"
    plutil -insert statusLine.command -string "$INSTALLED_HELPER" "$CLAUDE_SETTINGS"
    echo "Installed and enabled the Claude Code usage helper."
  fi
fi
