#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DIR="$ROOT_DIR/build/release-derived"
DIST_DIR="$ROOT_DIR/dist"
CONFIGURATION="${CONFIGURATION:-Release}"
INSTALL_TO_APPLICATIONS="${1:-}"

echo "Building AppleSync ($CONFIGURATION) using Xcode..."
mkdir -p "$DERIVED_DIR" "$DIST_DIR"

/usr/bin/xcodebuild \
  -project "$ROOT_DIR/App/AppleSync.xcodeproj" \
  -scheme AppleSync \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DIR" \
  build

BUILT_APP="$DERIVED_DIR/Build/Products/$CONFIGURATION/AppleSync.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Error: AppleSync.app was not found at $BUILT_APP" >&2
  exit 1
fi

rm -rf "$DIST_DIR/AppleSync.app"
ditto "$BUILT_APP" "$DIST_DIR/AppleSync.app"

ZIP_PATH="$DIST_DIR/AppleSync-macOS.zip"
rm -f "$ZIP_PATH"
ditto -c -k --norsrc --keepParent "$DIST_DIR/AppleSync.app" "$ZIP_PATH"

echo "Built app bundle: $DIST_DIR/AppleSync.app"
echo "Created archive:  $ZIP_PATH"

if [[ "$INSTALL_TO_APPLICATIONS" == "--install" ]]; then
  echo "Installing to /Applications/AppleSync.app..."
  rm -rf "/Applications/AppleSync.app"
  ditto "$DIST_DIR/AppleSync.app" "/Applications/AppleSync.app"
  echo "Installed! Launch with: open /Applications/AppleSync.app"
else
  echo ""
  echo "Next step: install to /Applications with:"
  echo "  ./scripts/build-app.sh --install"
  echo "Or open directly:"
  echo "  open \"$DIST_DIR/AppleSync.app\""
fi
