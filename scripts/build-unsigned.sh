#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "需要安装完整 Xcode 的 Mac，Windows 不能编译 iOS 应用。" >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "请先安装 XcodeGen：brew install xcodegen" >&2
  exit 1
fi

swift test
xcodegen generate --spec project.yml
xcodebuild \
  -project iMovie.xcodeproj \
  -scheme iMovie \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$PROJECT_ROOT/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  build

python3 scripts/package_ipa.py \
  "$PROJECT_ROOT/build/DerivedData/Build/Products/Release-iphoneos/iMovie.app" \
  "$PROJECT_ROOT/dist/iMovie-0.3.0-unsigned.ipa"
