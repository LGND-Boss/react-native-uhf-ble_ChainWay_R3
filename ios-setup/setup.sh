#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# UHF BLE App — iOS Setup Script
# Run this on your Mac to create a complete Xcode project.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e

APP_NAME="UhfBleApp"
RN_VERSION="0.72.6"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================"
echo "  UHF BLE App — iOS Setup"
echo "================================================"
echo ""

# 1. Check prerequisites
echo "Checking prerequisites..."
command -v node  >/dev/null 2>&1 || { echo "ERROR: Node.js not found. Install from nodejs.org"; exit 1; }
command -v npm   >/dev/null 2>&1 || { echo "ERROR: npm not found."; exit 1; }
command -v pod   >/dev/null 2>&1 || { echo "ERROR: CocoaPods not found. Run: sudo gem install cocoapods"; exit 1; }
echo "  Node:  $(node --version)"
echo "  npm:   $(npm --version)"
echo "  pod:   $(pod --version)"
echo ""

# 2. Init React Native project
if [ -d "$APP_NAME" ]; then
    echo "Directory $APP_NAME already exists. Delete it first if you want a fresh setup."
    echo "Skipping init, using existing..."
else
    echo "Creating React Native $RN_VERSION project..."
    npx react-native@$RN_VERSION init $APP_NAME --version $RN_VERSION --skip-install
fi

cd "$APP_NAME"

# 3. Copy source files
echo ""
echo "Copying app source files..."
mkdir -p src
cp "$SCRIPT_DIR/App.tsx"         .
cp "$SCRIPT_DIR/index.js"        .

# 4. Copy native module into ios/
echo "Copying native module files..."
cp "$SCRIPT_DIR/UhfBle.h"        ios/
cp "$SCRIPT_DIR/UhfBle.m"        ios/

# 5. Install JS dependencies
echo ""
echo "Installing JS dependencies..."
npm install

# 6. Patch Podfile
echo ""
echo "Patching Podfile..."
cp "$SCRIPT_DIR/Podfile.template" ios/Podfile

# 7. Pod install
echo ""
echo "Running pod install..."
cd ios
pod install
cd ..

# 8. Print success
echo ""
echo "================================================"
echo "  DONE!"
echo "================================================"
echo ""
echo "Next steps:"
echo "  1. Open $APP_NAME/ios/$APP_NAME.xcworkspace in Xcode"
echo "  2. Select your target device"
echo "  3. Press Run (Cmd+R)"
echo ""
echo "Make sure your Info.plist has:"
echo "  NSBluetoothAlwaysUsageDescription"
echo "  NSBluetoothPeripheralUsageDescription"
echo "(Already added by this script)"
