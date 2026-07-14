#!/bin/bash
# Build a shareable zip: dist/Cooldown-<version>.zip (app + double-clickable installer)
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP="$HOME/Applications/Cooldown.app"
STAGE="dist/Cooldown $VERSION"
ZIP="dist/Cooldown-$VERSION.zip"

rm -rf dist
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

cat > "$STAGE/Install.command" <<'EOF'
#!/bin/bash
# Cooldown installer — double-click, or run:  bash Install.command
set -e
cd "$(dirname "$0")"
APP="Cooldown.app"
DEST="$HOME/Applications"
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

( cd dist && ditto -c -k --keepParent "Cooldown $VERSION" "Cooldown-$VERSION.zip" )
echo "Packaged: $ZIP"
