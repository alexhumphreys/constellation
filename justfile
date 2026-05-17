default: test

# The SwiftPM package lives in Core/ so the iOS app (eventually under
# Apps/) can use a local-package reference at ../../Core without Xcode
# pulling the Apps/ dir back in via the package's source tree. All
# swift CLI invocations point at the package via --package-path Core.

build:
    swift build --package-path Core

test:
    swift test --package-path Core

clean:
    swift package --package-path Core clean
    rm -rf Core/.build

ci: build test

# --- CLI dogfood (`constellation` executable) ---

constellation *args:
    swift run --package-path Core constellation {{args}}

# Quick "smoke test the world" — wipes the dev store, seeds the design's
# data, then exercises a couple of read paths. Useful before a demo.
demo:
    @rm -f /tmp/constellation-demo.sqlite
    CONSTELLATION_STORE_PATH=/tmp/constellation-demo.sqlite \
      swift run --package-path Core constellation seed
    CONSTELLATION_STORE_PATH=/tmp/constellation-demo.sqlite \
      swift run --package-path Core constellation area list
    CONSTELLATION_STORE_PATH=/tmp/constellation-demo.sqlite \
      swift run --package-path Core constellation ready --area silks

# --- iOS app shell (Constellation-iOS) ---
#
# `ios-gen` regenerates the xcodeproj from project.yml — Apps/*.xcodeproj
# is gitignored so the project regenerates cleanly on each checkout.
# `ios-build` and `ios-launch` build for the iPhone simulator; pass a
# different name via `ios-sim=...`. First device install needs the
# device plugged in and trusted (Settings > VPN & Device Management).

ios-sim := "iPhone 17"
ios-pad-sim := "iPad Pro 13-inch (M4)"

ios-gen:
    cd Apps/Constellation-iOS && xcodegen generate

ios-build: ios-gen
    xcodebuild \
      -project Apps/Constellation-iOS/Constellation-iOS.xcodeproj \
      -scheme Constellation-iOS \
      -destination "generic/platform=iOS Simulator" \
      -skipPackagePluginValidation \
      build

# Phone build + launch on the named simulator. Builds first, then boots
# the sim and installs/launches the app.
ios-launch: ios-build
    #!/usr/bin/env bash
    set -euo pipefail
    xcrun simctl boot "{{ios-sim}}" 2>/dev/null || true
    open -a Simulator
    APP_PATH=$(xcodebuild \
      -project Apps/Constellation-iOS/Constellation-iOS.xcodeproj \
      -scheme Constellation-iOS \
      -destination "generic/platform=iOS Simulator" \
      -showBuildSettings \
      -skipPackagePluginValidation \
      2>/dev/null \
      | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ {print $2; exit}')
    xcrun simctl install booted "$APP_PATH/Constellation-iOS.app"
    xcrun simctl launch booted com.constellation.ios

# Same as ios-launch but boots the iPad simulator instead — handy when
# you want to actually see the split-view sidebar layout vs the sheet.
ipad-launch: ios-build
    #!/usr/bin/env bash
    set -euo pipefail
    xcrun simctl boot "{{ios-pad-sim}}" 2>/dev/null || true
    open -a Simulator
    APP_PATH=$(xcodebuild \
      -project Apps/Constellation-iOS/Constellation-iOS.xcodeproj \
      -scheme Constellation-iOS \
      -destination "generic/platform=iOS Simulator" \
      -showBuildSettings \
      -skipPackagePluginValidation \
      2>/dev/null \
      | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ {print $2; exit}')
    xcrun simctl install "{{ios-pad-sim}}" "$APP_PATH/Constellation-iOS.app"
    xcrun simctl launch "{{ios-pad-sim}}" com.constellation.ios

ios-devices:
    xcrun devicectl list devices

ios-device udid=env_var_or_default("IOS_DEVICE_ID", ""): ios-gen
    #!/usr/bin/env bash
    set -euo pipefail
    UDID="{{udid}}"
    if [ -z "$UDID" ]; then
      echo "usage: just ios-device <udid>  (or export IOS_DEVICE_ID)" >&2
      echo "list paired phones: just ios-devices" >&2
      exit 64
    fi
    xcodebuild \
      -project Apps/Constellation-iOS/Constellation-iOS.xcodeproj \
      -scheme Constellation-iOS \
      -destination "platform=iOS,id=$UDID" \
      -allowProvisioningUpdates \
      -skipPackagePluginValidation \
      build
    APP_PATH=$(xcodebuild \
      -project Apps/Constellation-iOS/Constellation-iOS.xcodeproj \
      -scheme Constellation-iOS \
      -destination "platform=iOS,id=$UDID" \
      -showBuildSettings \
      -skipPackagePluginValidation \
      2>/dev/null \
      | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ {print $2; exit}')
    xcrun devicectl device install app --device "$UDID" "$APP_PATH/Constellation-iOS.app"
    xcrun devicectl device process launch --device "$UDID" com.constellation.ios
