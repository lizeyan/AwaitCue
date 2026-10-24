#!/usr/bin/env bash

set -euo pipefail

swift build -Xswiftc -warnings-as-errors
./Scripts/run-macos-e2e.sh
./Scripts/swift-coverage.sh
./Scripts/extension-coverage.sh
node --test Benchmarks/Decision/tests/*.test.mjs
node Scripts/run-decision-benchmark.mjs --dry-run
