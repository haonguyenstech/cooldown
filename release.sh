#!/bin/bash
# Build + publish a new Cooldown version to GitHub Releases (public repo).
# Usage: bump CFBundleShortVersionString in Info.plist, then: ./release.sh
# Apps in the field see it on their next 6-hour check or via the "Check" button.
set -euo pipefail
cd "$(dirname "$0")"

REPO="haonguyenstech/cooldown"

./package.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP="dist/Cooldown.zip"   # stable asset name

echo ""
echo "Releasing v$VERSION to github.com/$REPO …"
gh release create "v$VERSION" "$ZIP" \
  --repo "$REPO" \
  --title "v$VERSION" \
  --notes "Cooldown v$VERSION — menu bar app that keeps a fanless Mac cool." \
  || { echo "Release v$VERSION may already exist. Bump the version in Info.plist first."; exit 1; }

echo "✅ Released: https://github.com/$REPO/releases/tag/v$VERSION"
