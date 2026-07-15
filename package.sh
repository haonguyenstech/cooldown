#!/bin/bash
# Build a shareable zip with a STABLE name: dist/Cooldown.zip
# (stable name so https://github.com/<repo>/releases/latest/download/Cooldown.zip
#  always resolves — GitHub does NOT support wildcards in that URL).
# Contents (flat, under a "Cooldown" folder): Cooldown.app + Install.command
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP="/Applications/Cooldown.app"
STAGE="dist/Cooldown"
ZIP="dist/Cooldown.zip"

rm -rf dist
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

cat > "$STAGE/Install.command" <<'EOF'
#!/bin/bash
# Cooldown installer — double-click, or run:  bash Install.command
set -e
cd "$(dirname "$0")"
APP="Cooldown.app"
DEST="/Applications"
echo "==> Installing $APP to $DEST …"
mkdir -p "$DEST"
pkill -x Cooldown 2>/dev/null || true
sleep 1
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
open "$DEST/$APP"
echo "==> Done. Cooldown is running in your menu bar."
EOF
chmod +x "$STAGE/Install.command"

# ditto keeps the app bundle intact; --keepParent puts everything under "Cooldown/".
( cd dist && ditto -c -k --keepParent Cooldown Cooldown.zip )
echo "Packaged: $ZIP (version $VERSION)"
