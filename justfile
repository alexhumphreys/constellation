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
