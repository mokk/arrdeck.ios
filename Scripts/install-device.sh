#!/bin/sh
# Builds the app and installs it on a paired iPhone — over USB or, once the
# phone has been paired by cable, over Wi-Fi (same network, phone unlocked).
# Also the 7-day refresh for a free (Personal Team) signature.
#
#   Scripts/install-device.sh            # the first paired physical iPhone
#   DEVICE=<udid> Scripts/install-device.sh
#   RENEW=1 Scripts/install-device.sh    # a fresh 7-day profile regardless
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Xcode reuses a cached profile until it expires, so a reinstall alone never
# moves the date. Inside its last two days (the app's warning window), set the
# profile aside — moved, not deleted — and Xcode makes a new seven-day one.
python3 - "${RENEW:-0}" <<'PY'
import datetime, os, plistlib, shutil, subprocess, sys
force = sys.argv[1] == "1"
cache = os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")
aside = "/tmp/arrdeck-old-profiles"
soon = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2)
for name in os.listdir(cache) if os.path.isdir(cache) else []:
    path = os.path.join(cache, name)
    raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
    try:
        profile = plistlib.loads(raw)
    except Exception:
        continue
    if profile.get("Name") != "iOS Team Provisioning Profile: dk.thrawn.arrdeck":
        continue
    expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
    if force or expires < soon:
        os.makedirs(aside, exist_ok=True)
        shutil.move(path, os.path.join(aside, name))
        print(f"Renewing the signature (the old one expires {expires:%Y-%m-%d %H:%M} UTC)")
PY

if [ -z "$DEVICE" ]; then
    json=$(mktemp)
    xcrun devicectl list devices --json-output "$json" >/dev/null
    DEVICE=$(python3 - "$json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS" and conn.get("pairingState") == "paired":
        print(hw["udid"])
        break
PY
)
    rm -f "$json"
fi
[ -n "$DEVICE" ] || { echo "No paired iPhone found. Pair it once by cable in Xcode first." >&2; exit 1; }

derived=/tmp/arrdeck-device
app="$derived/Build/Products/Debug-iphoneos/Arrdeck.app"
echo "Building for $DEVICE…"
xcodebuild -project App/Arrdeck.xcodeproj -scheme Arrdeck -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath "$derived" \
    -allowProvisioningUpdates -skipPackagePluginValidation -quiet build

echo "Installing…"
xcrun devicectl device install app --device "$DEVICE" "$app"
security cms -D -i "$app/embedded.mobileprovision" | plutil -extract ExpirationDate raw - | sed 's/^/Signature expires /'
