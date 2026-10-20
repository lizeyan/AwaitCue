#!/usr/bin/env bash

set -euo pipefail

: "${APPLE_NOTARY_KEY_PATH:?APPLE_NOTARY_KEY_PATH is required}"
: "${APPLE_NOTARY_KEY_ID:?APPLE_NOTARY_KEY_ID is required}"
: "${APPLE_NOTARY_ISSUER_ID:?APPLE_NOTARY_ISSUER_ID is required}"

readonly version="${VERSION:?VERSION is required}"
readonly dmg_path="dist/AwaitCue-${version}.dmg"

xcrun notarytool submit "${dmg_path}" \
  --key "${APPLE_NOTARY_KEY_PATH}" \
  --key-id "${APPLE_NOTARY_KEY_ID}" \
  --issuer "${APPLE_NOTARY_ISSUER_ID}" \
  --wait

xcrun stapler staple "${dmg_path}"
xcrun stapler validate "${dmg_path}"
