#!/bin/sh
# Builds the app and installs it on a paired iPhone — over USB or, once the
# phone has been paired by cable, over Wi-Fi (same network, phone unlocked).
# Also the 7-day refresh for a free (Personal Team) signature.
#
#   Scripts/install-device.sh            # the first paired physical iPhone
#   DEVICE=<udid> Scripts/install-device.sh
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ -z "$DEVICE" ]; then
    json=$(mktemp)
    xcrun devicectl list devices --json-output "$json" >/dev/null
    DEVICE=$(python3 - "$json" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS" and conn.get("pairingState") == "paired":
        print(hw["udid"])
        break
EOF
)
    rm -f "$json"
fi
[ -n "$DEVICE" ] || { echo "No paired iPhone found. Pair it once by cable in Xcode first." >&2; exit 1; }

derived=/tmp/arrdeck-device
echo "Building for $DEVICE…"
xcodebuild -project App/Arrdeck.xcodeproj -scheme Arrdeck -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath "$derived" \
    -allowProvisioningUpdates -skipPackagePluginValidation -quiet build

echo "Installing…"
xcrun devicectl device install app --device "$DEVICE" \
    "$derived/Build/Products/Debug-iphoneos/Arrdeck.app"
