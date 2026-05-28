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
#
# NOTE: `ios-gen` is intentionally NOT a dep of the build/launch/device
# recipes. Each regen rewrites project.pbxproj, which resets Xcode's
# Signing & Capabilities UI back to the raw team identifier — meaning
# you'd have to re-click "Alex Humphreys (Personal Team)" in the team
# dropdown every CLI build. Run `just ios-gen` manually after adding,
# removing, or renaming a source file (or after pulling new files);
# Xcode will pick up the change next time you open the project. Between
# regens the xcodeproj is stable and your team selection persists.

ios-sim := "iPhone 17"
ios-pad-sim := "iPad Pro 13-inch (M4)"

# GIT_SHA is expanded into the app's `GitSHA` Info.plist key (project.yml)
# so the `app.launch` wide event can report which build it ran. The SHA
# reflects the checkout at generate time — re-run `just ios-gen` to refresh
# it. Falls back to "unknown" on a detached HEAD or a non-repo checkout.
ios-gen:
    cd Apps/Constellation-iOS && \
      GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
      xcodegen generate

ios-build:
    xcodebuild \
      -project Apps/Constellation-iOS/Constellation-iOS.xcodeproj \
      -scheme Constellation-iOS \
      -destination "generic/platform=iOS Simulator" \
      -skipPackagePluginValidation \
      build

# App-hosted unit tests (CanvasCamera geometry, etc). Needs a concrete
# simulator destination — `test` can't run on the generic one. Run
# `just ios-gen` first if you've added/removed test files.
ios-test:
    xcodebuild \
      -project Apps/Constellation-iOS/Constellation-iOS.xcodeproj \
      -scheme Constellation-iOS \
      -destination "platform=iOS Simulator,name={{ios-sim}}" \
      -skipPackagePluginValidation \
      test

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

ios-device udid=env_var_or_default("IOS_DEVICE_ID", ""):
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
