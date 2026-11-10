#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p build/Fixtures dist/ui-evidence
swift Tests/Fixtures/generate-media.swift "$PROJECT_ROOT/build/Fixtures/sample.mp4"
python3 Tests/Fixtures/server.py "$PROJECT_ROOT/build/Fixtures/sample.mp4" &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT

DEVICE_ID="$(xcrun simctl list devices available --json | python3 -c '
import json,sys
devices=[d for items in json.load(sys.stdin)["devices"].values() for d in items if "iPhone" in d["name"]]
preferred=sorted(devices,key=lambda d:("iPhone 16" not in d["name"], d["state"]!="Booted",d["name"]))
print(preferred[0]["udid"])
')"
xcrun simctl boot "$DEVICE_ID" || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl status_bar "$DEVICE_ID" override --time '9:41' --batteryState charged --batteryLevel 100

TEST_STATUS=0
xcodebuild test \
  -project iMovie.xcodeproj -scheme iMovie -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "$PROJECT_ROOT/build/Simulator" \
  -resultBundlePath "$PROJECT_ROOT/build/SimulatorTests.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' || TEST_STATUS=$?
xcrun xcresulttool export attachments \
  --path "$PROJECT_ROOT/build/SimulatorTests.xcresult" \
  --output-path "$PROJECT_ROOT/dist/ui-evidence" || true
exit "$TEST_STATUS"
