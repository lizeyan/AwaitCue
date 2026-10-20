#!/usr/bin/env bash

set -euo pipefail

swift build -Xswiftc -warnings-as-errors
./Scripts/swift-coverage.sh
./Scripts/extension-coverage.sh
