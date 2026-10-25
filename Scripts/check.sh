#!/usr/bin/env bash

set -euo pipefail

bash -n Scripts/*.sh
swift build -Xswiftc -warnings-as-errors
./Scripts/run-macos-e2e.sh
./Scripts/test-chrome-e2e-fixture.sh
./Scripts/test-native-host-install.sh
./Scripts/swift-coverage.sh
./Scripts/extension-coverage.sh
npm --prefix SafariExtension ci
npm --prefix SafariExtension run coverage
CONFIGURATION=debug ./Scripts/build-safari-extension.sh
test -x dist/AwaitCueSafariExtension.appex/Contents/MacOS/AwaitCueSafariExtension
node --test Benchmarks/Decision/tests/*.test.mjs
node Scripts/run-decision-benchmark.mjs --dry-run
