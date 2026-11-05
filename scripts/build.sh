#!/bin/sh
# Builds MLXRunner.app. Usage: ./scripts/build.sh [--install]
#   --install  also copies the app to /Applications
set -e
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate --quiet
xcodebuild -project MLXRunner.xcodeproj -scheme MLXRunner -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- -quiet build
rm -rf build/MLXRunner.app
cp -R build/DerivedData/Build/Products/Release/MLXRunner.app build/
echo "Built $(pwd)/build/MLXRunner.app"
if [ "$1" = "--install" ]; then
  rm -rf /Applications/MLXRunner.app
  cp -R build/MLXRunner.app /Applications/
  echo "Installed /Applications/MLXRunner.app"
fi
